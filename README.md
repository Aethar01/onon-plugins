<div align="center">

# onon-plugins

**Example plugins for [onon](https://github.com/Aethar01/onon).**

Self-contained Lua plugins showing commands, keybindable actions, asynchronous I/O, persistent storage, background documents and custom UI panels.

[onon](https://github.com/Aethar01/onon) · [Plugin guide](https://ononreader.com/docs/plugins/) · [Themes](https://github.com/Aethar01/onon-themes) · [Website](https://ononreader.com/)

</div>

## Plugins

| Plugin | What it does | Highlights |
|---|---|---|
| [`file-browser`](./plugins/file-browser) | Browse directories and open documents without leaving onon. | Keyboard-first navigation (`h`/`l`, `/`, `s`, `.`), persistent directory marks (`"`/`'`), open-tab markers, live first-page thumbnail previews (`p`), recursive find with `fzf` ranking (`<C-f>`), async `onon.fs` reads. |
| [`synctex`](./plugins/synctex) | Jump between LaTeX source and PDF in both directions. | Modifier-click inverse search into VS Code, Emacs, Vim or Neovim/VimTeX; forward search via `onon --unique --command "synctex-forward …"`; no shell invocation. |

See each plugin's README ([`file-browser`](./plugins/file-browser/README.md), [`synctex`](./plugins/synctex/README.md)) for keybindings, options, commands, editor setup and troubleshooting.

## Installation

<details open>
<summary><strong>Linux &amp; macOS</strong></summary>

Clone the repository into your onon config directory and link `plugins` beside it:

```bash
git clone https://github.com/Aethar01/onon-plugins ~/.config/onon/onon-plugins
ln -s onon-plugins/plugins ~/.config/onon/plugins
```

Run `git pull` in `~/.config/onon/onon-plugins` to update, then `:reload-config` inside onon. If you already have a `plugins` directory, copy the individual plugin folders you want into it instead.

</details>

<details>
<summary><strong>Windows</strong></summary>

Clone the repository and copy the plugin folders into `%APPDATA%\onon\plugins`:

```powershell
git clone https://github.com/Aethar01/onon-plugins "$env:APPDATA\onon\onon-plugins"
New-Item -ItemType Directory -Force "$env:APPDATA\onon\plugins"
Copy-Item -Recurse "$env:APPDATA\onon\onon-plugins\plugins\*" "$env:APPDATA\onon\plugins"
```

</details>

## Enable

onon discovers installed plugins automatically, but only loads the ones your `config.lua` requires. Wrapping `require` in `pcall` keeps a shared config working on machines where a plugin is not installed:

```lua
local has_file_browser, file_browser = pcall(require, "file-browser")
if has_file_browser then
  onon.bind("bf", file_browser.actions.browse)
  onon.bind("ff", file_browser.actions.find)
end

local has_synctex, synctex = pcall(require, "synctex")
if has_synctex then
  synctex.editor = "code"
  synctex.editor_args = { "-g", "%f:%l:%c" }
end
```

Run `:reload-config` to load them without restarting.

## Writing your own

The [plugin guide](https://ononreader.com/docs/plugins/) covers plugin manifests, search paths, the Lua API and its sandboxing limits. Both plugins here are small enough to start from.

## License

[MIT](./LICENSE)
