local browser = onon.plugin.register("file-browser", {
  options = {
    start_path = {
      type = "path",
      default = "",
      description = "Default directory. Empty means the last visited directory, the document directory, or home."
    },
    show_hidden = {
      type = "boolean",
      default = false,
      description = "Show entries whose names begin with a dot."
    },
    remember_directory = {
      type = "boolean",
      default = true,
      description = "Reopen the browser in the directory it last visited."
    }
  }
})

local path_util = onon.path
local platform = onon.platform

local view
local entries = {}
local scan_operation
local scan_generation = 0

local LAST_DIRECTORY_KEY = "last-directory"

local function is_root(path)
  return path_util.dirname(path) == path
end

-- The engine decides what is openable, so the browser follows whatever formats
-- this build supports rather than assuming PDF.
local function is_document(name)
  return onon.formats.supports(name)
end

local function is_hidden(name)
  return name:sub(1, 1) == "."
end

local function document_directory()
  local path = onon.document.path or ""
  if path == "" then
    return nil
  end
  return path_util.dirname(path)
end

local function remembered_directory()
  if not browser.remember_directory then
    return nil
  end
  local stored = browser.storage:get(LAST_DIRECTORY_KEY)
  if type(stored) == "string" and stored ~= "" then
    return stored
  end
  return nil
end

local function default_directory()
  if browser.start_path ~= "" then
    return browser.start_path
  end
  return remembered_directory()
    or document_directory()
    or platform.home_dir
    or path_util.absolute(".")
end

-- Directories sort first, then names case-insensitively so listings read the
-- way a file manager does rather than in raw filesystem order.
local function compare_entries(left, right)
  if left.kind ~= right.kind then
    return left.kind == "directory"
  end
  return left.name:lower() < right.name:lower()
end

local function classify(entry)
  if entry.type == "directory" then
    return "directory"
  end
  if entry.type == "file" and is_document(entry.name) then
    return "document"
  end
  return "file"
end

local function row_for_entry(entry)
  if entry.kind == "directory" then
    return { text = entry.name .. "/", value = entry.path, secondary = "directory" }
  end
  if entry.kind == "document" then
    return { text = entry.name, value = entry.path, secondary = entry.detail or "document" }
  end
  return { text = entry.name, value = entry.path, secondary = entry.detail or "file", disabled = true }
end

-- The header shows the directory, and how far reading it has got or how
-- many entries it holds, muted after it.
local function set_status(path, text)
  entries = {}
  view:set_title(path .. " (" .. text .. ")")
  view:set_rows({})
end

local function human_size(bytes)
  if bytes < 1024 then
    return string.format("%d B", bytes)
  end
  local units = { "KB", "MB", "GB", "TB" }
  local size = bytes / 1024
  for _, unit in ipairs(units) do
    if size < 1024 or unit == "TB" then
      return string.format("%.1f %s", size, unit)
    end
    size = size / 1024
  end
end

-- "PDF · 1.2 MB" reads better than a bare size once more than one format is
-- listed, so the extension leads the secondary column.
local function format_label(entry)
  local extension = path_util.extension(entry.name):gsub("^%.", ""):upper()
  local size = human_size(entry.size_bytes)
  if extension == "" then
    return size
  end
  return extension .. " · " .. size
end

local function render(path, found)
  entries = {}
  local rows = {}
  view:set_title(path .. " (" .. tostring(#found) .. " entries)")
  if not is_root(path) then
    local parent = path_util.dirname(path)
    entries[#entries + 1] = { kind = "directory", name = "..", path = parent }
    rows[#rows + 1] = { text = "../", value = parent, secondary = "parent" }
  end
  for _, entry in ipairs(found) do
    entries[#entries + 1] = entry
    rows[#rows + 1] = row_for_entry(entry)
  end
  view:set_rows(rows)
  view:set_selected(1)
end

local function scan(path)
  path = (path or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if path == "" then
    path = default_directory()
  end
  path = path_util.absolute(path_util.expand_home(path))

  scan_generation = scan_generation + 1
  local generation = scan_generation
  if scan_operation then
    scan_operation:cancel()
    scan_operation = nil
  end
  set_status(path, "loading")

  -- Symlinks are followed so a linked directory can be entered like any other;
  -- entries whose target is missing come back with a per-entry error.
  scan_operation = browser.fs:read_dir(path, { follow_symlinks = true }, function(result)
    if generation ~= scan_generation then
      return
    end
    scan_operation = nil

    if not result.success then
      local detail = result.error
      if detail == "" then
        detail = "unable to read directory"
      end
      set_status(path, detail)
      onon.message("file browser: " .. detail)
      onon.log("warn", "read_dir failed for " .. path .. ": " .. detail)
      return
    end

    local found = {}
    for _, entry in ipairs(result.entries) do
      if browser.show_hidden or not is_hidden(entry.name) then
        local kind = classify(entry)
        local detail
        if entry.error ~= "" then
          detail = "unreadable"
        elseif kind == "document" then
          detail = format_label(entry)
        end
        found[#found + 1] = {
          kind = kind,
          name = entry.name,
          path = entry.path,
          detail = detail
        }
      end
    end
    table.sort(found, compare_entries)

    render(path, found)
    if browser.remember_directory then
      browser.storage:set(LAST_DIRECTORY_KEY, path)
    end
  end)
end

view = onon.ui.create({
  id = "file-browser",
  title = "File Browser",
  searchable = true,
  empty = "Nothing here",
  rows = {},
  on_select = function(index)
    local entry = entries[index]
    if not entry then
      return
    end
    if entry.kind == "directory" then
      view:set_query("")
      scan(entry.path)
      return
    end
    if entry.kind == "document" then
      view:close()
      onon.open(entry.path)
    end
  end,
  on_close = function()
    scan_generation = scan_generation + 1
    if scan_operation then
      scan_operation:cancel()
      scan_operation = nil
    end
  end
})

function browser.open(path)
  view:show()
  scan(path)
end

browser:register_action("browse", {
  description = "Open the document file browser."
}, function()
  browser.open()
end)

browser:register_command("open", {
  description = ":file-browser-open [directory] - Browse for a document."
}, function(context)
  browser.open(context.raw)
end)

return browser
