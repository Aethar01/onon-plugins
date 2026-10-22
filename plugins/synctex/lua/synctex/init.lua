-- SyncTeX support for onon.
--
-- Inverse search (PDF -> editor): modifier-click a spot in the page and the
-- .tex line that produced it opens in your editor.
--
-- Forward search (editor -> PDF): the editor asks a running onon to run this
-- plugin's command, and the lookup happens here:
--
--   onon --unique --command "synctex-forward chapter1.tex:142" paper.pdf
--
-- Keeping the lookup in the plugin means an editor integration is one line and
-- never has to parse synctex output itself.
--
-- Both directions run the `synctex` command line tool, so nothing here depends
-- on a particular TeX distribution.

local synctex = onon.plugin.register("synctex", {
  options = {
    command = {
      type = "string",
      default = "synctex",
      description = "The synctex executable to run."
    },
    editor = {
      type = "string",
      default = "",
      description = "Program to open the source location. Empty reports the location instead."
    },
    editor_args = {
      type = "list",
      default = { "+%l", "%f" },
      description = "Arguments for the editor. %f is the file, %l the line, %c the column."
    },
    source = {
      type = "path",
      default = "",
      description = "Main .tex for forward search when only a line is given. Empty derives it from the document name."
    },
    click_button = {
      type = "string",
      default = "left",
      description = "Mouse button for inverse search: left, middle, or right."
    },
    click_modifier = {
      type = "string",
      default = "ctrl",
      description = "Modifier held for inverse search: ctrl, shift, alt, gui, or none."
    },
    timeout_ms = {
      type = "integer",
      default = 5000,
      description = "How long to wait for the synctex command."
    }
  }
})

local path_util = onon.path

local last_click = nil
local pending = nil

local function fail(message)
  onon.message("synctex: " .. message)
  onon.log("warn", message)
end

local function document_path()
  local path = onon.document.path or ""
  if path == "" then
    return nil
  end
  return path
end

-- synctex measures from the top-left corner of the page in points. A page whose
-- box does not start at the origin must be shifted, otherwise every lookup is
-- off by the crop offset.
local function page_origin(page)
  local ok, info = pcall(onon.document.page_info, page)
  if not ok or not info or not info.bounds then
    return 0, 0
  end
  return info.bounds.x0, info.bounds.y0
end

-- The .synctex file sits beside the PDF, gzipped or not. Knowing which is
-- missing turns "nothing happened" into an actionable message.
local function synctex_file_candidates(pdf_path)
  local base = pdf_path:gsub("%.[^.]*$", "")
  return { base .. ".synctex.gz", base .. ".synctex" }
end

