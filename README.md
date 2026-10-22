# onon-plugins

Example plugins for [onon](https://github.com/Aethar01/onon), a quiet reader for the keyboard.

| Plugin | What it does |
|---|---|
| [`file-browser`](./plugins/file-browser) | Browse directories and open documents without leaving onon. |
| [`synctex`](./plugins/synctex) | Jump between LaTeX source and PDF in both directions. |

## Install

Clone the repository into your onon directory and link its `plugins` directory beside it:

```bash
git clone https://github.com/Aethar01/onon-plugins ~/.config/onon/onon-plugins
ln -s onon-plugins/plugins ~/.config/onon/plugins
```

That works on Linux and macOS. `git pull` in the clone updates the plugins, and `:reload-config` picks them up. If you already have a `plugins` directory, copy in the plugin directories you want instead.

On Windows, copy them out of the clone:

```powershell
git clone https://github.com/Aethar01/onon-plugins "$env:APPDATA\onon\onon-plugins"
New-Item -ItemType Directory -Force "$env:APPDATA\onon\plugins"
Copy-Item -Recurse "$env:APPDATA\onon\onon-plugins\plugins\*" "$env:APPDATA\onon\plugins"
```

## Enable

onon finds plugins but runs only the ones your `config.lua` requires. `pcall` keeps the config working on machines without the plugin:

```lua
local has_file_browser, file_browser = pcall(require, "file-browser")
if has_file_browser then
  onon.bind("bf", file_browser.actions.browse)
end

local has_synctex, synctex = pcall(require, "synctex")
if has_synctex then
  synctex.editor = "code"
  synctex.editor_args = { "-g", "%f:%l:%c" }
end
```

Run `:reload-config` to load them. Each plugin's README covers its options, commands and setup.

## Writing your own

The [plugin guide](https://ononreader.com/docs/plugins/) covers the manifest, the API and its limits. These plugins are small enough to start from.

## License

[MIT](./LICENSE)
