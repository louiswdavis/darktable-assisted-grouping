# Panel options

Part of [darktable-assisted-grouping](../README.md). Presets, every panel setting, and the preferences.

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
  - *last run's groups*: starts from each image's group tag from the latest earlier run; images without one share one group (see [Re-running and clearing](usage.md#re-running-and-clearing)).
  - *one group*: every image starts together, and only the divide layers below split it.
- **Minimum Burst Size (Frames)** (text field, default `2`; a whole number, 2 or more, or the run refuses). A final group (after the divide layers) with fewer frames than this is left as single frames: no darktable group for it, and each of its frames gets a Group tag of its own. A RAW+JPEG pair is one frame and still stacks as a pair. `2` keeps every group of two or more frames; `3` or more keeps stray pairs out of the groups. The log line `minimum burst size N: … smaller groups left as single frames` counts them. Applies to every **Start From** choice.

### 2 Divide Groups

- **Camera and Lens.** Divides each group by camera maker, model and lens, so two bodies or two lenses shooting the same moment end up apart. With **Start From** *capture time*, each camera is also timed on its own timeline, so one body's frames never join another's burst. Off by default.
- **Tag** (text field, e.g. `Cars|Red`). Divides each group into images that carry exactly this tag and images that don't. Child tags don't count. Empty = off.
- **Parent Tag** (text field, e.g. `Cars|Number`). Divides each group by which tag directly under this node an image carries. An image with no child under the node, or several, isn't split off by this layer: it stays with the group's first part. The log counts these images.

With *one group* at least one divide layer must be on, or the run refuses: "Turn on at least one divide layer (camera and lens, tag or parent tag), or start from capture time or last run's groups.".

Separate bursts are never linked by the tag layers. One car tagged in bursts 3, 9 and 20 gives three groups: at a rally the cars loop past many times, and merging on the tag would pull unrelated passes together.

### 3 Output

Two headings, **Outputs** and **How It Decided**.

- **Apply darktable Groups** (on by default). One darktable group per final group of two or more images (a lone RAW+JPEG frame counts). Images already in a darktable group you made by hand are skipped, left in that group, and counted in the log. With only this output on, the layers are flattened into the final grouping, because an image can only be in one darktable group.
- **Group Tags** (off by default; slower on large selections). The tags in [What you get](usage.md#what-you-get). Needed for *last run's groups*, **browse as bursts** and anything that reads the tags.
- **Session Gap (Minutes, 0 = Off)** (0 by default). Above 0, every image with a capture time also gets a `Session` tag: images are walked in capture order and a gap longer than this many minutes starts the next session, e.g. `30` separates the morning from the afternoon. Decimals work (`0.5`, `2,5`). Sessions are tags only, so Group Tags must be on; they don't change the groups or the darktable groups. The log says "sessions: N (a new one after a gap above M minutes)".
- **Layer Trace Tags** (under **How It Decided**; off by default, slower on large selections). The `Burst`, `Camera`, `Tag` and `Parent` tags showing which layer split each group. Written only when Group Tags is on, since they ride on the same tag write. A preset saved before Layer Trace Tags existed, with **Group Tags** on (`write_tags: true`) and no `trace_tags`, loads with both switches on, and the log says so; one saved with it off loads with Layer Trace Tags off.

At least one output must be on, or the run refuses: "Turn on at least one output (group tags or darktable groups).". Each output is only changed when it's on: a run with darktable groups off leaves the plugin's earlier darktable groups as they are, and a run with tags off leaves its earlier tags.

A notice line below the pages says what would stop or undermine the next run, in this priority: "Turn on at least one output (group tags or darktable groups).", then "The burst gap must be auto or a number of seconds above 0, e.g. 2 or 0.5.", then "The minimum burst size must be a whole number of frames, 2 or more.", then "The session gap must be a number of minutes, e.g. 30, or 0 for off.", then "Turn on Group Tags, or this run's groups aren't saved for the next run to start from." (*last run's groups* without Group Tags), then "One group needs a divide layer: turn on Camera and Lens, or type a Tag or Parent Tag." (*one group* with no layer), then "Turn on Group Tags, or no Session tags are written." (a session gap above 0 without Group Tags; the run still goes ahead, without Session tags). It is hidden when nothing is wrong. It updates from the **Start From** dropdown, the four checkboxes (Camera and Lens, Apply darktable Groups, Group Tags, Layer Trace Tags), a preset load, the reset and the **Group Selection** click. Text typed into burst gap, minimum burst size, session gap, Tag or Parent Tag is only checked after one of those.

### 4 Run

The page holds the grouping run and its check, under **Group (Uses Pages 1 to 3)**.

- **Group Selection.** Runs the layers on the selected images and writes the outputs that are on. After the `… frames in … groups` line the log lists each group's weakest link, widest first (the ten widest): `group 0003: 12 frames, 1.80 s before DSC00042.JPG` means group 3's largest time gap between neighbouring frames is 1.80 s, just before that file. The frame count is the whole group, including frames with no capture time. A gap close to the burst gap marks a group that may hold two bursts; lower the gap or split it by hand. After that come the cut hints (the first ten, by group): `group 0003 before DSC00042.JPG: focal length 70 to 200 mm` means the lens or exposure setting jumped between that file and the frame before it inside one group. A jump is focal length changing by 1.5× or more, exposure time by 4× (two stops) or more, or focus distance by 2× or more; a setting darktable has no value for is skipped. Hints are log lines only and change no group.
- **Verify Selection.** Checks the selected images against a fresh **Group Selection** run with the current settings, and writes nothing: no tag, no darktable group, no ledger change. The toast says "Verify only, nothing changed. N of M images differ from a fresh Group Selection run, K are in a group with no leader inside it." Each finding goes to [To check](#to-check). Frames a re-run would skip as hand-made (hand-made darktable groups, or frames you moved) count as correct and are left out, tags too.

### 5 Tools

Hand fixes and undo; nothing is run again. The page has three groups: **Browse As**, **Fix by Hand** and **Undo**.

- **Browse As** (darktable groups only; tags are kept), with two buttons. **Bursts** puts the selected images back into darktable groups from each image's newest `Group` tag; with no group tags it says "Nothing to browse. The selection has no group tags; run Group Selection with Group Tags on first.". **Pairs** ungroups the selected images and their groups, then stacks each RAW with its JPEG again; tags stay. See [Re-running and clearing](usage.md#re-running-and-clearing).
- **Merge Groups** (under **Fix by Hand**). Joins the darktable groups of the selected images into one, for a burst the run split: select one image of each group. The merged group counts as made by hand, so **Group Selection** keeps it and **Clear Grouping Marks** leaves it; tags stay. **Pairs** takes it apart again. With images from only one group it says "Nothing to merge".
- **Clear Grouping Marks** (under **Undo**). Removes the plugin's tags and darktable groups from the selected images (see [Re-running and clearing](usage.md#re-running-and-clearing)).

Everything in sections 1 to 3 is saved with the [preset](#presets).

### To Check

A box below the pages lists what a run leaves for you to look at, so a toast that went by unseen isn't lost. It shows only when it has items.

- The box is headed **To Check**. Each item reads `<action>: <what happened>` in full, wrapped over as many lines as it needs, with its buttons below: an error, or a **Clear Grouping Marks** cancelled partway (`clear cancelled: 39 images not reached keep their marks`). The newest run's items sit on top. Older runs' items move below an *Earlier runs (before HH:MM): may not hold any more* line, since a later run can have settled them; they stay until you remove them, so a Fix still works.
- **Verify Selection** adds up to two rows, each with a **Fix** button:
  - `N images differ from a fresh Group Selection run with these settings. Fix runs Group Selection on them.` Its details list each image with its reasons: `darktable group differs`, `no Group tag` or `Group tag differs` (the last two only with Group Tags on). A group of one, or a Group tag with no darktable group behind it, shows up here too.
  - `N images are in a darktable group whose leader is missing or outside it. Fix makes the group's lowest image its leader.` Fix leaves the group's members as they are and only sets its leader.
- **Select** beside a line selects its images in the lighttable. Images removed from the library since are skipped, and a toast counts them.
- The next run of the same action replaces that action's lines; other actions' lines stay. **Clear List**, under the items, empties the box.
- Six lines show; more add `and N more (see the log)`. The list is saved to `assisted_grouping.checks.txt` in darktable's config folder, so it survives a restart.
- A cancel that changed nothing adds no line. The partial-burst warning stays as standing guidance below the box.

## Preferences

In **preferences → lua options**. Everything else is a panel setting saved with its [preset](#presets).

| Preference | Default | What it does |
|---|---|---|
| plugins folder (`assisted_plugins/plugins_root`) | empty | The folder holding the assisted-* repos; this plugin uses `<plugins folder>/darktable-assisted-grouping` (holds `python/` and `.venv`). Empty = auto-detect. The old `assisted_grouping/plugin_folder` (this repo's folder) is still read and logged as deprecated |
