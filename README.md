# darktable-assisted-grouping

A grouping assistant for [darktable](https://www.darktable.org/). Select a batch of images in lighttable, click one button, and it will:

- split your selection into **Bursts** by capture time, to the sub-second where the files carry it
- optionally divide those bursts further by **camera and lens**, by a **tag**, and by the child of a **parent tag**
- write the result as **group tags** under `Assisted Grouping|<run time>|…`, as **darktable groups** that collapse in lighttable, or both

Everything runs locally: a Lua plugin inside darktable and a small Python helper (Pillow and exifread) that reads sub-second capture times. No models, no cloud. It only adds and removes its own `Assisted Grouping|…` tags and the darktable groups it made; tags and groups you made by hand are never touched (see [Limitations](#limitations)).

It is the third plugin next to `darktable-assisted-tagging` and `darktable-assisted-culling`. The three can be installed side by side. Grouping does one job, and the other two read its groups instead of each clustering bursts on their own: darktable groups, or its `Group` tags. Tagging picks between them with its **grouping support** setting, culling with its **Cull by native groups** checkbox and **tag node** boxes (see Grouping support in the [culling](../darktable-assisted-culling/README.md#grouping-support) and [tagging](../darktable-assisted-tagging/README.md#grouping-support) READMEs).

> **Status: not yet run inside darktable.** The pure logic and the Python helper are tested; the darktable side has never been run. Work through the [Acceptance checklist](#acceptance-checklist) first and report what breaks.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using it](#using-it)
- [Panel options](#panel-options)
- [Presets](#presets)
- [Preferences](#preferences)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Acceptance checklist](#acceptance-checklist)
- [Development](#development)

## Requirements

- darktable built with Lua (the official builds are). The plugin only checks for Lua API 7.0.0 or later; the minimum darktable version has not been confirmed.
- Python 3.9+ with `Pillow` and `exifread` (`python/requirements.txt`). `exifread` reads RAW (ARW) files Pillow can't open; without it, RAWs fall back to borrowing from their JPEG. Without Python the plugin still runs, at whole-second precision.

## Install

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

darktable's config directory is `~/.config/darktable` on Linux/macOS and `%LOCALAPPDATA%\darktable` on Windows. Link the plugin into it and load it from `luarc`.

The plugin is `lua/assisted_grouping.lua` plus `lua/plugin_common.lua`, the module the three Assisted plugins share. A link into the repo finds the module beside the plugin by itself.

Linux / macOS:

```
mkdir -p ~/.config/darktable/lua/contrib
ln -s "$(pwd)/lua/assisted_grouping.lua" ~/.config/darktable/lua/contrib/assisted_grouping.lua
echo 'require "contrib/assisted_grouping"' >> ~/.config/darktable/luarc
```

Windows (Command Prompt). Creating symbolic links needs an Administrator prompt unless Developer Mode is enabled.

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
mklink "%LOCALAPPDATA%\darktable\lua\contrib\assisted_grouping.lua" "%CD%\lua\assisted_grouping.lua"
echo require "contrib/assisted_grouping" >> "%LOCALAPPDATA%\darktable\luarc"
```

Windows (PowerShell). Same Administrator caveat.

```
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\darktable\lua\contrib"
New-Item -ItemType SymbolicLink -Path "$env:LOCALAPPDATA\darktable\lua\contrib\assisted_grouping.lua" -Value "$PWD\lua\assisted_grouping.lua"
Add-Content "$env:LOCALAPPDATA\darktable\luarc" 'require "contrib/assisted_grouping"'
```

Windows without Administrator rights or Developer Mode: copy `assisted_grouping.lua` into `%LOCALAPPDATA%\darktable\lua\contrib` instead of linking it, and add the same `luarc` line. Re-copy it after every update. The **plugins folder** preference (next step) still points the plugin at this repo for the Python side, and the plugin loads `plugin_common.lua` from that folder's `darktable-assisted-grouping/lua/` when the module is not beside the copied file (copy it too if you want darktable to start with the preference unset; the three plugins' copies are identical, so one copy in `contrib` serves all of them).

### 3. Point the plugin at the repo

Start darktable, open **preferences → lua options**, and set **plugins folder (holds the three assisted-* folders)** to the folder that holds `darktable-assisted-grouping` (and the other assisted plugins). From there the plugin finds `python/exif_times.py` and the `.venv` by itself. A folder whose `darktable-assisted-grouping` has no `python/exif_times.py` is an error. The preference is shared by the assisted plugins; the older per-plugin **Assisted Grouping: plugin folder** preference still works, and the log says once to move it. There is no interpreter preference, because each assisted plugin has different requirements: the plugin looks for its own `.venv` (in the repo folder it found `exif_times.py` in, or one level above the Lua files), and only then falls back to `python` (Windows) or `python3` on your `PATH`.

## Using it

Select the photos in lighttable, pick the layers and outputs in the **Assisted Grouping** panel (right side), and click **Group Selection**. A progress bar appears in darktable's job area; its cancel button stops the run (see [Cancel](#cancel)). When it finishes, the message line says how many images ended up in how many groups, whether timing was sub-second or whole-second, and the run's stamp. Instead of the timing it says "timing off" when **Start From** is *one group* or *last run's groups*, or "no timing needed" when *capture time* has nothing left to time; capture times aren't read in either case.

Running all three plugins? [WORKFLOW.md](WORKFLOW.md) says which order to pick and what to re-run after what.

Select **whole bursts, or the whole shoot**. Bursts are built from the selected frames only, so selecting part of a burst splits it. The panel shows this warning permanently.

### What you get

Each run has a **stamp**: its start time in UTC as `YYYY-MM-DD HH:MM:SS`, so a later run always sorts after an earlier one, across daylight-saving changes and time zones. Older versions of the plugin stamped local time; within your UTC offset of the upgrade, an old run can sort after a new one, and regrouping those photos fixes it. Every tag the run writes sits under `Assisted Grouping|<stamp>|`, so groups from different runs never collide. Two runs started in the same second get stamps one second apart.

With **Group Tags** on, every photo gets the `Group` tag. With **Layer Trace Tags** also on, it gets the four layer trace tags too:

| Tag | When | Example |
|---|---|---|
| `Assisted Grouping\|<stamp>\|Group\|NNNN` | always | `Assisted Grouping\|2026-11-08 14:03:21\|Group\|0007` |
| `Assisted Grouping\|<stamp>\|Session\|NNNN` | **session gap** above 0, on photos with a capture time | `Assisted Grouping\|2026-11-08 14:03:21\|Session\|0002` |
| `Assisted Grouping\|<stamp>\|Burst\|NNNN` (layer trace) | **Start From** is *capture time* and a camera, tag or parent layer is on, or **minimum burst size** is above 2 (written even when that layer splits nothing) | `Assisted Grouping\|2026-11-08 14:03:21\|Burst\|0003` |
| `Assisted Grouping\|<stamp>\|Camera\|<maker model lens>` (layer trace) | Camera and Lens on | `Assisted Grouping\|2026-11-08 14:03:21\|Camera\|SONY ZV-E10 E PZ 16-50mm F3.5-5.6 OSS` |
| `Assisted Grouping\|<stamp>\|Tag\|has <tag>` or `…\|not <tag>` (layer trace) | a tag is typed | `Assisted Grouping\|2026-11-08 14:03:21\|Tag\|has Red` |
| `Assisted Grouping\|<stamp>\|Parent\|<child>` or `…\|none` (layer trace) | a parent tag is typed | `Assisted Grouping\|2026-11-08 14:03:21\|Parent\|42` |

- `Group` is the final group after every layer; it's the one to read. When timing is the only layer, `Burst` would repeat `Group` exactly, so it is not written. A minimum burst size above 2 counts as a layer: `Burst` then keeps the number of each burst it left as single frames. `Burst` is the timing layer's result alone, for a consumer that only wants bursts. With *last run's groups* or *one group* there is no timing layer, so no `Burst` tag is written.
- `Session` sits above the groups: photos in capture order, with a new session after every gap longer than the **session gap**. It never splits or joins a group, and a photo with no capture time gets none. The frames of one group can carry different `Session` numbers when the session gap is shorter than the gap inside the group (a session gap below the burst gap, or *one group* / *last run's groups* as the start).
- Numbers are four digits, zero-padded, counted from `0001` within a run.
- `Camera` is maker, model and lens joined with spaces; `unknown` when darktable has none of them.
- `Tag` uses the last segment of the tag you typed (`Cars|Red` gives `has Red`).
- `Parent` is the photo's single child directly under the node, or `none` when it has none or several.
- `|`, `;`, `,`, `"` and control characters in a camera, lens or tag name are replaced with spaces, so they can't break the tag hierarchy or the ledger.

With **Apply darktable Groups** on, each final group of two or more images becomes one darktable group, led by its lowest image id. To collapse them, turn grouping on in lighttable; how depends on your darktable version (look for the grouping on/off toggle in the lighttable top bar; unverified). A final group of a single image gets no darktable group (a lone RAW+JPEG frame is two images, so it does get one).

### RAW+JPEG pairs and duplicates

A RAW and a JPEG with the same folder and filename stem (extension and case ignored, as darktable pairs them at import: `DSC0001.ARW`, `DSC0001.JPG` and `dsc0001.jpg` are one frame) are one frame, and so are duplicates (versions) of one file. Every member gets the same group and the same tags. This doesn't depend on darktable's own RAW+JPEG grouping at import: the plugin matches folder and stem either way, and a darktable group that holds only one frame's files doesn't count as hand-made.

### Re-running and clearing

**Replace (the default).** A re-run replaces the plugin's own earlier output on the selected images: tags from earlier runs that the ledger lists are detached, the new run's tags attached, and images are taken out of the plugin's old darktable groups before the new ones are built (each image is first moved into a group of its own, so a re-run can't scatter a group). Nothing the ledger doesn't list is touched. A frame you moved by hand from one plugin group into another keeps its place: both groups count as hand-made and the re-run skips them, as it does a group joined with **Merge Groups**. An image you took out of a plugin group to stand alone stays alone, and so does a plugin group you broke up by hand.

**start from: last run's groups.** Instead of burst timing, the starting groups are each photo's `Group` tag from the latest earlier run (latest stamp wins when a photo has several). Photos with no group tag share one starting group, and the burst gap is hidden and unused. Camera, tag and parent layers then divide as usual. The tags are the source of truth here: changes you made to darktable groups by hand are not read. The old tags are then replaced as in a normal run.

**Clear Grouping Marks** removes, from the selected images, the tags and darktable groups the ledger says the plugin made, and drops their ledger rows. It takes along the unselected images of a selected frame (the RAW of a selected JPEG, or the other way round, found in the same film roll), so a pair never ends up half cleared. An image you moved out of a plugin group by hand is left where it is. Your own tags and groups stay. The selected images of one frame (a RAW+JPEG pair or duplicates, same folder and filename stem) that Clear takes out of a plugin group are put back into one darktable group, led by the lowest id, so Clear doesn't break up the pairs darktable grouped at import.

**browse as pairs** takes the selected images, and every image grouped with them, out of their darktable groups, then puts each frame's files (same folder and filename stem) back into one group led by the lowest id, as darktable does at import. Tags stay, including the group tags, so you can switch between burst groups and pairs: **browse as pairs** after culling to browse each kept frame with its JPEG stacked, then click **browse as bursts** to come back. Hand-made groups are reset too, and the ledger forgets the plugin's darktable groups for these images. **browse as bursts** puts the selected photos back into darktable groups from each photo's newest `Group` tag (photos without one stay alone; photos in a hand-made group are skipped), with no Python and no capture times read; it needs Group Tags to have been on, and on untagged frames it says "nothing to browse. The selection has no group tags; run Group Selection with Group Tags on first.". **Group Selection** also brings the bursts back, but runs the whole pipeline.

### The ledger

The plugin records what it made in `assisted_grouping/ledger.csv` in darktable's config directory (`%LOCALAPPDATA%\darktable\assisted_grouping\ledger.csv` on Windows). Rows are `<library>,id,tag,<tag name>` for each tag it attached and `<library>,id,group,<leader id>` for each image it put in a darktable group. `<library>` is a hash of the library file's path (image ids restart in every library, so each library's rows are kept apart; rows from before this column belong to the library in use when they're first read). Anything not in the ledger is yours. A plugin tag you removed by hand drops out of the ledger the next time a run writes tags on that image, and rows for images removed from the library are dropped whenever the ledger is saved. A group whose leader image was removed is then re-pointed to its lowest remaining id (log: `ledger: N groups had a leader no longer in the library`), and a group with one image left is no longer counted as the plugin's. A failed save is tried once more before the on-screen error. Deleting the file makes every existing `Assisted Grouping` tag and group look hand-made: re-runs and Clear then leave them alone. A library opened with `--library` on the command line is not visible to the plugin and counts as the configured one.

### Cancel

- **Before anything is written** (while the helper reads times, or while groups are worked out) a cancel changes nothing: "cancelled, nothing was changed."
- **While tags are being written** a cancel stops partway and says how many images were updated; run again to finish. The ledger is saved, so the partial tags are still the plugin's.
- **Once darktable groups have started** a cancel is ignored, so no group is left half-built. The log says when that step starts.

If a job is already running, a second click queues the new job; it starts when the current one finishes. A cancel drops every queued job too ("N queued jobs dropped"): it means "stop what I started".

A cancel doesn't wait for the helper. If it is still reading files, it finishes in the background and leaves its temp files in darktable's tmp folder; the next run starts straight away with new ones.

## Presets

The **Preset** picker at the top of the panel saves every panel setting (start from, the burst gap, the minimum burst size, the layers, the outputs and the session gap) under a name, so a shoot type is one click away.

- **Preset**: `template` first, then your presets by name. Picking one loads its values into the panel. The panel opens on the last one you picked.
- **template**: the built-in defaults. It can't be updated, renamed or deleted; use it as the starting point for a new preset.
- **Actions** beside it: **update preset "<name>"** saves the panel into the selected preset; **store new preset…** asks for a name (type it, then **OK**) and saves the panel as a new preset; **rename preset…**; **delete preset** asks first. On `template` only **store new preset…** is offered.
- **Unsaved Changes** shows under the picker when the panel differs from the saved preset. Switching presets drops them. Text fields have no change signal, so their edits show when **Actions** is opened or a run starts.
- Each preset is `assisted_grouping/presets/<name>.json` in darktable's config folder. A name can't be `template` or use characters a Windows file name can't hold.
- Old files with `timing` and `refine` keys still load: both on, or only `refine` on, loads as *last run's groups*; `timing` off and `refine` not on loads as *one group*; anything else loads as *capture time*. **update preset** rewrites the file with `start_from`.
- A setting missing from a file uses its default; **update preset** writes every setting, so older files fill in. A value that's no longer valid uses the default and logs one line naming the preset and setting.
- A file that can't be read or parsed: the panel says so, names the file, and keeps its current values. The plugin never rewrites a broken file; fix or delete it.

## Panel options

Below the [preset](#presets) picker are the page buttons **1 Start Groups ▸**, **2 Divide Groups ▸**, **3 Output ▸**, **4 Run ▸** and **5 Tools ▸**: clicking one opens its contents below it (its label ends in **▾**) and folds the others; clicking the open one folds it. The open page is remembered across restarts. The [To check](#to-check) box and the partial-burst warning sit below the pages, shown whichever page is open. darktable's reset button (↺ in the panel header) puts every setting back to the template defaults; nothing is saved until you update a preset.

Layers run in a fixed order, and each one only divides the groups the one before produced; none merges.

### 1 Start Groups

- **Start From** (dropdown, default *capture time*). Where the groups begin before the divide layers run.
  - *capture time*: sorts the frames by capture time and starts a new group when the gap to the previous frame is longer than the burst gap. A frame with no capture time is a group of its own, never merged and never dropped. The **Burst Gap (Seconds)** box (text field, default `2`; frames closer together than this are one burst; decimals allowed, with a point or a comma, `0.5`, `1,5`; must be above 0, or the run refuses) shows only for this choice. Type `auto` instead of a number to pick the gap from the selection's own timing (experimental; the gap stays between 0.3 and 10 s): the log's `auto gap … s (…)` line shows the gap it chose, and with under 30 gaps or no clear split it uses 2.
  - *last run's groups*: starts from each photo's group tag from the latest earlier run; photos without one share one group (see [Re-running and clearing](#re-running-and-clearing)).
  - *one group*: every photo starts together, and only the divide layers below split it.
- **Minimum Burst Size (Frames)** (text field, default `2`; a whole number, 2 or more, or the run refuses). A final group (after the divide layers) with fewer frames than this is left as single frames: no darktable group for it, and each of its frames gets a Group tag of its own. A RAW+JPEG pair is one frame and still stacks as a pair. `2` keeps every group of two or more frames; `3` or more keeps stray pairs out of the groups. The log line `minimum burst size N: … smaller groups left as single frames` counts them. Applies to every **Start From** choice.

### 2 Divide Groups

- **Camera and Lens.** Divides each group by camera maker, model and lens, so two bodies or two lenses shooting the same moment end up apart. With **Start From** *capture time*, each camera is also timed on its own timeline, so one body's frames never join another's burst. Off by default.
- **Tag** (text field, e.g. `Cars|Red`). Divides each group into photos that carry exactly this tag and photos that don't. Child tags don't count. Empty = off.
- **Parent Tag** (text field, e.g. `Cars|Number`). Divides each group by which tag directly under this node a photo carries. A photo with no child under the node, or several, isn't split off by this layer: it stays with the group's first part. The log counts these photos.

With *one group* at least one divide layer must be on, or the run refuses: "turn on at least one divide layer (camera and lens, tag or parent tag), or start from capture time or last run's groups".

Separate bursts are never linked by the tag layers. One car tagged in bursts 3, 9 and 20 gives three groups: at a rally the cars loop past many times, and merging on the tag would pull unrelated passes together.

### 3 Output

Two headings, **Outputs** and **How It Decided**.

- **Apply darktable Groups** (on by default). One darktable group per final group of two or more images (a lone RAW+JPEG frame counts). Images already in a darktable group you made by hand are skipped, left in that group, and counted in the log. With only this output on, the layers are flattened into the final grouping, because a photo can only be in one darktable group.
- **Group Tags** (off by default; slower on large selections). The tags in [What you get](#what-you-get). Needed for *last run's groups*, **browse as bursts** and anything that reads the tags.
- **Session Gap (Minutes, 0 = Off)** (0 by default). Above 0, every photo with a capture time also gets a `Session` tag: photos are walked in capture order and a gap longer than this many minutes starts the next session, e.g. `30` separates the morning from the afternoon. Decimals work (`0.5`, `2,5`). Sessions are tags only, so Group Tags must be on; they don't change the groups or the darktable groups. The log says "sessions: N (a new one after a gap above M minutes)".
- **Layer Trace Tags** (under **How It Decided**; off by default, slower on large selections). The `Burst`, `Camera`, `Tag` and `Parent` tags showing which layer split each group. Written only when Group Tags is on, since they ride on the same tag write. A preset saved before Layer Trace Tags existed, with **Group Tags** on (`write_tags: true`) and no `trace_tags`, loads with both switches on, and the log says so; one saved with it off loads with Layer Trace Tags off.

At least one output must be on, or the run refuses: "turn on at least one output (group tags or darktable groups)". Each output is only changed when it's on: a run with darktable groups off leaves the plugin's earlier darktable groups as they are, and a run with tags off leaves its earlier tags.

A notice line below the pages says what would stop or undermine the next run, in this priority: "turn on at least one output (group tags or darktable groups)", then "the burst gap must be auto or a number of seconds above 0, e.g. 2 or 0.5", then "the minimum burst size must be a whole number of frames, 2 or more", then "the session gap must be a number of minutes, e.g. 30, or 0 for off", then "turn on Group Tags, or this run's groups aren't saved for the next run to start from" (*last run's groups* without Group Tags), then "one group needs a divide layer: turn on Camera and Lens, or type a Tag or Parent Tag" (*one group* with no layer), then "turn on Group Tags, or no Session tags are written" (a session gap above 0 without Group Tags; the run still goes ahead, without Session tags). It is hidden when nothing is wrong. It updates from the **Start From** dropdown, the four checkboxes (Camera and Lens, Apply darktable Groups, Group Tags, Layer Trace Tags), a preset load, the reset and the **Group Selection** click. Text typed into burst gap, minimum burst size, session gap, Tag or Parent Tag is only checked after one of those.

### 4 Run

Two headings, **Group (Uses Pages 1 to 3)** and **browse as**.

- **Group Selection.** Runs the layers on the selected photos and writes the outputs that are on. After the `… frames in … groups` line the log lists each group's weakest link, widest first (the ten widest): `group 0003: 12 frames, 1.80 s before DSC00042.JPG` means group 3's largest time gap between neighbouring frames is 1.80 s, just before that file. The frame count is the whole group, including frames with no capture time. A gap close to the burst gap marks a group that may hold two bursts; lower the gap or split it by hand. After that come the cut hints (the first ten, by group): `group 0003 before DSC00042.JPG: focal length 70 to 200 mm` means the lens or exposure setting jumped between that file and the frame before it inside one group. A jump is focal length changing by 1.5× or more, exposure time by 4× (two stops) or more, or focus distance by 2× or more; a setting darktable has no value for is skipped. Hints are log lines only and change no group.
- **Verify Selection.** Checks the selected photos against a fresh **Group Selection** run with the current settings, and writes nothing: no tag, no darktable group, no ledger change. The toast says "verify only, nothing changed. N of M images differ from a fresh Group Selection run, K are in a group with no leader inside it." Each finding goes to [To check](#to-check). Frames a re-run would skip as hand-made (hand-made darktable groups, or frames you moved) count as correct and are left out, tags too.
- **browse as** (darktable groups only; tags are kept), with two buttons. **Bursts** puts the selected photos back into darktable groups from each photo's newest `Group` tag; with no group tags it says "nothing to browse. The selection has no group tags; run Group Selection with Group Tags on first.". **Pairs** ungroups the selected photos and their groups, then stacks each RAW with its JPEG again; tags stay. See [Re-running and clearing](#re-running-and-clearing).
- **Merge Groups** (under "fix by hand"). Joins the darktable groups of the selected photos into one, for a burst the run split: select one image of each group. The merged group counts as made by hand, so **Group Selection** keeps it and **Clear Grouping Marks** leaves it; tags stay. **Pairs** takes it apart again. With images from only one group it says "nothing to merge".

### 5 Tools

- **Clear Grouping Marks** (under **Undo**). Removes the plugin's tags and darktable groups from the selected photos (see [Re-running and clearing](#re-running-and-clearing)).

Everything in sections 1 to 3 is saved with the [preset](#presets).

### To Check

A box below the pages lists what a run leaves for you to look at, so a toast that went by unseen isn't lost. It shows only when it has items.

- The box is headed **To Check**. Each item reads `<action>: <what happened>` in full, wrapped over as many lines as it needs, with its buttons below: an error, or a **Clear Grouping Marks** cancelled partway (`clear cancelled: 39 photos not reached keep their marks`). The newest run's items sit on top. Older runs' items move below an *Earlier runs (before HH:MM): may not hold any more* line, since a later run can have settled them; they stay until you remove them, so a Fix still works.
- **Verify Selection** adds up to two rows, each with a **Fix** button:
  - `N photos differ from a fresh Group Selection run with these settings. Fix runs Group Selection on them.` Its details list each photo with its reasons: `darktable group differs`, `no Group tag` or `Group tag differs` (the last two only with Group Tags on). A group of one, or a Group tag with no darktable group behind it, shows up here too.
  - `N photos are in a darktable group whose leader is missing or outside it. Fix makes the group's lowest image its leader.` Fix leaves the group's members as they are and only sets its leader.
- **Select** beside a line selects its photos in the lighttable. Photos removed from the library since are skipped, and a toast counts them.
- The next run of the same action replaces that action's lines; other actions' lines stay. **Clear List**, under the items, empties the box.
- Six lines show; more add `and N more (see the log)`. The list is saved to `assisted_grouping.checks.txt` in darktable's config folder, so it survives a restart.
- A cancel that changed nothing adds no line. The partial-burst warning stays as standing guidance below the box.

## Preferences

In **preferences → lua options**. Everything else is a panel setting saved with its [preset](#presets).

| Preference | Default | What it does |
|---|---|---|
| plugins folder (`assisted_plugins/plugins_root`) | empty | The folder holding the assisted-* repos; this plugin uses `<plugins folder>/darktable-assisted-grouping` (holds `python/` and `.venv`). Empty = auto-detect. The old `assisted_grouping/plugin_folder` (this repo's folder) is still read and logged as deprecated |

## How it works

1. **Read the selection.** For each image: id, folder, filename, capture time (`exif_datetime_taken`), maker, model, lens and tags.
2. **Sub-second times.** darktable's Lua only gives whole seconds, which can't tell the frames of a fast burst apart. The plugin writes a manifest of the dated frames the timing layer uses (one file per frame: the JPEG of a RAW+JPEG pair, else the RAW; none at all unless **Start From** is *capture time*), runs `python/exif_times.py` on it (on Windows through `pythonw.exe` and `python/launch.py`, like the sibling plugins), and adds each file's sub-second fraction to darktable's time.
3. **Collapse frames.** RAW+JPEG pairs and duplicates become one frame.
4. **Run the layers** in order: the starting groups (capture time, last run's groups or one group), camera and lens, tag, parent tag, then the minimum burst size.
5. **Write.** Tags first (if on), then darktable groups (if on), then the ledger.

### Timing precision

`exif_times.py` reads `DateTimeOriginal` and `SubSecTimeOriginal` with Pillow, and falls back to the `exifread` package for files Pillow can't read or fields Pillow doesn't find. Probes of the Sony ZV-E10 found:

- **JPEG:** Pillow reads `SubSecTimeOriginal` (e.g. `897`, i.e. .897 s).
- **ARW:** Pillow can't read the file, but `exifread` reads both fields from it, so RAW (ARW) files are read directly. This was confirmed on one ZV-E10 ARW; other cameras and other RAW formats are untested.

When a frame's JPEG is in the selection, only the JPEG is read and **the RAW borrows its fraction** (same folder and filename stem, extension and case ignored). That halves the reads on a RAW+JPEG shoot. If that JPEG has no readable sub-second time, the RAW isn't tried and the run uses whole seconds. Only the fraction comes from the helper; the whole seconds always come from darktable.

If any timed frame on a timeline ends up with no fraction (a RAW-only frame neither reader can open, a file without the field, or the helper failing), **that whole timeline uses whole seconds**, so no timeline mixes the two. With **Camera and Lens** off the run is one timeline. With **Camera and Lens** on each camera (maker, model and lens) is its own timeline, so a body that records sub-seconds keeps them when a second body does not. The log says which, and why:

- `timing: sub-second`
- `timing: whole seconds for the whole run (3 of 40 frames had none)`
- with Camera and Lens on, one line per camera on whole seconds, such as `Sub-second time off for SONY ZV-E10 E 18-105mm F4 G OSS (40 of 40 frames had none)`, then `timing: sub-second, except the cameras above` when another camera kept them

On a whole-second timeline the automatic burst gap treats 0 s and 1 s gaps as the same, and the cut is never under 1 s.

The other reasons it can give: no frame has a capture time, the helper reported whole-second precision, the helper couldn't start, stopped with an error, wrote no results, or didn't finish within 10 minutes.

If a RAW format other than ZV-E10 ARW comes back whole-second, **keep the JPEGs selected when sub-second timing matters**, and check what the helper reads with `.venv\Scripts\python python\probe_subsec.py <file>` (macOS/Linux: `.venv/bin/python python/probe_subsec.py <file>`; see [Running the helper on its own](#running-the-helper-on-its-own)).

Capture times use a constant offset with no daylight saving (`isdst = false`), so a DST change can't split a burst.

## Troubleshooting

- **The panel isn't there.** Start darktable with `-d lua` and look for `LUA ERROR` in the log. On Windows the log is `Documents\Darktable\darktable-log.txt`. A `module ... not found` error means darktable is loading an old copy of `assisted_grouping.lua`: re-link or re-copy it from this repo.
- **Every run writes a log** to `assisted_grouping.log` in darktable's config directory (`%LOCALAPPDATA%\darktable\assisted_grouping.log` on Windows); the 5 runs before it are kept as `assisted_grouping.prev.log` (the last one), `assisted_grouping.prev2.log` … `assisted_grouping.prev5.log`. Each line is written as it happens, so a crash leaves the last step in the file; each stage logs `started` and `done` with its seconds, and a failed write names its image. It has the run stamp and every setting, the timing line, the frame and group counts, how many photos the parent layer left unsplit, the tags attached and detached, the darktable groups made and skipped, every message shown on screen, and the helper's errors. Start here when a result looks wrong.
- **"the plugins folder preference gives …, which has no python/exif_times.py."** Point the preference at the folder holding `darktable-assisted-grouping`, or clear it to auto-detect.
- **The run always says whole-second.** Read the reason on the `timing:` line. If it counts frames with none, the helper couldn't read those files: on a RAW-only selection check that `exifread` is installed in the interpreter, or select the JPEGs too. "exif_times.py stopped with exit code …" usually means the interpreter has no Pillow: install `python/requirements.txt` into it.
- **"another job is still running."** Wait, or cancel it from the progress bar.
- **"No selected photo has the tag …"** The tag layer matched nothing, so every photo is `not …`. Check the spelling and spaces against the tagging module (`Cars|Red`, not `Cars | Red`).
- **`dt_assisted_grouping_*` files in darktable's tmp folder** are from a helper that was still running at a cancel or the 10-minute timeout. They're safe to delete once it has finished.
- **Some photos weren't put into a darktable group.** The log's `native groups: … skipped (already in a hand-made group)` counts them. Take them out of that group by hand if you want the plugin to group them.
- **"couldn't save the ledger …"** on screen: the tags and groups that run made will look hand-made next time, and the old ledger is left as it was. Check that darktable's config directory is writable and the disk isn't full.

## Limitations

Known gaps, not yet fixed:

- **RAW reading is confirmed on one file only.** ARW sub-seconds were read from one Sony ZV-E10 file; other cameras and RAW formats are untested. See [Timing precision](#timing-precision).
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

## Acceptance checklist

The darktable side has never run: it was written without darktable to test against. Work through these steps on Windows, in order, and note the result of each. Use a test collection, or a copy of your library, for the first pass.

**Setup**

1. **Install Python.** In the repo folder: `python -m venv .venv`, then `.venv\Scripts\pip install -r python\requirements.txt`. *Expect:* Pillow and exifread install with no errors.
2. **Install the plugin** as in [Install](#2-darktable-side), linking **both** Lua files, and start darktable. *Expect:* an **Assisted Grouping** panel on the right in lighttable, with the page buttons *1 start groups ▾* (open, its settings below it) to *5 tools ▸*; opening *4 run* shows the **Group Selection** button, and the partial-burst warning sits below the pages. No `LUA ERROR` in the darktable log.
3. **Set the plugins folder** in **preferences → lua options → plugins folder (holds the three assisted-* folders)** to the folder holding the repo. *Expect:* the preference is saved; the panel's burst gap shows `2` on `template`.

**First run (tags only)**

4. **Select 30-60 frames with both RAW and JPEG of each frame**, including a fast burst, a night shot and frames from two different lenses. In the panel: **Start From** *capture time*, Group Tags ticked, Apply darktable Groups unticked (the defaults are Apply on, Group Tags off; tick Group Tags for this check, since steps 5 and 6 read the tags). Click **Group Selection**. *Expect:* a progress bar, then "Assisted Grouping: done. N images in M groups (sub-second timing). Run YYYY-MM-DD HH:MM:SS."
5. **Check the log** at `%LOCALAPPDATA%\darktable\assisted_grouping.log`. *Expect:* `group started`, the `run stamp …` settings line, `timing: sub-second`, `… frames in … groups (… bursts)`, `tags: … attached, 0 detached`, `run finished`.
6. **Check the tags** in the tagging module. *Expect:* each image has `Assisted Grouping|<stamp>|Group|NNNN` (and no `Burst` tag, since timing is the only layer); the frames of the fast burst share one `Group` number; a RAW and its JPEG have identical tags; the night shot has its own tags like the rest.
7. **RAW-only frames.** Select only the RAW (ARW) files of a few frames and run again. *Expect:* "(sub-second timing)" on screen and `timing: sub-second` in the log, since the helper reads ARW directly. If it says whole-second instead, run `.venv\Scripts\python python\probe_subsec.py <one of the files>` on one of them (macOS/Linux: `.venv/bin/python python/probe_subsec.py <one of the files>`).

**Layers**

8. **Camera and Lens.** Select the two-lens frames, tick **Camera and Lens**, **Group Tags** and **Layer Trace Tags**, run. *Expect:* a burst shot on two lenses splits into separate `Group` numbers, and each image has `Assisted Grouping|<stamp>|Camera|<maker model lens>`.
9. **Last run's groups.** Untick Camera and Lens, set **Start From** to *last run's groups* (the burst gap box hides) and tick **Group Tags** and **Layer Trace Tags**, type a tag that some of the frames carry into the Tag field, run. *Expect:* groups start from the previous run's `Group` tags and are split by the tag; images get `…|Tag|has <tag>` or `…|Tag|not <tag>`; the previous stamp's tags are gone from these images.

**Re-run and darktable groups**

10. **Hand-made marks.** Apply a tag of your own to two of the selected frames. Make a darktable group by hand from two frames in the middle of one selected burst (select both files of each frame and use your darktable version's group command; the shortcut is often ctrl+g, unverified). Also make a second hand-made group from two frames outside the selection.
11. **Darktable groups only.** Set **Start From** back to *capture time* and clear the Tag field. Make sure **Apply darktable Groups** is ticked, untick **Group Tags**, and run on the step 4 selection. *Expect:* with grouping turned on in lighttable (in your darktable version, look for the grouping on/off toggle in the lighttable top bar; unverified), each burst collapses to one thumbnail (the burst holding your hand-made group shows two stacks, because those images are skipped); both hand-made groups are unchanged; the log has `native groups: … images grouped, N skipped (already in a hand-made group)`, where N is the number of images in the first hand-made group (4 for two RAW+JPEG frames).
12. **Re-run replaces, no scattering.** Tick both outputs and run again on the same selection. *Expect:* the previous stamp's tags are gone from these images, only the new stamp's remain; your own tag survives; each burst is still one darktable group, with no images left in stray groups.
13. **Log and ledger location.** *Expect:* `assisted_grouping.log` and `assisted_grouping.prev.log` in `%LOCALAPPDATA%\darktable`, and `%LOCALAPPDATA%\darktable\assisted_grouping\ledger.csv` with `tag` and `group` rows for the step 4 selection.

**Clear, cancel, refusal**

14. **Clear.** With the same selection, click **Clear Grouping Marks**. *Expect:* "cleared grouping marks from N images"; the plugin's tags and darktable groups are gone; your own tag and the hand-made group are still there; the cleared images' rows are gone from `ledger.csv`; each RAW+JPEG pair is still one darktable group (two images per stack with grouping on), and the log's `clear:` line counts the `frame groups restored`.
15. **Cancel before applying.** Select all 30-60 frames, run, and cancel from the progress bar straight away. *Expect:* "cancelled, nothing was changed." and no new tags or groups. (If the run finished before you could cancel, note that instead.) Click **Group Selection** again straight after. *Expect:* it starts at once (no "still stopping" message) and finishes normally.
16. **Both outputs off.** Untick both outputs and click **Group Selection**. *Expect:* the run refuses with "turn on at least one output (group tags or darktable groups)" and nothing changes.
17. **Browse as pairs and back.** Tick both outputs, run **Group Selection** on RAW+JPEG frames, then select one collapsed burst and click **browse as pairs**. *Expect:* "reset N images to M RAW+JPEG pairs. Tags kept."; every frame of that burst is its own stack of two; the group tags are still on them; the log's `pairs:` line matches. Click **Bursts** on the same frames. *Expect:* "browsing N images as M bursts from their group tags.", the burst is one darktable group again, and the log has no helper (Python) line. Click **Group Selection** on the same frames too: the burst is one darktable group again.
18. **Old preset upgrade.** Load a preset saved before Layer Trace Tags existed, with `"write_tags": true` and no `trace_tags`. *Expect:* both **Group Tags** and **Layer Trace Tags** are ticked and the log says "preset upgraded: trace_tags set from write_tags". A preset with `"write_tags": false` loads with Layer Trace Tags unticked.
19. **Hand edits survive a re-run.** Run **Group Selection** on two neighbouring bursts. Move one frame (both its files) from burst A into burst B by hand. Select one image of each of two other bursts and click **Merge Groups**. Take one frame of a fourth burst out of its group to stand alone. Run **Group Selection** on all of them again. *Expect:* the moved frame is still in burst B, burst B is unchanged, the merged group is still one group, the frame you took out is still alone, and the log's `native groups:` line counts them as skipped. **Clear Grouping Marks** then leaves the merged group alone.
20. **Clear takes the RAW along.** Tick **Group Tags**, run **Group Selection** on RAW+JPEG frames, then select only their JPEGs and click **Clear Grouping Marks**. *Expect:* "cleared grouping marks from N images, M of them unselected RAW/JPEG partners"; the RAWs lose their group tag too, each RAW+JPEG pair is still one darktable group, and the log has `clear: M unselected RAW/JPEG partners of the selection included`.
21. **Export and import a preset.** Store a preset named `Rally`, then pick **export preset…** in the actions menu, choose an empty folder and click **Export**. *Expect:* `preset "Rally" exported to <folder>\Rally.atpreset`; that folder holds `manifest.json` and `preset.json`. Export again into the same folder. *Expect:* refused, "already exists". Pick **import preset…**, choose the `Rally.atpreset` folder, click **Import**. *Expect:* `imported "Rally (2)" … ("Rally" was taken); pick it in the preset list`; picking `Rally (2)` shows the same settings as `Rally`. Import the same bundle in Assisted Culling. *Expect:* refused, "the bundle is for assisted_grouping, not this plugin".
22. **Verify Selection.** Run **Group Selection** with both outputs on over two bursts, then move one frame into the other burst by hand, and remove one image's `Group` tag in the tagging module. Select the bursts and click **Verify Selection**. *Expect:* "verify only, nothing changed. 1 of N images differ…" (the untagged one; the moved frame counts as hand-made); no tag or group changed; a To check row whose details say `<file>: no Group tag`. Click its **Fix**. *Expect:* Group Selection runs on that photo, and a second Verify adds no row.
23. **Verify, missing leader.** In darktable, remove the leader image of one burst group from the library (or group one frame with a photo outside the selection, then remove that photo). Verify the burst. *Expect:* a row `… whose leader is missing or outside it`; its **Fix** makes the lowest image the leader, and a second Verify adds no row.

### Report what breaks

For each step that doesn't match, send back:

- the step number, and what happened instead (screenshot if it's visual)
- `assisted_grouping.log` from `%LOCALAPPDATA%\darktable` (copy it right after the failing step; the next run moves it to `assisted_grouping.prev.log`)
- any `LUA ERROR` lines from `Documents\Darktable\darktable-log.txt`, with darktable started with `-d lua`
- for a tag or group problem, the rows for the affected image ids from `assisted_grouping\ledger.csv`

## Development

### Tests

Run these from the repo root (the `darktable-assisted-grouping` folder).

One command runs every `python/test_*.py` and the Lua suite `lua/test_assisted_grouping.lua` (the grouping logic above its `require "darktable"`, no darktable needed), or only the ones named (e.g. `exif_times assisted_grouping`), and writes each one's output to `tests/<name>.txt`. The Lua suite uses a `lua` on PATH if there is one, else lupa: run `pip install lupa` in the venv once (Windows has no `lua` by default):

```
# Linux / macOS
.venv/bin/python python/run_tests.py

# Windows
.venv\Scripts\python python\run_tests.py
```

### Running the helper on its own

`manifest.csv` is `id,path` per line. `results.csv` gets one `id,epoch` row per manifest row (epoch blank when the file has no readable `DateTimeOriginal`), then `#precision,subsecond` or `#precision,whole`:

```
python python/exif_times.py manifest.csv results.csv
```

To see what a camera writes, the probe prints each file's capture time and sub-second fields (`path | DateTimeOriginal | SubSecTimeOriginal | SubSecDateTimeOriginal`, blank when missing):

```
# Windows
.venv\Scripts\python python\probe_subsec.py DSC0001.ARW DSC0001.JPG

# Linux / macOS
.venv/bin/python python/probe_subsec.py DSC0001.ARW DSC0001.JPG
```

### Notes from the darktable source

Shared with the sibling plugins, recorded so they don't cost time again:

- **`register_lib` takes eight positional arguments**: `(plugin_name, name, expandable, resetable, containers, widget, view_enter, view_leave)`. Leaving out `resetable` shifts the container table into a boolean slot and the panel never registers.
- **Registering a lib straight from `luarc` is a startup race.** darktable can report lighttable as the current view before the view has finished initialising, and a lib registered in that window is silently never attached (`src/views/view.c` documents it; the lua-scripts hit it as #19197). The plugin installs its panel from the `view-changed` event into lighttable instead, which fires only once the view is fully up.
- **`darktable-cli` never runs your `luarc`.** Anything GTK-wrapped (`register_lib`, `preferences.register`) blocks forever headless, so the plugin gates those on `dt.gui`.
- **Windows runs start with `start "" /B pythonw.exe launch.py <job>`.** The script and its arguments go in a job file, so none of them pass through cmd.exe. The command starts with `start`, not a quote, so cmd.exe keeps its quoted items intact (`lib/dtutils/system.lua` in darktable's lua-scripts wraps commands in a `.bat` because a command that starts with a quote gets mangled). There's no `.vbs`/`.bat` chain: antivirus behaviour checks (Bitdefender Advanced Threat Defense) flag a script host starting a hidden cmd from temp files. `pythonw.exe` must sit beside the `python.exe` the preference points at, as it does in a venv or a python.org install.
- **`group_with` first removes the image from its current group**, and removing a *leader* hands its group to another member. On a re-run, attaching to a leader that still sits in an old group would scatter the burst. So the plugin first calls `group_with()` with no leader on every image it will regroup (darktable moves it into a group of its own), and only then attaches the members to their new leader.
- **darktable's Lua gives capture time in whole seconds** (`exif_datetime_taken`, `YYYY:MM:DD HH:MM:SS`), which is why sub-seconds come from the Python helper.
- **Every tag attach or detach rewrites the image's XMP sidecar**, so writes are paced: after 12 writes the plugin sleeps 20 ms to keep the GUI responsive.

## License

MIT, see [LICENSE](LICENSE).
