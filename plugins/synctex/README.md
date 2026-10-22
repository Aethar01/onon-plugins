# SyncTeX

Source↔PDF navigation for LaTeX documents.

- **Inverse search** (PDF → editor): modifier-click a spot in the page and the
  `.tex` line that produced it opens in your editor.
- **Forward search** (editor → PDF): one command from your editor jumps the
  open window to the matching position.

---

## Setup

### 1. Install SyncTeX

**Linux**

```bash
sudo apt install texlive-binaries      # Debian, Ubuntu
sudo pacman -S texlive-bin             # Arch
sudo dnf install texlive-synctex       # Fedora
```

**macOS**

```bash
brew install texlive
```

`brew install --cask basictex` installs to `/Library/TeX/texbin`, which is not
on `PATH` by default.

**Windows**

[TeX Live](https://tug.org/texlive/) and [MiKTeX](https://miktex.org/) both
provide `synctex.exe` and put it on `PATH`. For an installation elsewhere:

```lua
synctex.command = "C:\\texlive\\2025\\bin\\windows\\synctex.exe"
```

### 2. Build with SyncTeX data

Both directions read a `.synctex.gz` beside the PDF, written by:

```bash
pdflatex -synctex=1 paper.tex
```

`latexmk` writes it when its config has:

```perl
$pdflatex = 'pdflatex -synctex=1 %O %S';
```

`:synctex-status` reports whether the data is present for the open document.

### 3. Install and enable the plugin

Plugin search paths:

| | Plugin path |
|---|---|
| Linux | `$XDG_DATA_HOME/onon/plugins/` or `~/.local/share/onon/plugins/`, then `~/.config/onon/plugins/` |
| macOS | `~/Library/Application Support/onon/plugins/`, then `~/.config/onon/plugins/` |
| Windows | `%LOCALAPPDATA%\onon\plugins\`, then `%APPDATA%\onon\plugins\` |

Config paths: `~/.config/onon/config.lua` on Linux, `~/Library/Application
Support/onon/config.lua` on macOS, `%APPDATA%\onon\config.lua` on Windows.

```lua
synctex = require("synctex")
```

### 4. Point it at your editor

With `editor` unset, inverse search reports the source location in the status
line. Setting it opens the location instead.

`%f` is the file, `%l` the line, `%c` the column. The editor runs without a
shell, so each argument is its own list entry and none needs quoting, including
paths containing spaces.

```lua
-- VS Code
synctex.editor = "code"
synctex.editor_args = { "-g", "%f:%l:%c" }

-- Emacs
synctex.editor = "emacsclient"
synctex.editor_args = { "+%l:%c", "%f" }

-- Vim / gVim
synctex.editor = "gvim"
synctex.editor_args = { "+%l", "%f" }

-- Neovim with VimTeX
synctex.editor = "nvim"
synctex.editor_args = { "--headless", "-c", "VimtexInverseSearch %l '%f'" }
```

Each of these reaches an editor window that is already open. `code` and
`emacsclient` locate their own instance. VimTeX records each running Neovim
server in `~/.cache/vimtex/nvim_servernames.log`, and `VimtexInverseSearch` runs
in a throwaway headless Neovim that reads the file, hands the position to the
live servers, and exits.

Neovim without VimTeX has no such registry, and its default address contains a
component regenerated per instance. Start it with `--listen` on a fixed path and
use `--server <path> --remote-send "<C-\\><C-N>:edit %f<CR>:%l<CR>zz"`.

On Windows, an executable that is not on `PATH` must be named with its
extension.

---

## Forward search

The editor asks a running onon to run this plugin's command:

```bash
onon --unique --command "synctex-forward chapter1.tex:142" paper.pdf
```

The lookup runs inside onon, so the editor neither invokes `synctex` nor parses
its output.

`--unique` reuses the window already showing the document. With no such window,
onon opens one and runs the command once its plugins are ready. A command onon
does not recognise exits non-zero.

The argument is `[file.tex:]line[:column]`. A bare line number uses the `source`
option, or the `.tex` whose name matches the PDF. A relative path resolves
against the document's directory.

---

## Neovim walkthrough

A setup with [VimTeX](https://github.com/lervag/vimtex): inverse search through
this plugin, forward search through `--command`.

**Config for onon:**

```lua
synctex = require("synctex")
synctex.editor = "nvim"
synctex.editor_args = { "--headless", "-c", "VimtexInverseSearch %l '%f'" }
```

**Config for Neovim:**

```lua
vim.g.vimtex_view_method = "general"
vim.g.vimtex_view_general_viewer = "onon"
vim.g.vimtex_view_general_options = "--unique @pdf"

-- Forward search: onon's synctex plugin does the lookup.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "tex" },
  callback = function()
    vim.keymap.set("n", "<localleader>v", function()
      local pdf = vim.fn.expand("%:p:r") .. ".pdf"
      local target = vim.fn.expand("%:p") .. ":" .. vim.fn.line(".") .. ":" .. vim.fn.col(".")
      vim.system({ "onon", "--unique", "--command", "synctex-forward " .. target, pdf })
    end, { buffer = true, desc = "Forward search to onon" })
  end,
})
```

Neither side listens on a configured address. onon is reached through
`--unique`, and Neovim through VimTeX's server registry.

`onon` must be an executable on `PATH`. A local build that needs library paths
set requires a wrapper script; a symlink cannot carry environment variables.

---

## Options

| Option | Default | Meaning |
|---|---|---|
| `command` | `"synctex"` | The synctex executable. |
| `editor` | `""` | Program to open the source. Empty reports the location instead. |
| `editor_args` | `{"+%l", "%f"}` | Editor arguments. `%f` file, `%l` line, `%c` column. |
| `click_button` | `"left"` | Button for inverse search: `left`, `middle`, `right`. |
| `click_modifier` | `"ctrl"` | Modifier held: `ctrl`, `shift`, `alt`, `gui`, or `none`. |
| `source` | `""` | Main `.tex` for forward search when only a line is given. Empty derives it from the document name. |
| `timeout_ms` | `5000` | How long to wait for synctex. |

`gui` is Super on Linux, Command on macOS, and the Windows key on Windows.

## Commands and actions

| | Meaning |
|---|---|
| `:synctex-forward [file.tex:]line[:column]` | Jump to the PDF position for a source line. |
| `:synctex-status` | Report whether SyncTeX data is available. |
| `synctex.actions.inverse` | Look up the last clicked point. |

The action is bindable, and looks up wherever you last clicked:

```lua
onon.bind("gs", synctex.actions.inverse)
```

`synctex.inverse_at(page, x, y)` and `synctex.forward_to(file, line[, column])`
take arbitrary positions from Lua.

---

## Troubleshooting

**Ctrl-click does nothing.** Run `:synctex-status`. No data means the document
needs rebuilding with `-synctex=1`. A named file means `synctex` itself is not
on `PATH`; set `synctex.command` to its full path.

**Ctrl-click lands on the wrong line.** The `.synctex.gz` is from an older
build. Recompile.

**The editor does not open.** With Neovim, check VimTeX's registry, which is
written whenever a `.tex` buffer is opened:

```bash
cat ~/.cache/vimtex/nvim_servernames.log
```

An empty or missing file means VimTeX never loaded in the window meant to
receive the jump. A populated file points at `editor_args`.

**Forward search opens a second window.** Either `--unique` is missing, or the
path given to onon differs from the one already open. Paths are matched after
resolving symlinks; pass an absolute path.

**Forward search exits non-zero.** onon did not recognise the command, usually
because the window it reached has no `require("synctex")` in its config.

**Diagnostics.** The plugin logs through `onon.log`, which writes to stderr
tagged `plugin=synctex`. `-V` enables them.

## Notes

Coordinates are translated between synctex's top-left page origin and the
document's page box, so cropped pages land in the right place.

Multi-file projects work when the `.synctex.gz` belongs to the main document.
Inverse search reports whichever file produced the text.

The plugin runs no shell. Its only external programs are `synctex` and the
configured editor, both by argument vector.
