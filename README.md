# onon-plugins

Example plugins for [onon](https://github.com/Aethar01/onon), a quiet reader for the keyboard.

| Plugin | What it does |
|---|---|
| [`file-browser`](./file-browser) | Browse directories and open documents without leaving onon. |
| [`synctex`](./synctex) | Jump between LaTeX source and PDF in both directions. |

## Install

Clone the repository as your plugin directory:

```bash
git clone https://github.com/Aethar01/onon-plugins ~/.config/onon/plugins
```

That path works on Linux and macOS. On Windows:

```powershell
git clone https://github.com/Aethar01/onon-plugins "$env:APPDATA\onon\plugins"
```

If you already have a `plugins` directory, clone the repository somewhere else and copy in the plugins you want. Each one is a self-contained directory. `git pull` updates a clone.

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