-- synctex prints "Key:value" lines between "SyncTeX result begin" and "end",
-- repeating the block once per match, best match first.
--
-- Keys are case-sensitive and deliberately so: "h"/"H" and "w"/"W" are
-- different fields, so nothing here may fold case. Records are split on the key
-- that starts each block ("Input" for edit, "Page" for view) rather than on a
-- repeated key, which would break on those pairs.
local function parse_records(output, start_key)
  local records = {}
  local current = nil
  local inside = false
  for line in output:gmatch("[^\r\n]+") do
    if line:match("^SyncTeX result begin") then
      inside = true
    elseif line:match("^SyncTeX result end") then
      inside = false
    elseif inside then
      local key, value = line:match("^(%a+):(.*)$")
      if key then
        if key == start_key then
          if current then
            records[#records + 1] = current
          end
          current = {}
        end
        if current then
          current[key] = value
        end
      end
    end
  end
  if current then
    records[#records + 1] = current
  end
  return records
end

local function open_in_editor(file, line, column)
  if synctex.editor == "" then
    onon.message(string.format("synctex: %s:%d", file, line))
    return
  end
  local args = {}
  for _, template in ipairs(synctex.editor_args) do
    local value = template:gsub("%%f", file)
    value = value:gsub("%%l", tostring(line))
    value = value:gsub("%%c", tostring(column))
    args[#args + 1] = value
  end
  synctex:job({ command = synctex.editor, args = args, timeout_ms = synctex.timeout_ms }, function(result)
    -- Editors that take over the terminal or detach report no output; only a
    -- genuine launch failure is worth surfacing.
    if not result.success and result.error ~= "" then
      fail("editor: " .. result.error)
    end
  end)
end

-- Only the newest request matters; an earlier lookup still running is dropped.
local function run_synctex(args, start_key, on_record)
  if pending then
    pending:cancel()
    pending = nil
  end
  pending = synctex:job({
    command = synctex.command,
    args = args,
    timeout_ms = synctex.timeout_ms
  }, function(result)
    pending = nil
    if not result.success then
      local detail = result.error
      if detail == "" then
        detail = (result.stderr or ""):gsub("^%s+", ""):gsub("%s+$", "")
      end
      if detail == "" and result.timed_out then
        detail = "synctex timed out"
      end
      if detail == "" then
        detail = "synctex exited with code " .. tostring(result.code)
      end
      fail(detail)
      return
    end
    on_record(parse_records(result.stdout, start_key)[1])
  end)
end

local function inverse_at(page, x, y)
  local pdf_path = document_path()
  if not pdf_path then
    fail("no document is open")
    return
  end
  local origin_x, origin_y = page_origin(page)
  local locator = string.format("%d:%.6f:%.6f:%s", page, x - origin_x, y - origin_y, pdf_path)
  run_synctex({ "edit", "-o", locator }, "Input", function(record)
    if not record or not record.Input then
      fail("no source position for that point")
      return
    end
    local file = record.Input:gsub("^%s+", ""):gsub("%s+$", "")
    -- Some TeX distributions prefix the input path with the file scheme.
    file = file:gsub("^file://", "")
    local line = tonumber(record.Line) or 1
    local column = tonumber(record.Column) or 0
    if column < 0 then
      -- synctex reports -1 when it has no column.
      column = 0
    end
    onon.log("info", string.format("inverse %s:%d -> %s:%d", pdf_path, page, file, line))
    open_in_editor(file, line, column)
  end)
end

-- A relative source belongs to the document being viewed, not to whatever
-- directory onon happens to have been started in.
local function resolve_source(file, pdf_path)
  file = path_util.expand_home(file)
  if path_util.is_absolute(file) then
    return path_util.clean(file)
  end
  return path_util.join(path_util.dirname(pdf_path), file)
end

local function default_source(pdf_path)
  if synctex.source ~= "" then
    return resolve_source(synctex.source, pdf_path)
  end
  return pdf_path:gsub("%.[^.]*$", "") .. ".tex"
end

local function forward_to(source, line, column)
  local pdf_path = document_path()
  if not pdf_path then
    fail("no document is open")
    return
  end
  local locator = string.format("%d:%d:%s", line, column, source)
  run_synctex({ "view", "-i", locator, "-o", pdf_path }, "Page", function(record)
    if not record or not record.Page then
      fail("no PDF position for " .. source .. ":" .. tostring(line))
      return
    end
    local page = tonumber(record.Page)
    if not page then
      fail("synctex returned an unreadable page")
      return
    end
    -- x/y are the precise hit point; h/v are the enclosing box corner.
    local x = tonumber(record.x) or tonumber(record.h) or 0
    local y = tonumber(record.y) or tonumber(record.v) or 0
    local origin_x, origin_y = page_origin(page)
    onon.log("info", string.format("forward %s:%d -> page %d", source, line, page))
    onon.goto_document_point({ page = page, x = x + origin_x, y = y + origin_y })
  end)
end

-- "file.tex:120:5", "file.tex:120", or a bare "120" against the default source.
local function parse_target(raw)
  raw = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "" then
    return nil, "usage: :synctex-forward [file.tex:]line[:column]"
  end
  local pdf_path = document_path()
  if not pdf_path then
    return nil, "no document is open"
  end
  local line_only = raw:match("^(%d+)$")
  if line_only then
    return { source = default_source(pdf_path), line = tonumber(line_only), column = 0 }
  end
  local file, line, column = raw:match("^(.+):(%d+):(%d+)$")
  if not file then
    file, line = raw:match("^(.+):(%d+)$")
    column = "0"
  end
  if not file then
    return nil, "could not read a line number from " .. raw
  end
  return { source = resolve_source(file, pdf_path), line = tonumber(line), column = tonumber(column) }
end

local function modifier_held(modifiers)
  local wanted = synctex.click_modifier:lower()
  if wanted == "none" then
    return true
  end
  return modifiers[wanted] == true
end

synctex:on("mouse_button_pre", function(event)
  if event.phase ~= "down" or not event.inside_document then
    return
  end
  if event.button ~= synctex.click_button then
    return
  end
  if not modifier_held(event.modifiers) then
    return
  end
  inverse_at(event.page, event.page_x, event.page_y)
  -- Consume the click so it does not also begin a text selection.
  return true
end)

synctex:on("mouse_button", function(event)
  if event.phase == "down" and event.inside_document then
    last_click = { page = event.page, x = event.page_x, y = event.page_y }
  end
end)

synctex:register_action("inverse", {
  description = "Jump to the source line for the last clicked point."
}, function()
  if not last_click then
    fail("click in the page first")
    return
  end
  inverse_at(last_click.page, last_click.x, last_click.y)
end)

synctex:register_command("forward", {
  description = ":synctex-forward [file.tex:]line[:column] - Jump to the PDF position for a source line."
}, function(context)
  local target, err = parse_target(context.raw)
  if not target then
    fail(err)
    return
  end
  forward_to(target.source, target.line, target.column)
end)

synctex:register_command("status", {
  description = ":synctex-status - Report whether SyncTeX data is available for this document."
}, function()
  local pdf_path = document_path()
  if not pdf_path then
    fail("no document is open")
    return
  end
  local candidates = synctex_file_candidates(pdf_path)
  local remaining = #candidates
  local found = nil
  for _, candidate in ipairs(candidates) do
    synctex.fs:stat(candidate, function(result)
      if result.success and not found then
        found = candidate
      end
      remaining = remaining - 1
      if remaining > 0 then
        return
      end
      if found then
        onon.message("synctex: using " .. path_util.basename(found))
      else
        onon.message("synctex: no .synctex or .synctex.gz beside " .. path_util.basename(pdf_path)
          .. "; rebuild with -synctex=1")
      end
    end)
  end
end)

-- Callable from configuration Lua, so a keybinding can look up an arbitrary
-- point rather than only the last clicked one.
function synctex.inverse_at(page, x, y)
  inverse_at(page, x, y)
end

function synctex.forward_to(source, line, column)
  forward_to(source, line, column or 0)
end

return synctex
