# file-browser

A keyboard-first, asynchronous document browser for [onon](https://github.com/Aethar01/onon) with configurable columns, persistent directory marks, tab awareness, live first-page previews and recursive find.

Openable formats come from `onon.formats.supports`, which reports everything the linked MuPDF build handles — PDF, EPUB, XPS, MOBI, FictionBook, CBZ/CBT comic archives and images. Files onon cannot open are listed greyed out (or hidden with `show_other_files = false`).

## Installation

Install the full [onon-plugins](../../README.md#installation) repository, or copy this directory into one of onon's plugin search paths (earlier entries win when the same plugin ID appears twice):

| Platform | Plugin search paths |
|---|---|
| Linux | `$XDG_DATA_HOME/onon/plugins/` (or `~/.local/share/onon/plugins/`), then `$XDG_CONFIG_HOME/onon/plugins/` (or `~/.config/onon/plugins/`) |
| macOS | `~/Library/Application Support/onon/plugins/`, then `~/.config/onon/plugins/` |
| Windows | `%LOCALAPPDATA%\onon\plugins\`, then `%APPDATA%\onon\plugins\` |

## Enable

In your `config.lua` (`~/.config/onon/config.lua` on Linux, `~/Library/Application Support/onon/config.lua` on macOS, `%APPDATA%\onon\config.lua` on Windows):

```lua
local has_file_browser, file_browser = pcall(require, "file-browser")
if has_file_browser then
  onon.bind("bf", file_browser.actions.browse)
  onon.bind("ff", file_browser.actions.find)
end
```

Run `:reload-config` to load it.

## Commands and actions

| Command / Action | Meaning |
|---|---|
| `:file-browser-open [dir]` | Open the browser, optionally starting at `dir`. |
| `:file-browser-find [dir]` | Open the recursive document finder on its own, optionally rooted at `dir`. |
| `file_browser.actions.browse` | Bindable action that opens the browser. |
| `file_browser.actions.find` | Bindable action that opens the recursive finder. |

## Keys

| Key | Action |
|---|---|
| `Enter` | Enter a directory; open a document, or switch to its tab if already open. |
| `<C-t>`, `<S-CR>` | Open the document in a new tab (or switch to its tab — onon keeps one tab per document). |
| `l` | Enter a directory. |
| `h`, `-`, `<BS>` | Move up to the parent directory, keeping the directory you left selected. |
| `/` | Filter the current listing by name. |
| `s` | Cycle sort order: name, newest first, largest first (remembered across sessions). |
| `.` | Toggle hidden entries. |
| `"x` | Set mark `x` to the current directory (persisted across restarts). |
| `'x` | Jump to mark `x`; `''` jumps back to where the last jump left. |
| `p`, `<C-p>` | Toggle the live first-page preview card (`<C-p>` inside find; remembered across sessions). |
| `<C-f>` | Find documents anywhere under the current directory, ranked by `fzf` when installed. |

The header shows the current directory on the left and the active sort (plus hidden-files state) muted on the right (or in parentheses on older onon builds without view details). Documents already open in a tab are marked `○`, and the active tab `●`. Each directory remembers the entry last selected in it while onon runs.

## Options

Set options in `config.lua`; they are read when the browser first opens:

```lua
file_browser.start_path = "~/Documents"
file_browser.show_hidden = true
file_browser.columns = { "type", "size", "modified" }
file_browser.sort = "modified"
```

| Option | Default | Meaning |
|---|---|---|
| `start_path` | `""` | Directory to open. Empty uses the last visited directory, then the current document's directory, then home. |
| `show_hidden` | `false` | Show entries whose names begin with a dot initially; `.` toggles it. |
| `show_other_files` | `true` | List files onon cannot open, greyed out. `false` hides them. |
| `remember_directory` | `true` | Reopen where the browser last was. |
| `columns` | `{ "size", "modified" }` | Columns beside the name, in order, from `type`, `size` and `modified`. `{}` shows names only. |
| `sort` | `"name"` | Initial sort until `s` picks another: `name`, `modified` or `size`. |
| `preview` | `false` | Show the preview card initially until `p` toggles it. |
| `preview_side` | `"right"` | Side of the selected row the preview card opens on: `right` or `left` (falls back to the other side if there is no room). |
| `preview_size` | `"14%"` | Preview card width as a share of the window (`14%` fits beside the browser); height adapts to the first page. |
| `find_ignore` | `{ "node_modules", "Library", "__pycache__" }` | Directory names skipped during recursive find. Hidden directories are skipped unless shown. |
| `find_max_directories` | `20000` | Maximum number of directories one find reads. |
| `fzf` | `"fzf"` | `fzf` executable used to rank find matches (name on `PATH` or full path; also checked in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.fzf/bin`, etc. for Dock launches). `""`, or none found, falls back to substring filtering. |

`start_path` accepts `~` and native separators; paths are handled through `onon.path`, so drive letters and backslashes work on Windows.

## Preview

Pressing `p` (`<C-p>` in find) opens a small card beside the selected row showing the document's first page, loaded in the background via `onon.load_document` and sized to the page's aspect ratio.

- Selecting a document from rest loads it immediately; while moving quickly (e.g. holding `j`/`k`), only the document you stop on is loaded.
- Moving between documents keeps the previous page visible until the next finishes rendering, resizing the card in place when the aspect ratio changes (older builds without `view:set_size` close and reopen it).
- The card closes automatically on a folder, when preview is toggled off, or when the browser closes.

Requires an onon build with `onon.load_document`.

## Behaviour

- Directories sort first. `../` moves up and is omitted at a filesystem root (`dirname(path) == path`, true for both `/` and `C:\`).
- Symbolic links are followed in the directory listing, so a linked directory enters like any other; broken symlinks are listed as `unreadable` without affecting other entries.
- Recursive find walks breadth-first (eight directories at a time) so shallow documents appear first as the list fills. It does not follow symlinks so cycles cannot loop, and stops cleanly after `find_max_directories`.
- When `fzf` is available, each query runs `fzf --filter` over the discovered documents one run at a time, re-ranking as new queries or results arrive and showing the match count in the header. If `fzf` fails, find falls back to substring filtering for the rest of the session.
- The last visited directory, sort order, preview toggle and marks are persisted in onon's session database keyed by plugin ID and survive config reloads and restarts. Directory paths are stored as plain absolute paths, so they will not resolve if a single profile is shared across operating systems.

## Layout

Under `lua/file-browser/`:

- `init.lua` — registers the plugin, options, actions and commands, and wires the shared context
- `listing.lua` — directory browser view
- `find.lua` — breadth-first recursive finder and `fzf` integration
- `preview.lua` — background-loaded first-page preview card
- `marks.lua` — persistent directory marks
- `tabs.lua`, `util.lua` — stateless helpers

Modules load via `require("file-browser.<module>")`.

## Notes

The plugin uses onon's built-in filesystem, path, tab, background-document and storage APIs, plus `fzf` when found (invoked directly, with no shell). Directory reads run asynchronously and cancel on navigating away or closing the view, so a slow or unresponsive filesystem never blocks the viewer.
