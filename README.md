# darktable-assisted-grouping

A grouping assistant for [darktable](https://www.darktable.org/). Select a batch of images in lighttable, click one button, and it will:

- split your selection into **Bursts** by capture time, to the sub-second where the files carry it
- optionally divide those bursts further by **camera and lens**, by a **tag**, and by the child of a **parent tag**
- write the result as **group tags** under `Assisted Grouping|<run time>|…`, as **darktable groups** that collapse in lighttable, or both

Everything runs locally: a Lua plugin inside darktable and a small Python helper (Pillow and exifread) that reads sub-second capture times. No models, no cloud. It only adds and removes its own `Assisted Grouping|…` tags and the darktable groups it made; tags and groups you made by hand are never touched (see [Limitations](#limitations)).

It is the third plugin next to `darktable-assisted-tagging` and `darktable-assisted-culling`. The three can be installed side by side. Grouping does one job, and the other two read its groups instead of each clustering bursts on their own: darktable groups, or its `Group` tags. Tagging picks between them with its **grouping support** setting, culling with its **Cull by native groups** checkbox and **tag node** boxes (see Grouping support in the [culling](../darktable-assisted-culling/README.md#grouping-support) and [tagging](../darktable-assisted-tagging/README.md#grouping-support) READMEs).

> **Status: not yet run inside darktable.** The pure logic and the Python helper are tested; the darktable side has never been run. Work through the [Acceptance checklist](docs/testing.md#acceptance-checklist) first and report what breaks.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Documentation](#documentation)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

## Requirements

- darktable built with Lua (the official builds are). The plugin only checks for Lua API 7.0.0 or later; the minimum darktable version has not been confirmed.
- Python 3.9+ with `Pillow` and `exifread` (`python/requirements.txt`). `exifread` reads RAW (ARW) files Pillow can't open; without it, RAWs fall back to borrowing from their JPEG. Without Python the plugin still runs, at whole-second precision.
- Windows: `git` and `curl` (Windows 10+ ships `curl`). Linking the plugin needs Developer Mode on (`Win + R`, then `ms-settings:developers`) or an Administrator prompt; without either, copy the files instead (step 2).

## Install

Do the steps in order: Python, darktable, plugins folder.
Commands come first under each step; the reasons follow them.

### 1. Python side

```
git clone <repo url> darktable-assisted-grouping
cd darktable-assisted-grouping

# Windows (Command Prompt or PowerShell)
python -m venv .venv
.venv\Scripts\pip install -r python\requirements.txt

# Linux / macOS (no plain `python` on macOS)
python3 -m venv .venv
.venv/bin/pip install -r python/requirements.txt
```

### 2. darktable side

Run the block for your system from the repo root, the folder holding `README.md`. It puts the two plugin files into darktable's `lua/contrib` folder and adds one `luarc` line. Run it again from each other Assisted plugin's repo that you install; nothing is added twice.

Linux / macOS (links):

```
mkdir -p ~/.config/darktable/lua/contrib
ln -sf "$(pwd)/lua/assisted_grouping.lua" ~/.config/darktable/lua/contrib/assisted_grouping.lua
ln -sf "$(pwd)/lua/plugin_common.lua" ~/.config/darktable/lua/contrib/plugin_common.lua
grep -qs 'assisted-loop' ~/.config/darktable/luarc || echo 'do local d = require("darktable"); local f = io.open(d.configuration.config_dir .. "/dt-lua-errors.txt", "a"); for _, n in ipairs({"assisted_tagging", "assisted_culling", "assisted_grouping"}) do local h = io.open(d.configuration.config_dir .. "/lua/contrib/" .. n .. ".lua", "r"); if h then h:close(); local ok, e = pcall(require, "contrib/" .. n); f:write(n, " ", ok and "loaded" or ("FAILED " .. tostring(e)), "\n") end end f:close() end -- assisted-loop' >> ~/.config/darktable/luarc
```

Windows (Command Prompt, copies; no Administrator or Developer Mode needed, re-run after every update):

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
copy /Y lua\assisted_grouping.lua "%LOCALAPPDATA%\darktable\lua\contrib\"
copy /Y lua\plugin_common.lua "%LOCALAPPDATA%\darktable\lua\contrib\"
findstr /C:"assisted-loop" "%LOCALAPPDATA%\darktable\luarc" >nul 2>&1 || echo do local d = require("darktable"); local f = io.open(d.configuration.config_dir .. "/dt-lua-errors.txt", "a"); for _, n in ipairs({"assisted_tagging", "assisted_culling", "assisted_grouping"}) do local h = io.open(d.configuration.config_dir .. "/lua/contrib/" .. n .. ".lua", "r"); if h then h:close(); local ok, e = pcall(require, "contrib/" .. n); f:write(n, " ", ok and "loaded" or ("FAILED " .. tostring(e)), "\n") end end f:close() end -- assisted-loop >> "%LOCALAPPDATA%\darktable\luarc"
```

Windows (Command Prompt, links; needs Developer Mode on, `Win + R` then `ms-settings:developers`, or an Administrator prompt; links follow the repo, so no re-run after an update):

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
del "%LOCALAPPDATA%\darktable\lua\contrib\assisted_grouping.lua" "%LOCALAPPDATA%\darktable\lua\contrib\plugin_common.lua" 2>nul
mklink "%LOCALAPPDATA%\darktable\lua\contrib\assisted_grouping.lua" "%CD%\lua\assisted_grouping.lua"
mklink "%LOCALAPPDATA%\darktable\lua\contrib\plugin_common.lua" "%CD%\lua\plugin_common.lua"
findstr /C:"assisted-loop" "%LOCALAPPDATA%\darktable\luarc" >nul 2>&1 || echo do local d = require("darktable"); local f = io.open(d.configuration.config_dir .. "/dt-lua-errors.txt", "a"); for _, n in ipairs({"assisted_tagging", "assisted_culling", "assisted_grouping"}) do local h = io.open(d.configuration.config_dir .. "/lua/contrib/" .. n .. ".lua", "r"); if h then h:close(); local ok, e = pcall(require, "contrib/" .. n); f:write(n, " ", ok and "loaded" or ("FAILED " .. tostring(e)), "\n") end end f:close() end -- assisted-loop >> "%LOCALAPPDATA%\darktable\luarc"
```

Then restart darktable and open `dt-lua-errors.txt` in the config directory (`~/.config/darktable` on Linux/macOS, `%LOCALAPPDATA%\darktable` on Windows). `assisted_grouping loaded` means it worked: the panel appears in lighttable once the view has finished loading. `assisted_grouping FAILED ...` gives the reason.

**Why these steps.**

- The plugin is two files, and both must sit in `lua/contrib`: `lua/assisted_grouping.lua` and `lua/plugin_common.lua`. `plugin_common.lua` is the module the three Assisted plugins share. The three copies are identical, so each plugin's block overwrites the same file harmlessly.
- Without `plugin_common.lua` the plugin fails with `module 'plugin_common' not found`. It has no `luarc` line of its own: the plugin loads it with `loadfile`, looking beside itself first, then in the **plugins folder** preference. Nothing copies it for you, and on a new device the preference does not exist yet (it is registered only after the plugin loads), so put it in `lua/contrib`.
- The `luarc` line is one loop for all three plugins. For each of `assisted_tagging`, `assisted_culling` and `assisted_grouping` whose file is in `lua/contrib`, it loads the plugin inside `pcall` and appends `loaded` or `FAILED <reason>` to `dt-lua-errors.txt`. A plugin you did not install is skipped without a line. The `assisted-loop` marker at its end stops a second run from adding it again.
- Replacing an older setup: delete any per-plugin `pcall` or `require "contrib/..."` lines for these plugins from `luarc`, then run the block.
- Keep `require "tools/script_manager"` (the scripts panel, from the separate `lua-scripts` repo) on the first line of `luarc`, above the loop. If the scripts panel is missing, remove the loop line, restart, and check `dt-lua-errors.txt` after adding it back.
- Copies must be re-made after every update; links follow the repo.

### 3. Point the plugin at the repo

Start darktable, open **preferences → lua options**, and set **plugins folder (holds the three assisted-* folders)** to the folder that holds `darktable-assisted-grouping` (and the other assisted plugins). From there the plugin finds `python/exif_times.py` and the `.venv` by itself. A folder whose `darktable-assisted-grouping` has no `python/exif_times.py` is an error. The preference is shared by the assisted plugins; the older per-plugin **Assisted Grouping: Plugin folder** preference still works, and the log says once to move it. There is no interpreter preference, because each assisted plugin has different requirements: the plugin looks for its own `.venv` (in the repo folder it found `exif_times.py` in, or one level above the Lua files), and only then falls back to `python` (Windows) or `python3` on your `PATH`.

## Documentation

- [Using it](docs/usage.md): What a run does, re-running and clearing, the ledger, cancelling.
- [Panel options](docs/panel-options.md): Presets, every panel setting, and the preferences.
- [How it works](docs/how-it-works.md): Timing precision and how bursts and groups are decided.
- [Testing and development](docs/testing.md): The Windows acceptance checklist, the tests and the helper.

## Troubleshooting

- **The panel isn't there.** Start darktable with `-d lua` and look for `LUA ERROR` in the log. On Windows the log is `Documents\Darktable\darktable-log.txt`. A `module ... not found` error means darktable is loading an old copy of `assisted_grouping.lua`: re-link or re-copy it from this repo.
- **Every run writes a log** to `assisted_grouping.log` in darktable's config directory (`%LOCALAPPDATA%\darktable\assisted_grouping.log` on Windows); the 5 runs before it are kept as `assisted_grouping.prev.log` (the last one), `assisted_grouping.prev2.log` … `assisted_grouping.prev5.log`. Each line is written as it happens, so a crash leaves the last step in the file; each stage logs `started` and `done` with its seconds, and a failed write names its image. It has the run stamp and every setting, the timing line, the frame and group counts, how many images the parent layer left unsplit, the tags attached and detached, the darktable groups made and skipped, every message shown on screen, and the helper's errors. Start here when a result looks wrong.
- **"the plugins folder preference gives …, which has no python/exif_times.py."** Point the preference at the folder holding `darktable-assisted-grouping`, or clear it to auto-detect.
- **The run always says whole-second.** Read the reason on the `timing:` line. If it counts frames with none, the helper couldn't read those files: on a RAW-only selection check that `exifread` is installed in the interpreter, or select the JPEGs too. "exif_times.py stopped with exit code …" usually means the interpreter has no Pillow: install `python/requirements.txt` into it.
- **"Another job is still running."** Wait, or cancel it from the progress bar.
- **"No selected image has the tag …"** The tag layer matched nothing, so every image is `not …`. Check the spelling and spaces against the tagging module (`Cars|Red`, not `Cars | Red`).
- **`dt_assisted_grouping_*` files in darktable's tmp folder** are from a helper that was still running at a cancel or the 10-minute timeout. They're safe to delete once it has finished.
- **Some images weren't put into a darktable group.** The log's `native groups: … skipped (already in a hand-made group)` counts them. Take them out of that group by hand if you want the plugin to group them.
- **"couldn't save the ledger …"** on screen: the tags and groups that run made will look hand-made next time, and the old ledger is left as it was. Check that darktable's config directory is writable and the disk isn't full.

## Limitations

Known gaps, not yet fixed:

- **RAW reading is confirmed on one file only.** ARW sub-seconds were read from one Sony ZV-E10 file; other cameras and RAW formats are untested. See [Timing precision](docs/how-it-works.md#timing-precision).
- **Group Tags off** leaves tags from earlier runs on the images, and *last run's groups* still reads them.
- **Group mates removed from the library.** An image whose plugin group mates were all removed from the library counts as taken out by hand for one more run, until the ledger drops them.
- **Cancel during tag writing** leaves partial tags. Only a cancel before anything is applied is guaranteed to change nothing, and a cancel is ignored once darktable groups have started.
- **Undated frames with start from set to *one group*** all share the one starting group.
- **Clear acts on the selection and its RAW/JPEG partners only.** Other unselected images keep their marks. Tags of old runs are detached but not deleted from darktable's tag library.
- **Unsaved panel changes** (checkboxes, text fields) are lost at restart: the panel reopens on the last preset you picked, with its saved values.
- **"images grouped"** in the log counts the leader too.
- **"left as they were"** in the log counts images whose darktable group already matched the result (same images, lowest id leading). A second run on the same selection writes no group changes.
- **Narrow panel.** Labels end in an ellipsis when the right panel is narrow.
- **The partial-burst warning** is static text, shown whatever you selected.
- **Same-second runs** are stamped one second apart, so a stamp can be a second later than the run actually started.
- **No merging.** Layers only divide. To get bigger bursts, re-run with a larger burst gap.

## License

MIT, see [LICENSE](LICENSE).
