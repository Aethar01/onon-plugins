-- Helpers with no state of their own: paths, sizes and dates as the
-- browser shows them, and where it starts.

local path_util = onon.path
local platform = onon.platform

local util = {}

util.LAST_DIRECTORY_KEY = "last-directory"

function util.is_root(path)
  return path_util.dirname(path) == path
end

function util.is_hidden(name)
  return name:sub(1, 1) == "."
end

-- The engine decides what is openable, so the browser follows whatever formats
-- this build supports rather than assuming PDF.
function util.is_document(name)
  return onon.formats.supports(name)
end

function util.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.display_path(path)
  local home = platform.home_dir
  if home and home ~= "" then
    if path == home then
      return "~"
    end
    if path:sub(1, #home + 1) == home .. "/" then
      return "~" .. path:sub(#home + 1)
    end
  end
  return path
end

function util.relative_path(root, path)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

function util.human_size(bytes)
  if bytes < 1024 then
    return string.format("%d B", bytes)
  end
  local size = bytes / 1024
  for _, unit in ipairs({ "KB", "MB", "GB", "TB" }) do
    if size < 1024 or unit == "TB" then
      return string.format("%.1f %s", size, unit)
    end
    size = size / 1024
  end
end

function util.human_time(unix)
  if not unix or unix <= 0 then
    return ""
  end
  if os.date("%Y", unix) == os.date("%Y") then
    return os.date("%d %b %H:%M", unix)
  end
  return os.date("%d %b %Y", unix)
end

function util.document_directory()
  local path = onon.document.path or ""
  if path == "" then
    return nil
  end
  return path_util.dirname(path)
end

-- default_directory is where plugin's browser starts: start_path, else the
-- directory it last visited, the document's, or home.
function util.default_directory(plugin)
  if plugin.start_path ~= "" then
    return plugin.start_path
  end
  if plugin.remember_directory then
    local stored = plugin.storage:get(util.LAST_DIRECTORY_KEY)
    if type(stored) == "string" and stored ~= "" then
      return stored
    end
  end
  return util.document_directory() or platform.home_dir or path_util.absolute(".")
end

-- normalize makes path absolute, ~ expanded, the default directory if empty.
function util.normalize(plugin, path)
  path = util.trim(path or "")
  if path == "" then
    path = util.default_directory(plugin)
  end
  return path_util.absolute(path_util.expand_home(path))
end

return util
