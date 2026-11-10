-- The window's tabs, as the browser and the find mark and open documents.

local tabs = {}

-- open is the paths open in the window's tabs, to their tab index.
function tabs.open()
  local open = {}
  for _, tab in ipairs(onon.tabs.list()) do
    if tab.path ~= "" then
      open[tab.path] = tab.index
    end
  end
  return open
end

-- marker marks the document shown ● and others open in a tab ○.
function tabs.marker(path, open)
  if path == onon.document.path then
    return "●"
  end
  if open[path] then
    return "○"
  end
  return nil
end

-- show shows path: in the tab it is open in, else in place; in a new tab
-- with new_tab. onon keeps one tab per document, so a document already
-- open is shown either way.
function tabs.show(path, new_tab)
  if new_tab then
    onon.tabs.open(path)
    return
  end
  local index = tabs.open()[path]
  if index then
    onon.tabs.select(index)
  else
    onon.open(path)
  end
end

return tabs
