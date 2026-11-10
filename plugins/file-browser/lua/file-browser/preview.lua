-- The preview: a small card attached beside the selected row of the
-- browser, or the find, as a submenu is, showing the document's first page
-- and how many it has. It opens once the selection settles on a document
-- and the document has loaded, in the background, shaped to its first
-- page, and closes on anything else.

local PREVIEW_KEY = "preview"
local DELAY_MS = 120
local CAPTION = 20 -- logical pixels under the page for its count
local PAD = 6 -- logical pixels around what the card shows

return function(ctx)
  local plugin = ctx.plugin
  local preview = { shown = false }
  -- The card, the view it follows, the document on it, and the one loading
  -- to take its place, which it shows until that has opened.
  local card, list, doc, pending, timer
  local loaded = false

  local function close(d)
    if d then
      d:close()
    end
  end

  local function close_documents()
    if timer then
      timer:cancel()
      timer = nil
    end
    close(doc)
    close(pending)
    doc, pending = nil, nil
  end

  local function close_card()
    if card and card:visible() then
      card:close()
    end
  end

  local function draw(canvas, box)
    if not doc then
      return
    end
    local state = doc:state()
    if state == "failed" then
      canvas:text(PAD, PAD, doc:error(), "muted", { width = box.w - 2 * PAD, wrap = true })
      return
    end
    if state ~= "open" then
      canvas:text(PAD, PAD, "Loading", "muted")
      return
    end
    local _, h = canvas:document_page(doc, 1, PAD, PAD, box.w - 2 * PAD, box.h - CAPTION - 2 * PAD)
    local pages = doc:page_count()
    canvas:text(PAD, PAD + h + 4, pages == 1 and "1 page" or pages .. " pages", "muted")
  end

  local function make_card(width, height)
    card = onon.ui.create({
      id = "file-browser-preview",
      modal = false,
      width = width,
      height = height,
      attach = { view = list, side = plugin.preview_side == "left" and "left" or "right" },
      draw = draw
    })
    card:show()
  end

  -- open_card shows the card for doc, open: preview_size wide, a share of
  -- the window as it is now, and as tall as its first page is at that
  -- width, with its count. The width is learnt from a card made a pixel
  -- tall, which goes before anything is drawn.
  local function open_card()
    local aspect = math.sqrt(2) -- A4's, for a document whose page cannot be read
    local ok, info = pcall(doc.page_info, doc, 1)
    if ok and info.width > 0 then
      aspect = info.height / info.width
    end
    close_card()
    make_card(plugin.preview_size, 1)
    local width = card:size()
    card:close()
    make_card(width, math.floor((width - 2 * PAD) * aspect + CAPTION + 2 * PAD + 0.5))
  end

  -- init reads whether the preview shows, once options are set: what p
  -- last left, else the preview option. It needs onon.load_document.
  function preview.init()
    if loaded then
      return
    end
    loaded = true
    local stored = plugin.storage:get(PREVIEW_KEY)
    if type(stored) == "boolean" then
      preview.shown = stored
    else
      preview.shown = plugin.preview
    end
    preview.shown = preview.shown and onon.load_document ~= nil
  end

  -- follow attaches the card to view, the browser or the find, whichever
  -- the selection is now in.
  function preview.follow(view)
    if list ~= view then
      close_card()
      list = view
    end
  end

  -- show shows what, an entry as the browser's or the find's are, or
  -- nothing for nil.
  function preview.show(what)
    if not preview.shown or not list then
      return
    end
    if not what or what.kind ~= "document" then
      close_documents()
      return close_card()
    end
    local wanted = pending or doc
    if wanted and wanted.path == what.path then
      return
    end
    if timer then
      timer:cancel()
    end
    -- Loaded, and the card opened, once the selection settles, not for
    -- each document passed on the way to one.
    timer = plugin.timer:after(DELAY_MS, function()
      timer = nil
      close(pending)
      local loading
      loading = onon.load_document(what.path, function()
        if pending ~= loading then
          return -- the selection moved on meanwhile
        end
        close(doc)
        doc, pending = loading, nil
        open_card() -- the page, or why it could not open
      end)
      pending = loading
    end)
  end

  -- release closes the card and lets its document go, as the browser
  -- closes.
  function preview.release()
    close_documents()
    close_card()
  end

  -- toggle shows or hides the preview, remembered, of what is selected
  -- now.
  function preview.toggle(selected)
    if not onon.load_document then
      onon.message("file browser: the preview needs a newer onon")
      return
    end
    preview.shown = not preview.shown
    plugin.storage:set(PREVIEW_KEY, preview.shown)
    if preview.shown then
      preview.show(selected)
    else
      preview.release()
    end
  end

  return preview
end
