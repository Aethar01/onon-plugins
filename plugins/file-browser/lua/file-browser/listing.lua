-- The browser: one directory's entries, directories first, moved through
-- with the keys, sorted and filtered as asked.

local util = require("file-browser.util")
local tabs = require("file-browser.tabs")
local path_util = onon.path

local SORT_KEY = "sort"
local SORTS = { "name", "modified", "size" }
local SORT_LABELS = { name = "by name", modified = "newest first", size = "largest first" }
local COLUMNS = {
  type = { title = "Type", width = 70 },
  size = { title = "Size", width = 80, align = "right" },
  modified = { title = "Modified", width = 130, align = "right" }
}

return function(ctx)
  local plugin = ctx.plugin
  local listing = {}
  local view
  local state = {
    dir = nil,          -- the directory listed
    listing = {},       -- its entries, classified, before filtering and sorting
    error = nil,        -- why it could not be read
    entries = {},       -- row index -> entry
    selection = {},     -- directory -> path of the entry last selected in it
    pending_mark = nil, -- "set" after ", "jump" after '
    show_hidden = nil,
    sort = nil,
    scan = nil,
    generation = 0
  }

  local function classify(entry)
    local kind = "file"
    if entry.type == "directory" then
      kind = "directory"
    elseif entry.type == "file" and util.is_document(entry.name) then
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
      return entry.kind == "directory" and "" or util.human_size(entry.size)
    end
    if column == "modified" then
      return util.human_time(entry.modified)
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
      marker = entry.kind == "document" and tabs.marker(entry.path, open) or nil
    }
    local columns = plugin.columns
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
    local columns = plugin.columns
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

  -- The directory, and on the right of the header, muted, how it is
  -- listed. An onon without view details draws a title's parenthesised end
  -- there.
  local function set_title()
    local detail = SORT_LABELS[state.sort]
    if state.show_hidden then
      detail = detail .. " · hidden shown"
    end
    if view.set_detail then
      view:set_title(util.display_path(state.dir))
      view:set_detail(detail)
    else
      view:set_title(util.display_path(state.dir) .. " (" .. detail .. ")")
    end
  end

  local function remember_selection()
    local entry = state.entries[view:selected()]
    if state.dir and entry and entry.kind ~= "error" then
      state.selection[state.dir] = entry.path
    end
  end

  local function render()
    local open = tabs.open()
    local entries, rows = {}, {}
    local function add(entry)
      entries[#entries + 1] = entry
      rows[#rows + 1] = entry.kind == "error" and { text = entry.name, disabled = true } or row_for(entry, open)
    end

    if not util.is_root(state.dir) then
      add({ kind = "parent", name = "..", path = path_util.dirname(state.dir) })
    end
    if state.error then
      add({ kind = "error", name = state.error })
    else
      local shown = {}
      for _, entry in ipairs(state.listing) do
        if (state.show_hidden or not util.is_hidden(entry.name))
          and (plugin.show_other_files or entry.kind ~= "file") then
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

    -- Back where the user last was in this directory, else on the first
    -- entry.
    local index = (entries[1] and entries[1].kind == "parent" and #entries > 1) and 2 or 1
    local want = state.selection[state.dir]
    for i, entry in ipairs(entries) do
      if want and entry.path == want then
        index = i
        break
      end
    end
    index = #rows > 0 and index or 0
    view:set_selected(index)
    ctx.preview.show(entries[index])
  end

  local function cancel_scan()
    state.generation = state.generation + 1
    if state.scan then
      state.scan:cancel()
      state.scan = nil
    end
  end

  local function scan(path)
    path = util.normalize(plugin, path)
    cancel_scan()
    local generation = state.generation

    -- Symlinks are followed so a linked directory can be entered like any
    -- other; entries whose target is missing come back with a per-entry
    -- error.
    state.scan = plugin.fs:read_dir(path, { follow_symlinks = true }, function(result)
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
        if plugin.remember_directory then
          plugin.storage:set(util.LAST_DIRECTORY_KEY, path)
        end
      end
      render()
    end)
  end

  -- go moves to path, coming back to `from` selected, as going up does.
  local function go(path, from)
    remember_selection()
    if from then
      state.selection[path] = from
    end
    scan(path)
  end

  local function go_up()
    if state.dir and not util.is_root(state.dir) then
      go(path_util.dirname(state.dir), state.dir)
    end
  end

  function listing.selected_entry()
    return view and state.entries[view:selected()]
  end

  function listing.visible()
    return view ~= nil and view:visible()
  end

  -- follow makes the preview follow the browser again, as the find
  -- stacked over it closes.
  function listing.follow()
    ctx.preview.follow(view)
    ctx.preview.show(listing.selected_entry())
  end

  function listing.close()
    if listing.visible() then
      view:close()
    end
  end

  -- show_hidden says whether hidden entries are shown, for the find: as
  -- . left them, else as the option says.
  function listing.show_hidden()
    if state.show_hidden == nil then
      return plugin.show_hidden
    end
    return state.show_hidden
  end

  local function relist()
    remember_selection()
    render()
  end

  local keys = {
    ["h"] = go_up,
    ["-"] = go_up,
    ["<BS>"] = go_up,
    ["l"] = function()
      local entry = listing.selected_entry()
      if entry and entry.kind == "directory" then
        go(entry.path)
      elseif entry and entry.kind == "parent" then
        go_up()
      end
    end,
    ["<C-t>"] = function()
      local entry = listing.selected_entry()
      if entry and entry.kind == "document" then
        ctx.show_document(entry.path, true)
      end
    end,
    ["s"] = function()
      for i, sort in ipairs(SORTS) do
        if sort == state.sort then
          state.sort = SORTS[i % #SORTS + 1]
          break
        end
      end
      plugin.storage:set(SORT_KEY, state.sort)
      relist()
    end,
    ["."] = function()
      state.show_hidden = not state.show_hidden
      relist()
    end,
    ["p"] = function()
      ctx.preview.toggle(listing.selected_entry())
    end,
    ["<C-f>"] = function()
      ctx.find.open(state.dir, state.show_hidden)
    end,
    ['"'] = function()
      state.pending_mark = "set"
    end,
    ["'"] = function()
      state.pending_mark = "jump"
    end
  }
  keys["<S-CR>"] = keys["<C-t>"]
  keys["<C-p>"] = keys["p"]

  local function on_key(key)
    if state.pending_mark then
      local pending = state.pending_mark
      state.pending_mark = nil
      if #key == 1 then
        if pending == "set" then
          ctx.marks.set(key, state.dir)
        else
          local target = ctx.marks.jump(key, state.dir)
          if target then
            go(target)
          end
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
      ctx.show_document(entry.path, false)
    end
  end

  -- init reads the options, once config.lua has set them, as it does after
  -- requiring the plugin.
  local function init()
    if view then
      return
    end
    state.show_hidden = plugin.show_hidden
    local stored = plugin.storage:get(SORT_KEY)
    state.sort = SORT_LABELS[stored] and stored or (SORT_LABELS[plugin.sort] and plugin.sort or "name")
    view = onon.ui.create({
      id = "file-browser",
      title = "File Browser",
      searchable = true,
      empty = "Nothing here",
      columns = view_columns(),
      rows = {},
      on_select = on_select,
      on_selection_changed = function(index)
        ctx.preview.show(state.entries[index])
      end,
      on_key = on_key,
      on_close = function()
        remember_selection()
        cancel_scan()
        state.pending_mark = nil
        ctx.preview.release()
      end
    })
  end

  function listing.open(path)
    init()
    view:show()
    ctx.preview.follow(view)
    scan(path)
  end

  return listing
end
