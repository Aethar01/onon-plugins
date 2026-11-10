-- Marks: "x sets mark x to the directory listed, 'x goes to it, and ''
-- goes back to where the last jump left. Marks are kept across restarts.

local util = require("file-browser.util")

return function(ctx)
  local plugin = ctx.plugin
  local marks = { previous = nil }

  local function key(name)
    return "mark:" .. name
  end

  function marks.set(name, dir)
    plugin.storage:set(key(name), dir)
    onon.message("file browser: mark " .. name .. " → " .. util.display_path(dir))
  end

  -- target is where mark name goes from dir, or nil, saying so.
  function marks.jump(name, dir)
    local target
    if name == "'" then
      target = marks.previous
    else
      target = plugin.storage:get(key(name))
    end
    if type(target) ~= "string" or target == "" then
      onon.message("file browser: no mark " .. name)
      return nil
    end
    marks.previous = dir
    return target
  end

  return marks
end
