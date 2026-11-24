-- Remote directories, on a host reached over SSH, named as scp names them
-- and onon.open opens them: [user@]host:/path. A listing is one ssh run of
-- sh on the host, which prints the directory and its entries. onon names a
-- remote document it has open sftp://host/path; from_uri brings that back
-- to host:/path, so the browser can mark open documents and start beside
-- a remote one.

local remote = {}

local SSH_SCHEMES = { "sftp://", "ssh://", "scp://" }

local function unescape(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- Hosts are lowercased, as onon does, so a host typed either way is one.
local function lower_host(host)
  local user, name = host:match("^(.*@)(.*)$")
  if user then
    return user .. name:lower()
  end
  return host:lower()
end

-- split returns the host and path of [user@]host:path, or of an ssh URI,
-- or nil for a local path. A single letter before the colon is a Windows
-- drive, not a host. A URI's path comes back as scp has it: /~/x is ~/x.
function remote.split(path)
  if type(path) ~= "string" then
    return nil
  end
  for _, scheme in ipairs(SSH_SCHEMES) do
    if path:sub(1, #scheme) == scheme then
      local host, rest = path:sub(#scheme + 1):match("^([^/]+)(.*)$")
      if not host then
        return nil
      end
      rest = unescape(rest)
      if rest == "" or rest == "/~" then
        rest = "~"
      elseif rest:sub(1, 3) == "/~/" then
        rest = rest:sub(2)
      end
      return lower_host(host), rest
    end
  end
  if path:find("://", 1, true) or path:sub(1, 1) == "-" then
    return nil
  end
  local host, rest = path:match("^([^/\\:]+):(.*)$")
  if not host or #host == 1 or host:sub(1, 1) == "@" or host:sub(-1) == "@" then
    return nil
  end
  return lower_host(host), rest
end

function remote.is_remote(path)
  return remote.split(path) ~= nil
end

-- from_uri gives the host:path of a remote document onon has open, or
-- path itself for a local one.
function remote.from_uri(path)
  local host, rest = remote.split(path)
  if not host then
    return path
  end
  return host .. ":" .. rest
end

function remote.join(host, path)
  return host .. ":" .. path
end

function remote.dirname(path)
  local host, rest = remote.split(path)
  if rest == "/" then
    return path
  end
  local dir = rest:match("^(.*)/[^/]*$")
  if not dir then
    return remote.join(host, "~") -- a path relative to the remote home
  end
  return remote.join(host, dir == "" and "/" or dir)
end

function remote.is_root(path)
  local _, rest = remote.split(path)
  return rest == "/"
end

local function quote(text)
  return "'" .. text:gsub("'", [['\'']]) .. "'"
end

-- The script sh runs on the host: the directory's absolute path, then an
-- entry per record, type, size, modification time and name, tab separated.
-- Each ends in a NUL, so any name survives. GNU find lists in one process;
-- elsewhere, as on macOS, a loop stats each entry. Links are followed, so
-- a linked directory is entered like any other; a broken one is type l.
local LIST = [[
%s || exit 1
printf '%%s\0' "$(pwd)"
if find . -maxdepth 0 -printf '' 2>/dev/null; then
  find -L . -mindepth 1 -maxdepth 1 -printf '%%y\t%%s\t%%T@\t%%f\0' 2>/dev/null
  exit 0
fi
for f in .* *; do
  case $f in .|..) continue ;; esac
  [ -e "$f" ] || [ -L "$f" ] || continue
  if [ -d "$f" ]; then t=d; elif [ -f "$f" ]; then t=f; elif [ -e "$f" ]; then t=o; else t=l; fi
  set -- $(stat -L -f '%%z %%m' "$f" 2>/dev/null || stat -L -c '%%s %%Y' "$f" 2>/dev/null || echo 0 0)
  printf '%%s\t%%s\t%%s\t%%s\0' "$t" "${1:-0}" "${2:-0}" "$f"
done
]]

local function cd_command(path)
  if path == "" or path == "~" then
    return 'cd -- "$HOME"'
  end
  if path:sub(1, 2) == "~/" then
    return 'cd -- "$HOME" && cd -- ' .. quote(path:sub(3))
  end
  -- ssh starts in the home directory, so a relative path is under it.
  return "cd -- " .. quote(path)
end

local TYPES = { d = "directory", f = "file", l = "symlink" }

local function parse(host, stdout)
  local records = {}
  local start = 1
  while true do
    local nul = stdout:find("\0", start, true)
    if not nul then
      break
    end
    records[#records + 1] = stdout:sub(start, nul - 1)
    start = nul + 1
  end
  local dir = records[1]
  if not dir or dir == "" then
    return nil
  end
  local entries = {}
  for i = 2, #records do
    local kind, size, modified, name = records[i]:match("^(%a)\t(%d*)\t([%d.]*)\t(.+)$")
    if kind then
      local broken = kind == "l"
      entries[#entries + 1] = {
        name = name,
        path = remote.join(host, (dir == "/" and "" or dir) .. "/" .. name),
        type = TYPES[kind] or "other",
        size_bytes = broken and 0 or (tonumber(size) or 0),
        modified_unix = broken and 0 or math.floor(tonumber(modified) or 0),
        error = broken and "broken link" or ""
      }
    end
  end
  return remote.join(host, dir), entries
end

-- ssh_command is the ssh to run and the arguments before the host. Off
-- Windows, connections are shared for a minute, so moving between
-- directories does not log in again each time.
local function ssh_command(plugin)
  local args = { "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ClearAllForwardings=yes" }
  if onon.platform.os ~= "windows" then
    for _, arg in ipairs({ "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/onon-%C", "-o", "ControlPersist=60" }) do
      args[#args + 1] = arg
    end
  end
  for _, arg in ipairs(plugin.ssh_args) do
    args[#args + 1] = arg
  end
  return plugin.ssh, args
end

-- read_dir lists path, host:path, on its host, calling callback as
-- plugin.fs:read_dir does, with the absolute host:path listed as dir.
-- It returns a handle to cancel it with.
function remote.read_dir(plugin, path, callback)
  local host, rest = remote.split(path)
  local command, args = ssh_command(plugin)
  args[#args + 1] = "--"
  args[#args + 1] = host
  args[#args + 1] = "sh -s"
  return plugin:job({
    command = command,
    args = args,
    stdin = LIST:format(cd_command(rest)),
    timeout_ms = 30000
  }, function(result)
    local dir, entries
    if result.code == 0 then
      dir, entries = parse(host, result.stdout)
    end
    if not dir then
      local detail = (result.stderr or ""):gsub("%s+$", ""):match("([^\n]*)$"):gsub("^sh: line %d+: ", "")
      if detail == "" then
        detail = result.timed_out and "timed out" or (result.error ~= "" and result.error or "unable to list")
      end
      callback({ success = false, error = host .. ": " .. detail, entries = {} })
      return
    end
    callback({ success = true, error = "", dir = dir, entries = entries })
  end)
end

return remote
