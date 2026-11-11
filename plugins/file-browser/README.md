# File Browser

An asynchronous document browser for onon. Directories open in place;
documents open in the viewer.

Openable formats come from `onon.formats.supports`, which reports what the
linked MuPDF build handles: EPUB, CBZ, XPS, images, and PDFs among them. Files
onon cannot open are listed but not selectable.

## Install

Put this directory in one of onon's plugin search paths.

**Linux**

```
$XDG_DATA_HOME/onon/plugins/       (or ~/.local/share/onon/plugins/)
$XDG_CONFIG_HOME/onon/plugins/     (or ~/.config/onon/plugins/)
```

**macOS**

```
~/Library/Application Support/onon/plugins/
~/.config/onon/plugins/
```

**Windows**

```
%LOCALAPPDATA%\onon\plugins\
%APPDATA%\onon\plugins\
```

Earlier entries win when the same plugin ID appears twice.

## Enable

In your onon config — `~/.config/onon/config.lua` on Linux, `~/Library/Application
Support/onon/config.lua` on macOS, `%APPDATA%\onon\config.lua` on Windows:

```lua
file_browser = require("file-browser")
onon.bind("o", file_browser.actions.browse)
```

`:file-browser-open` opens the browser, optionally at a given directory:
`:file-browser-open /path/to/directory`. `file_browser.actions.find` and
`:file-browser-find [directory]` open the find on its own.

## Keys

| Key | Does |
|---|---|
| `Enter` | Enters a directory; opens a document, or shows its tab if it is open already. |
| `<C-t>`, `<S-CR>` | Opens the document in a new tab (or shows its tab: onon keeps one tab per document). |
| `l` | Enters a directory. |
| `h`, `-`, `<BS>` | Goes up, with the directory you left selected. |
| `/` | Filters the listing by name. |
| `s` | Sorts by name, then newest first, then largest first. Remembered. |
| `.` | Shows or hides hidden entries. |
| `"x` | Sets mark `x` to this directory. Kept across restarts. |
| `'x` | Jumps to mark `x`; `''` jumps back to where the last jump left. |
| `p`, `<C-p>` | Shows or hides the preview; in the find, `<C-p>`. Remembered. |
| `<C-f>` | Finds documents anywhere under this directory, typing to filter: ranked by fzf, best first, when it is installed. |

The header shows the directory on the left and the sort, and whether hidden
entries are shown, muted on the right (with an onon too old for view details,
in parentheses after the directory). Documents open in a tab are marked `○`,
and the one shown `●`. Each directory remembers the entry last selected in it
while onon runs.

## Options

```lua
file_browser.start_path = "~/Documents"
file_browser.show_hidden = true
file_browser.columns = { "type", "size", "modified" }
file_browser.sort = "modified"
```

| Option | Default | Meaning |
|---|---|---|
| `start_path` | `""` | Directory to open. Empty uses the last visited directory, then the current document's directory, then home. |
| `show_hidden` | `false` | Show entries whose names begin with a dot at first; `.` toggles it. |
| `show_other_files` | `true` | List files onon cannot open, greyed out. False hides them. |
| `remember_directory` | `true` | Reopen where the browser last was. |
| `columns` | `{ "size", "modified" }` | Columns beside the name, in order, from `type`, `size` and `modified`. `{}` shows names only. |
| `sort` | `"name"` | The sort until `s` picks another: `name`, `modified` or `size`. |
| `preview` | `false` | Show the preview until `p` first toggles it. |
| `preview_side` | `"right"` | The side of the selected row the card opens on: `right` or `left`, the other without room. |
| `preview_size` | `"14%"` | The card's width, a share of the window; 14% fits beside the browser. Its height fits the first page. |
| `find_ignore` | `{ "node_modules", "Library", "__pycache__" }` | Directory names the find skips. Hidden directories are skipped unless shown. |
| `find_max_directories` | `20000` | The most directories one find reads. |
| `fzf` | `"fzf"` | The fzf that ranks the find's matches: a name on `PATH` or a path. It is also looked for where it is usually installed (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.fzf/bin`…), as an onon started from the Dock has a short `PATH`. `""`, or none found, filters by substring. |

Options are read when the browser first opens, so set them in `config.lua`.
`start_path` accepts `~` and native separators; paths are handled through
`onon.path`, so drive letters and backslashes work on Windows.

## Preview

`p` (in the find, `<C-p>`) shows a small card beside the selected row, as a
submenu is, on the side `preview_side` says (the other if there is no room): the
document's first page. It opens once the document has loaded, in the background
with `onon.load_document`, and is shaped to its first page. A document selected
from rest starts loading at once; while the selection is moving, as a held key
moves it, only the one it stops on loads. It closes on a folder, when the
preview is turned off, or when the browser closes. Moving between documents
keeps the last page on the card until the next has loaded, and keeps the card
itself open, unless the next page is a different shape. It needs an onon with
`onon.load_document`; an older one says so.

## Behaviour

Directories sort first. `../` moves up, and is absent at a filesystem root,
detected as `dirname(path) == path` — true for both `/` and `C:\`.

Symbolic links are followed, so a linked directory is entered like any other.
An entry whose target is missing is listed as `unreadable`; the rest of the
listing is unaffected.

With fzf, each query runs `fzf --filter` over the documents found, one at a
time; a query typed or documents found meanwhile are ranked once it is done,
and the header shows how many match. If fzf fails, the find says so and
filters by substring for the rest of the session.

The find walks breadth first, eight directories at a time, so shallow documents
come first and the list fills as it reads. It does not follow links, so a link
back up the tree cannot loop. It stops after `find_max_directories` and says so.

The last directory, the sort and the marks live in onon's session database,
keyed by plugin ID, and survive config reloads and restarts. They are plain
absolute paths, and will not resolve if one profile is shared between
operating systems.

## Layout

`lua/file-browser/`: `init.lua` registers the plugin, its options, actions and
commands, and gives the parts a context they find each other through:
`listing.lua` (the browser), `find.lua`, `preview.lua`, `marks.lua`, and the
stateless `tabs.lua` and `util.lua`. The modules load as
`require("file-browser.listing")`, which needs an onon that finds a plugin's
modules as Lua's `require` does.

## Notes

The plugin uses the filesystem, path, tabs, background document and storage surfaces, and runs fzf when it finds one. It runs no
shell, and behaves identically on Linux, macOS, and Windows.

Directory reads are asynchronous, and are cancelled on navigating away or
closing the view. A slow or unresponsive filesystem does not block the viewer.
