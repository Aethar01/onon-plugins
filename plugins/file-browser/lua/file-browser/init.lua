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
      description = "Show entries whose names begin with a dot. `.` toggles it while browsing."
    },
    show_other_files = {
      type = "boolean",
      default = true,
      description = "List files onon cannot open, greyed out. False hides them."
    },
    remember_directory = {
      type = "boolean",
      default = true,
      description = "Reopen the browser in the directory it last visited."
    },
    columns = {
      type = "list",
      default = { "size", "modified" },
      description = 'Columns beside the name, in order, from "type", "size" and "modified". Empty shows names only.'
    },
    sort = {
      type = "string",
      default = "name",
      description = 'How listings sort until `s` changes it: "name", "modified" (newest first) or "size" (largest first).'
    },
    find_ignore = {
      type = "list",
      default = { "node_modules", "Library", "__pycache__" },
      description = "Directory names the find (<C-f>) does not look in. Hidden directories are skipped unless shown."
    },
    fzf = {
      type = "string",
      default = "fzf",
      description = "The fzf that ranks the find's matches: a name on PATH or a path, also looked for where it is usually installed. Empty, or none found, matches substrings."
    },
    find_max_directories = {
      type = "integer",
      default = 20000,
      description = "The most directories one find reads before it stops."
    }
  }
})

local path_util = onon.path
local platform = onon.platform

local LAST_DIRECTORY_KEY = "last-directory"
local SORT_KEY = "sort"
local SORTS = { "name", "modified", "size" }
local SORT_LABELS = { name = "by name", modified = "newest first", size = "largest first" }
local COLUMNS = {
  type = { title = "Type", width = 70 },
  size = { title = "Size", width = 80, align = "right" },
  modified = { title = "Modified", width = 130, align = "right" }
}
local FIND_IN_FLIGHT = 8
local FIND_FLUSH_MS = 100

local view, finder

local state = {
  dir = nil,          -- the directory listed
  listing = {},       -- its entries, classified, before filtering and sorting
  error = nil,        -- why it could not be read
  entries = {},       -- row index -> entry
  selection = {},     -- directory -> path of the entry last selected in it
  previous = nil,     -- the directory before the last mark jump, for ''
  pending_mark = nil, -- "set" after ", "jump" after '
  show_hidden = nil,
  sort = nil,
  scan = nil,
  generation = 0
}

local find = { generation = 0, ops = {}, found = {}, shown = {}, rel = {}, by_rel = {}, query = "" }

-- Helpers -------------------------------------------------------------------

local function is_root(path)
  return path_util.dirname(path) == path
end

local function is_hidden(name)
  return name:sub(1, 1) == "."
end

-- The engine decides what is openable, so the browser follows whatever formats
-- this build supports rather than assuming PDF.
local function is_document(name)
  return onon.formats.supports(name)
end

local function display_path(path)
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

local function relative_path(root, path)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

local function human_size(bytes)
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

local function human_time(unix)
  if not unix or unix <= 0 then
    return ""
  end
  if os.date("%Y", unix) == os.date("%Y") then
    return os.date("%d %b %H:%M", unix)
  end
  return os.date("%d %b %Y", unix)
end

local function document_directory()
  local path = onon.document.path or ""
  if path == "" then
    return nil
  end
  return path_util.dirname(path)
end

local function default_directory()
  if browser.start_path ~= "" then
    return browser.start_path
  end
  if browser.remember_directory then
    local stored = browser.storage:get(LAST_DIRECTORY_KEY)
    if type(stored) == "string" and stored ~= "" then
      return stored
    end
  end
  return document_directory() or platform.home_dir or path_util.absolute(".")
end

