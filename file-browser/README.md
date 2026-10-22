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
`:file-browser-open /path/to/directory`.

## Options

```lua
file_browser.start_path = "~/Documents"
file_browser.show_hidden = true
file_browser.remember_directory = false
```

| Option | Default | Meaning |
|---|---|---|
| `start_path` | `""` | Directory to open. Empty uses the last visited directory, then the current document's directory, then home. |
| `show_hidden` | `false` | Show entries whose names begin with a dot. |
| `remember_directory` | `true` | Reopen where the browser last was. |

`start_path` accepts `~` and native separators; paths are handled through
`onon.path`, so drive letters and backslashes work on Windows.

## Behaviour

Directories sort first, then names case-insensitively. The header row shows the
current directory and its entry count. `../` moves up, and is absent at a
filesystem root, detected as `dirname(path) == path` — true for both `/` and
`C:\`.

Openable documents show their format and size (`EPUB · 1.2 MB`).

Symbolic links are followed, so a linked directory is entered like any other.
An entry whose target is missing is listed as `unreadable`; the rest of the
listing is unaffected.

The last visited directory lives in onon's session database, keyed by plugin
ID, and survives config reloads and restarts. It is a plain absolute path, and
will not resolve if one profile is shared between operating systems.

## Notes

The plugin uses the filesystem, path, and storage surfaces. It runs no external
commands and no shell, and behaves identically on Linux, macOS, and Windows.

Directory reads are asynchronous, and are cancelled on navigating away or
closing the view. A slow or unresponsive filesystem does not block the viewer.
