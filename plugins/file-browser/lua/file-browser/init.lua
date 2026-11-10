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
    preview = {
      type = "boolean",
      default = false,
      description = "Show the preview at first, until p or <C-p> toggles it, which is remembered."
    },
    preview_side = {
      type = "string",
      default = "right",
      description = 'The side of the selected row the preview opens on, "right" or "left", taking the other without room.'
    },
    preview_size = {
      type = "string",
      default = "14%",
      description = "The preview's width, a share of the window such as \"14%\", which fits beside the browser; its height fits its first page."
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

-- The browser's parts, each made with the context they share, find each
-- other through it as they run.
local util = require("file-browser.util")
local tabs = require("file-browser.tabs")

local ctx = { plugin = browser }
ctx.preview = require("file-browser.preview")(ctx)
ctx.marks = require("file-browser.marks")(ctx)
ctx.find = require("file-browser.find")(ctx)
ctx.listing = require("file-browser.listing")(ctx)

-- show_document closes the browser and the find, and shows path.
function ctx.show_document(path, new_tab)
  ctx.find.close()
  ctx.listing.close()
  tabs.show(path, new_tab)
end

function browser.open(path)
  ctx.preview.init()
  ctx.listing.open(path)
end

function browser.find(path)
  ctx.preview.init()
  ctx.find.open(path or util.document_directory() or util.default_directory(browser), ctx.listing.show_hidden())
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