local function normalize(path)
  path = (path or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if path == "" then
    path = default_directory()
  end
  return path_util.absolute(path_util.expand_home(path))
end

-- Tabs ----------------------------------------------------------------------

-- Paths open in the window's tabs, to their tab index.
local function open_tabs()
  local open = {}
  for _, tab in ipairs(onon.tabs.list()) do
    if tab.path ~= "" then
      open[tab.path] = tab.index
    end
  end
  return open
end

local function tab_marker(path, open)
  if path == onon.document.path then
    return "●"
  end
  if open[path] then
    return "○"
  end
  return nil
end

-- Enter shows the tab a document is already open in, else opens it in place;
-- <C-t> and <S-CR> open it in a new tab. onon keeps one tab per document, so a
-- document already open is shown either way.
local function open_document(path, new_tab)
  if finder then
    finder:close()
  end
  if view then
    view:close()
  end
  if new_tab then
    onon.tabs.open(path)
    return
  end
  local index = open_tabs()[path]
  if index then
    onon.tabs.select(index)
  else
    onon.open(path)
  end
end

-- Listing -------------------------------------------------------------------

local function classify(entry)
  local kind = "file"
  if entry.type == "directory" then
    kind = "directory"
  elseif entry.type == "file" and is_document(entry.name) then
    kind = "document"
  end
  return {
    kind = kind,
    name = entry.name,
    path = entry.path,
    size = entry.size_bytes or 0,
    modified = entry.modified_unix or 0,
    unreadable = entry.error ~= ""
  }
end

-- Directories first; within each, the sort chosen, then names
-- case-insensitively so listings read the way a file manager does.
local function compare(left, right)
  local left_dir, right_dir = left.kind == "directory", right.kind == "directory"
  if left_dir ~= right_dir then
    return left_dir
  end
  if state.sort == "modified" and left.modified ~= right.modified then
    return left.modified > right.modified
  end
  if state.sort == "size" and not left_dir and left.size ~= right.size then
    return left.size > right.size
  end
  return left.name:lower() < right.name:lower()
end

local function cell(entry, column)
  if entry.kind == "parent" or entry.unreadable then
    return ""
  end
  if column == "type" then
    if entry.kind == "directory" then
      return "folder"
    end
    return (path_util.extension(entry.name):gsub("^%.", ""):upper())
  end
  if column == "size" then
    return entry.kind == "directory" and "" or human_size(entry.size)
  end
  if column == "modified" then
    return human_time(entry.modified)
  end
  return ""
end

local function row_for(entry, open)
  local name = entry.name
  if entry.kind == "directory" or entry.kind == "parent" then
    name = name .. "/"
  end
  -- The name alone is the value, so / matches names rather than the
  -- directory every entry shares.
  local row = {
    text = name,
    value = name,
    disabled = entry.kind == "file",
    marker = entry.kind == "document" and tab_marker(entry.path, open) or nil
  }
  local columns = browser.columns
  if #columns > 0 then
    row.cells = { name }
    for _, column in ipairs(columns) do
      row.cells[#row.cells + 1] = cell(entry, column)
    end
    if entry.unreadable then
      row.cells[#row.cells] = "unreadable"
    end
  elseif entry.unreadable then
    row.secondary = "unreadable"
  end
  return row
end

local function view_columns()
  local columns = browser.columns
  if #columns == 0 then
    return nil
  end
  local spec = { { title = "Name", width = "*" } }
  for _, name in ipairs(columns) do
    local column = COLUMNS[name]
    if column then
      spec[#spec + 1] = { title = column.title, width = column.width, align = column.align }
    else
      onon.log("warn", "file-browser: unknown column " .. tostring(name))
    end
  end
  return spec
end

-- The directory, and on the right of the header, muted, how it is listed.
-- An onon without view details draws a title's parenthesised end there.
local function set_title()
  local detail = SORT_LABELS[state.sort]
  if state.show_hidden then
    detail = detail .. " · hidden shown"
  end
  if view.set_detail then
    view:set_title(display_path(state.dir))
    view:set_detail(detail)
  else
    view:set_title(display_path(state.dir) .. " (" .. detail .. ")")
  end
end

local function remember_selection()
  local entry = state.entries[view:selected()]
  if state.dir and entry and entry.kind ~= "error" then
    state.selection[state.dir] = entry.path
  end
end

local function render()
  local open = open_tabs()
  local entries, rows = {}, {}
  local function add(entry)
    entries[#entries + 1] = entry
    rows[#rows + 1] = entry.kind == "error" and { text = entry.name, disabled = true } or row_for(entry, open)
  end

  if not is_root(state.dir) then
    add({ kind = "parent", name = "..", path = path_util.dirname(state.dir) })
  end
  if state.error then
    add({ kind = "error", name = state.error })
  else
    local shown = {}
    for _, entry in ipairs(state.listing) do
      if (state.show_hidden or not is_hidden(entry.name))
        and (browser.show_other_files or entry.kind ~= "file") then
        shown[#shown + 1] = entry
      end
    end
    table.sort(shown, compare)
    for _, entry in ipairs(shown) do
      add(entry)
    end
  end

  state.entries = entries
  set_title()
  view:set_rows(rows)

  -- Back where the user last was in this directory, else on the first entry.
  local index = (entries[1] and entries[1].kind == "parent" and #entries > 1) and 2 or 1
  local want = state.selection[state.dir]
  for i, entry in ipairs(entries) do
    if want and entry.path == want then
      index = i
      break
    end
  end
  view:set_selected(#rows > 0 and index or 0)
end

local function cancel_scan()
  state.generation = state.generation + 1
  if state.scan then
    state.scan:cancel()
    state.scan = nil
  end
end

local function scan(path)
  path = normalize(path)
  cancel_scan()
  local generation = state.generation

  -- Symlinks are followed so a linked directory can be entered like any other;
  -- entries whose target is missing come back with a per-entry error.
  state.scan = browser.fs:read_dir(path, { follow_symlinks = true }, function(result)
    if generation ~= state.generation then
      return
    end
    state.scan = nil
    state.dir = path
    state.listing, state.error = {}, nil

    if not result.success then
      local detail = result.error ~= "" and result.error or "unable to read directory"
      state.error = detail
      onon.message("file browser: " .. detail)
      onon.log("warn", "read_dir failed for " .. path .. ": " .. detail)
    else
      for _, entry in ipairs(result.entries) do
        state.listing[#state.listing + 1] = classify(entry)
      end
      if browser.remember_directory then
        browser.storage:set(LAST_DIRECTORY_KEY, path)
      end
    end
    render()
  end)
end

-- Moves to path, coming back to `from` selected, as going up does.
local function go(path, from)
  remember_selection()
  if from then
    state.selection[path] = from
  end
  scan(path)
end

local function go_up()
  if state.dir and not is_root(state.dir) then
    go(path_util.dirname(state.dir), state.dir)
  end
end

local function selected_entry()
  return state.entries[view:selected()]
end

-- Marks ---------------------------------------------------------------------

local function mark_key(name)
  return "mark:" .. name
end

local function set_mark(name)
  if not state.dir then
    return
  end
  browser.storage:set(mark_key(name), state.dir)
  onon.message("file browser: mark " .. name .. " → " .. display_path(state.dir))
end

local function jump_mark(name)
  local target
  if name == "'" then
    target = state.previous
  else
    target = browser.storage:get(mark_key(name))
  end
  if type(target) ~= "string" or target == "" then
    onon.message("file browser: no mark " .. name)
    return
  end
  state.previous = state.dir
  go(target)
end

-- Find ----------------------------------------------------------------------

-- Where fzf is usually installed, tried after PATH: an onon started from
-- the Dock or a desktop launcher often has a PATH without them.
local FZF_LOCATIONS = {
  "/opt/homebrew/bin/fzf", "/usr/local/bin/fzf", "/usr/bin/fzf",
  "/run/current-system/sw/bin/fzf", "~/.fzf/bin/fzf", "~/.local/bin/fzf"
}

-- fzf_command is nil until looked for, false when there is none, else the
-- command that runs it.
local fzf_command = nil

local function find_fzf(done)
  if fzf_command ~= nil then
    return done()
  end
  if browser.fzf == "" then
    fzf_command = false
    return done()
  end
  local candidates = { browser.fzf }
  for _, location in ipairs(FZF_LOCATIONS) do
    candidates[#candidates + 1] = path_util.expand_home(location)
  end
  local i = 0
  local function try()
    i = i + 1
    local command = candidates[i]
    if not command then
      fzf_command = false
      return done()
    end
    browser:job({ command = command, args = { "--version" }, timeout_ms = 2000 }, function(result)
      if result.success then
        fzf_command = command
        done()
      else
        try()
      end
    end)
  end
  try()
end

local function stop_find()
  find.generation = find.generation + 1
  for op in pairs(find.ops) do
    op:cancel()
  end
  find.ops = {}
  if find.timer then
    find.timer:cancel()
    find.timer = nil
  end
  if find.job then
    find.job:cancel()
    find.job = nil
  end
end

local function set_find_detail()
  if not finder.set_detail then
    return -- an onon without view details
  end
  local parts = {}
  if find.walking then
    parts[#parts + 1] = "searching"
  end
  if find.fzf and find.query ~= "" then
    parts[#parts + 1] = #find.shown .. "/" .. #find.found
  else
    parts[#parts + 1] = tostring(#find.found)
  end
  finder:set_detail(table.concat(parts, " · "))
end

local function show_find_rows()
  if not find.fzf or find.query == "" then
    find.shown = find.found -- the view filters them, or nothing does
  end
  local rows, open = {}, open_tabs()
  for i, path in ipairs(find.shown) do
    local rel = find.rel[path]
    rows[i] = { text = rel, value = rel, marker = tab_marker(path, open) }
  end
  finder:set_rows(rows)
  set_find_detail()
end

-- Ranks the documents found against the query with fzf, best first. One
-- fzf runs at a time: a query typed or documents found while it runs are
-- ranked again once it is done.
local function rank()
  if find.query == "" then
    return show_find_rows()
  end
  if find.job then
    find.again = true
    return
  end
  if find.input_count ~= #find.found then
    -- Joined a chunk at a time: table.concat of thousands of strings at
    -- once overflows the Lua registry.
    local chunks, chunk = {}, {}
    for _, path in ipairs(find.found) do
      chunk[#chunk + 1] = find.rel[path]
      if #chunk == 500 then
        chunks[#chunks + 1] = table.concat(chunk, "\n")
        chunk = {}
      end
    end
    chunks[#chunks + 1] = table.concat(chunk, "\n")
    find.input, find.input_count = table.concat(chunks, "\n"), #find.found
  end
  local generation, query = find.generation, find.query
  find.job = browser:job({
    command = fzf_command,
    args = { "--filter", query },
    stdin = find.input
  }, function(result)
    if generation ~= find.generation then
      return
    end
    find.job = nil
    -- fzf exits 1 when nothing matches, and 2 or worse on an error.
    if not result.success and result.code ~= 1 then
      onon.log("warn", "file-browser: fzf failed: " .. (result.error ~= "" and result.error or result.stderr))
      onon.message("file browser: fzf failed; matching substrings instead")
      fzf_command = false
      return
    end
    local shown = {}
    for rel in result.stdout:gmatch("[^\n]+") do
      shown[#shown + 1] = find.by_rel[rel]
    end
    if query == find.query then
      find.shown = shown
      show_find_rows()
    end
    if find.again then
      find.again = false
      rank()
    end
  end)
end

-- Walks root breadth first, a few directories at a time, so shallow documents
-- come first and the list fills as it goes rather than when the walk ends.
local function start_find(root)
  stop_find()
  local generation = find.generation
  local ignore = {}
  for _, name in ipairs(browser.find_ignore) do
    ignore[name] = true
  end
  local show_hidden = state.show_hidden
  find.found, find.shown, find.rel, find.by_rel = {}, {}, {}, {}
  find.input, find.input_count, find.again = "", 0, false
  find.walking = true
  -- head and tail index the queue, whose taken slots are cleared.
  local queue, head, tail, active, read = { root }, 1, 1, 0, 0
  local dirty = false

  local function flush()
    if dirty and generation == find.generation then
      dirty = false
      if find.fzf then
        rank()
      else
        show_find_rows()
      end
    end
  end

  local function pump()
    while active < FIND_IN_FLIGHT and head <= tail and read < browser.find_max_directories do
      local dir = queue[head]
      queue[head] = nil
      head = head + 1
      active = active + 1
      read = read + 1
      local op
      -- Links are not followed, so a link back up the tree cannot loop.
      op = browser.fs:read_dir(dir, { follow_symlinks = false }, function(result)
        if generation ~= find.generation then
          return
        end
        find.ops[op] = nil
        active = active - 1
        if result.success then
          for _, entry in ipairs(result.entries) do
            local name = entry.name
            if show_hidden or not is_hidden(name) then
              if entry.type == "directory" then
                if not ignore[name] then
                  tail = tail + 1
                  queue[tail] = entry.path
                end
              elseif (entry.type == "file" or entry.type == "symlink") and is_document(name) then
                local rel = relative_path(root, entry.path)
                find.found[#find.found + 1] = entry.path
                find.rel[entry.path], find.by_rel[rel] = rel, entry.path
                dirty = true
              end
            end
          end
        end
        pump()
      end)
      find.ops[op] = true
    end
    if active == 0 then
      if find.timer then
        find.timer:cancel()
        find.timer = nil
      end
      find.walking = false
      dirty = true
      flush()
      if read >= browser.find_max_directories and head <= tail then
        onon.message("file browser: find stopped after " .. read .. " directories")
      end
    end
  end

  local function tick()
    flush()
    find.timer = browser.timer:after(FIND_FLUSH_MS, tick)
  end
  find.timer = browser.timer:after(FIND_FLUSH_MS, tick)
  pump()
end

local function open_find(root)
  root = normalize(root or state.dir)
  find_fzf(function()
    -- With fzf, the plugin ranks the rows itself; without, the view
    -- filters them by substring.
    find.fzf = fzf_command and true or false
    find.query = ""
    local function selected_path(index)
      return find.shown[index]
    end
    finder = onon.ui.create({
      id = "file-browser-find",
      title = "Find in " .. display_path(root),
      prompt = "Find",
      stack = true,
      filter = not find.fzf,
      empty = "no documents found",
      rows = {},
      on_query_changed = function(query)
        find.query = query:gsub("^%s+", ""):gsub("%s+$", "")
        if find.fzf then
          rank()
        end
      end,
      on_select = function(index)
        local path = selected_path(index)
        if path then
          open_document(path, false)
        end
      end,
      on_key = function(key)
        if key == "<C-t>" or key == "<S-CR>" then
          local path = selected_path(finder:selected())
          if path then
            open_document(path, true)
          end
          return true
        end
      end,
      on_close = stop_find
    })
    finder:show()
    start_find(root)
  end)
end

-- The browser ---------------------------------------------------------------

local keys = {
  ["h"] = go_up,
  ["-"] = go_up,
  ["<BS>"] = go_up,
  ["l"] = function()
    local entry = selected_entry()
    if entry and entry.kind == "directory" then
      go(entry.path)
    elseif entry and entry.kind == "parent" then
      go_up()
    end
  end,
  ["<C-t>"] = function()
    local entry = selected_entry()
    if entry and entry.kind == "document" then
      open_document(entry.path, true)
    end
  end,
  ["s"] = function()
    for i, sort in ipairs(SORTS) do
      if sort == state.sort then
        state.sort = SORTS[i % #SORTS + 1]
        break
      end
    end
    browser.storage:set(SORT_KEY, state.sort)
    remember_selection()
    render()
  end,
  ["."] = function()
    state.show_hidden = not state.show_hidden
    remember_selection()
    render()
  end,
  ["<C-f>"] = function()
    open_find(state.dir)
  end,
  ['"'] = function()
    state.pending_mark = "set"
  end,
  ["'"] = function()
    state.pending_mark = "jump"
  end
}
keys["<S-CR>"] = keys["<C-t>"]

local function on_key(key)
  if state.pending_mark then
    local pending = state.pending_mark
    state.pending_mark = nil
    if #key == 1 then
      if pending == "set" then
        set_mark(key)
      else
        jump_mark(key)
      end
    end
    return true -- anything else, Escape among them, just cancels
  end
  local run = keys[key]
  if run and state.dir then
    run()
    return true
  end
end

local function on_select(index)
  local entry = state.entries[index]
  if not entry then
    return
  end
  if entry.kind == "parent" then
    go_up()
  elseif entry.kind == "directory" then
    view:set_query("")
    go(entry.path)
  elseif entry.kind == "document" then
    open_document(entry.path, false)
  end
end

local function create_view()
  view = onon.ui.create({
    id = "file-browser",
    title = "File Browser",
    searchable = true,
    empty = "Nothing here",
    columns = view_columns(),
    rows = {},
    on_select = on_select,
    on_key = on_key,
    on_close = function()
      remember_selection()
      cancel_scan()
      state.pending_mark = nil
    end
  })
end

-- Options are read when the browser first opens, as config.lua sets them
-- after requiring the plugin.
local function init()
  if state.show_hidden == nil then
    state.show_hidden = browser.show_hidden
  end
  if not state.sort then
    local stored = browser.storage:get(SORT_KEY)
    state.sort = SORT_LABELS[stored] and stored or (SORT_LABELS[browser.sort] and browser.sort or "name")
  end
end

function browser.open(path)
  init()
  if not view then
    create_view()
  end
  view:show()
  scan(path)
end

function browser.find(path)
  init()
  open_find(path or document_directory() or default_directory())
end

browser:register_action("browse", {
  description = "Open the document file browser."
}, function()
  browser.open()
end)

browser:register_action("find", {
  description = "Find documents under the directory of the one open, typing to filter."
}, function()
  browser.find()
end)

browser:register_command("open", {
  description = ":file-browser-open [directory] - Browse for a document."
}, function(context)
  browser.open(context.raw)
end)

browser:register_command("find", {
  description = ":file-browser-find [directory] - Find documents under a directory."
}, function(context)
  browser.find(context.raw ~= "" and context.raw or nil)
end)

return browser
