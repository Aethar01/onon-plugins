-- The preview: a small card attached beside the selected row of the
-- browser, or the find, as a submenu is, showing the document's first
-- page. It opens once the document has loaded, in the background, shaped
-- to its first page, and closes on anything else. A document selected
-- from rest loads at once; while the selection is moving, as a held key
-- moves it, only the one it stops on loads.

local PREVIEW_KEY = "preview"
local SETTLE_MS = 120 -- how long the selection stays put to be at rest
local PAD = 6 -- logical pixels around the card's text; its page fills it

return function(ctx)
  local plugin = ctx.plugin
  local preview = { shown = false }
  -- The card, the view it follows, the document on it, and the one loading
  -- to take its place, which it shows until that has opened. settle runs
  -- while the selection is moving, and latest is the document it is on.
  local card, list, doc, pending, settle, latest
  local loaded = false

  local function close(d)
    if d then
      d:close()
    end
  end

  local function close_documents()
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
    canvas:document_page(doc, 1, 0, 0, box.w, box.h)
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

  local function height_for(width, aspect)
    return math.floor(width * aspect + 0.5)
  end

  -- open_card shows the card for doc, open: preview_size wide, a share of
  -- the window as it is now, and as tall as its first page is at that
  -- width. A card already open is kept and given the new page's height
  -- where it is, so moving between documents neither closes nor fades it.
  -- A new card opens a pixel tall, to learn its width, and has its height
  -- before anything is drawn.
  local function open_card()
    local aspect = math.sqrt(2) -- A4's, for a document whose page cannot be read
    local ok, info = pcall(doc.page_info, doc, 1)
    if ok and info.width > 0 then
      aspect = info.height / info.width
    end
    if not (card and card:visible()) then
      make_card(plugin.preview_size, 1)
    end
    local width, height = card:size()
    local wanted = height_for(width, aspect)
    if height == wanted then
      return card:redraw()
    end
    if card.set_size then
      card:set_size(nil, wanted)
      return card:redraw()
    end
    card:close() -- an onon without set_size: another card, of that height
    make_card(width, wanted)
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

  -- load loads what, unless it is on the card or loading, and opens the
  -- card for it once it has. A card already open keeps the page on it
  -- until the next has rendered, at the card's width, so that the card is
  -- never blank between them.
  local function load(what)
    local wanted = pending or doc
    if wanted and wanted.path == what.path then
      return
    end
    close(pending)
    local loading
    local function show()
      if pending ~= loading then
        return -- the selection moved on meanwhile
      end
      close(doc)
      doc, pending = loading, nil
      open_card() -- the page, or why it could not open
    end
    loading = onon.load_document(what.path, function()
      if pending ~= loading then
        return
      end
      -- prepare_page needs a newer onon; without it the page renders once
      -- the card draws it.
      if card and card:visible() and loading:state() == "open" and loading.prepare_page then
        if pcall(loading.prepare_page, loading, 1, (card:size()), show) then
          return
        end
      end
      show()
    end)
    pending = loading
  end

  -- show shows what, an entry as the browser's or the find's are, or
  -- nothing for nil.
  function preview.show(what)
    if not preview.shown or not list then
      return
    end
    -- A move from rest loads now; a move within SETTLE_MS of the last
    -- waits, and the document the selection stops on loads once it has
    -- been there SETTLE_MS, not each one passed on the way.
    local moving = settle ~= nil
    if settle then
      settle:cancel()
    end
    settle = plugin.timer:after(SETTLE_MS, function()
      settle = nil
      if latest then
        load(latest)
      end
    end)
    if not what or what.kind ~= "document" then
      latest = nil
      close_documents()
      return close_card()
    end
    latest = what
    if not moving then
      load(what)
    end
  end

  -- release closes the card and lets its document go, as the browser
  -- closes.
  function preview.release()
    if settle then
      settle:cancel()
      settle = nil
    end
    latest = nil
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
