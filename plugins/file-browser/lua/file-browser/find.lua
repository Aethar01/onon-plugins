-- The find (<C-f>): every document under a directory, read breadth first a
-- few directories at a time so the list fills as it goes, filtered as the
-- query is typed: ranked by fzf, best first, when it is installed, else by
-- substring.

local util = require("file-browser.util")
local tabs = require("file-browser.tabs")
local path_util = onon.path

local IN_FLIGHT = 8
local FLUSH_MS = 100

-- Where fzf is usually installed, tried after PATH: an onon started from
-- the Dock or a desktop launcher often has a PATH without them.
local FZF_LOCATIONS = {
  "/opt/homebrew/bin/fzf", "/usr/local/bin/fzf", "/usr/bin/fzf",
  "/run/current-system/sw/bin/fzf", "~/.fzf/bin/fzf", "~/.local/bin/fzf"
}

return function(ctx)
  local plugin = ctx.plugin
  local find = {}
  local view
  -- fzf_command is nil until looked for, false when there is none, else
  -- the command that runs it.
  local fzf_command = nil
  local s = { generation = 0, ops = {}, found = {}, shown = {}, rel = {}, by_rel = {}, query = "" }

  local function find_fzf(done)
    if fzf_command ~= nil then
      return done()
    end
    if plugin.fzf == "" then
      fzf_command = false
      return done()
    end
    local candidates = { plugin.fzf }
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
      plugin:job({ command = command, args = { "--version" }, timeout_ms = 2000 }, function(result)
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

  local function stop()
    s.generation = s.generation + 1
    for op in pairs(s.ops) do
      op:cancel()
    end
    s.ops = {}
    if s.timer then
      s.timer:cancel()
      s.timer = nil
    end
    if s.job then
      s.job:cancel()
      s.job = nil
    end
  end

  -- entry is the row at index as the preview takes it.
  local function entry(index)
    local path = s.shown[index]
    if path then
      return { kind = "document", name = s.rel[path], path = path }
    end
  end

  function find.visible()
    return view ~= nil and view:visible()
  end

  function find.selected_entry()
    return view and entry(view:selected())
  end

  function find.close()
    if find.visible() then
      view:close()
    end
  end

  local function set_detail()
    if not view.set_detail then
      return -- an onon without view details
    end
    local parts = {}
    if s.walking then
      parts[#parts + 1] = "searching"
    end
    if s.fzf and s.query ~= "" then
      parts[#parts + 1] = #s.shown .. "/" .. #s.found
    else
      parts[#parts + 1] = tostring(#s.found)
    end
    view:set_detail(table.concat(parts, " · "))
  end

  local function show_rows()
    if not s.fzf or s.query == "" then
      s.shown = s.found -- the view filters them, or nothing does
    end
    local rows, open = {}, tabs.open()
    for i, path in ipairs(s.shown) do
      local rel = s.rel[path]
      rows[i] = { text = rel, value = rel, marker = tabs.marker(path, open) }
    end
    view:set_rows(rows)
    set_detail()
    ctx.preview.show(entry(view:selected()))
  end

  -- rank ranks the documents found against the query with fzf, best
  -- first. One fzf runs at a time: a query typed or documents found while
  -- it runs are ranked again once it is done.
  local function rank()
    if s.query == "" then
      return show_rows()
    end
    if s.job then
      s.again = true
      return
    end
    if s.input_count ~= #s.found then
      -- Joined a chunk at a time: table.concat of thousands of strings at
      -- once overflows the Lua registry.
      local chunks, chunk = {}, {}
      for _, path in ipairs(s.found) do
        chunk[#chunk + 1] = s.rel[path]
        if #chunk == 500 then
          chunks[#chunks + 1] = table.concat(chunk, "\n")
          chunk = {}
        end
      end
      chunks[#chunks + 1] = table.concat(chunk, "\n")
      s.input, s.input_count = table.concat(chunks, "\n"), #s.found
    end
    local generation, query = s.generation, s.query
    s.job = plugin:job({
      command = fzf_command,
      args = { "--filter", query },
      stdin = s.input
    }, function(result)
      if generation ~= s.generation then
        return
      end
      s.job = nil
      -- fzf exits 1 when nothing matches, and 2 or worse on an error.
      if not result.success and result.code ~= 1 then
        onon.log("warn", "file-browser: fzf failed: " .. (result.error ~= "" and result.error or result.stderr))
        onon.message("file browser: fzf failed; matching substrings instead")
        fzf_command = false
        return
      end
      local shown = {}
      for rel in result.stdout:gmatch("[^\n]+") do
        shown[#shown + 1] = s.by_rel[rel]
      end
      if query == s.query then
        s.shown = shown
        show_rows()
      end
      if s.again then
        s.again = false
        rank()
      end
    end)
  end

  local function walk(root, show_hidden)
    stop()
    local generation = s.generation
    local ignore = {}
    for _, name in ipairs(plugin.find_ignore) do
      ignore[name] = true
    end
    s.found, s.shown, s.rel, s.by_rel = {}, {}, {}, {}
    s.input, s.input_count, s.again = "", 0, false
    s.walking = true
    -- head and tail index the queue, whose taken slots are cleared.
    local queue, head, tail, active, read = { root }, 1, 1, 0, 0
    local dirty = false

    local function flush()
      if dirty and generation == s.generation then
        dirty = false
        if s.fzf then
          rank()
        else
          show_rows()
        end
      end
    end

    local function pump()
      while active < IN_FLIGHT and head <= tail and read < plugin.find_max_directories do
        local dir = queue[head]
        queue[head] = nil
        head = head + 1
        active = active + 1
        read = read + 1
        local op
        -- Links are not followed, so a link back up the tree cannot loop.
        op = plugin.fs:read_dir(dir, { follow_symlinks = false }, function(result)
          if generation ~= s.generation then
            return
          end
          s.ops[op] = nil
          active = active - 1
          if result.success then
            for _, item in ipairs(result.entries) do
              local name = item.name
              if show_hidden or not util.is_hidden(name) then
                if item.type == "directory" then
                  if not ignore[name] then
                    tail = tail + 1
                    queue[tail] = item.path
                  end
                elseif (item.type == "file" or item.type == "symlink") and util.is_document(name) then
                  local rel = util.relative_path(root, item.path)
                  s.found[#s.found + 1] = item.path
                  s.rel[item.path], s.by_rel[rel] = rel, item.path
                  dirty = true
                end
              end
            end
          end
          pump()
        end)
        s.ops[op] = true
      end
      if active == 0 then
        if s.timer then
          s.timer:cancel()
          s.timer = nil
        end
        s.walking = false
        dirty = true
        flush()
        if read >= plugin.find_max_directories and head <= tail then
          onon.message("file browser: find stopped after " .. read .. " directories")
        end
      end
    end

    local function tick()
      flush()
      s.timer = plugin.timer:after(FLUSH_MS, tick)
    end
    s.timer = plugin.timer:after(FLUSH_MS, tick)
    pump()
  end

  -- open finds the documents under root, hidden ones too with show_hidden,
  -- over the browser if it is open.
  function find.open(root, show_hidden)
    root = util.normalize(plugin, root)
    find_fzf(function()
      -- With fzf, the find ranks the rows itself; without, the view
      -- filters them by substring.
      s.fzf = fzf_command and true or false
      s.query = ""
      view = onon.ui.create({
        id = "file-browser-find",
        title = "Find in " .. util.display_path(root),
        prompt = "Find",
        stack = true,
        filter = not s.fzf,
        empty = "no documents found",
        rows = {},
        on_selection_changed = function(index)
          ctx.preview.show(entry(index))
        end,
        on_query_changed = function(query)
          s.query = util.trim(query)
          if s.fzf then
            rank()
          end
        end,
        on_select = function(index)
          local path = s.shown[index]
          if path then
            ctx.show_document(path, false)
          end
        end,
        on_key = function(key)
          if key == "<C-t>" or key == "<S-CR>" then
            local path = s.shown[view:selected()]
            if path then
              ctx.show_document(path, true)
            end
            return true
          end
          if key == "<C-p>" then
            ctx.preview.toggle(find.selected_entry())
            return true
          end
        end,
        on_close = function()
          stop()
          if ctx.listing.visible() then
            ctx.listing.follow()
          else
            ctx.preview.release()
          end
        end
      })
      view:show()
      ctx.preview.follow(view)
      walk(root, show_hidden)
    end)
  end

  return find
end
