# Testing and development

Part of [darktable-assisted-grouping](../README.md). The Windows acceptance checklist, the tests and the helper.

## Acceptance checklist

The darktable side has never run: it was written without darktable to test against. Work through these steps on Windows, in order, and note the result of each. Use a test collection, or a copy of your library, for the first pass.

**Setup**

1. **Install Python.** In the repo folder: `python -m venv .venv`, then `.venv\Scripts\pip install -r python\requirements.txt`. *Expect:* Pillow and exifread install with no errors.
2. **Install the plugin** as in [Install](../README.md#2-darktable-side), linking **both** Lua files, and start darktable. *Expect:* an **Assisted Grouping** panel on the right in lighttable, with the page buttons *1 start groups ▾* (open, its settings below it) to *5 tools ▸*; opening *4 run* shows the **Group Selection** button, and the partial-burst warning sits below the pages. No `LUA ERROR` in the darktable log.
3. **Set the plugins folder** in **preferences → lua options → plugins folder (holds the three assisted-* folders)** to the folder holding the repo. *Expect:* the preference is saved; the panel's burst gap shows `2` on `template`.

**First run (tags only)**

4. **Select 30-60 frames with both RAW and JPEG of each frame**, including a fast burst, a night shot and frames from two different lenses. In the panel: **Start From** *capture time*, Group Tags ticked, Apply darktable Groups unticked (the defaults are Apply on, Group Tags off; tick Group Tags for this check, since steps 5 and 6 read the tags). Click **Group Selection**. *Expect:* a progress bar, then "Assisted Grouping: Done. N images in M groups (sub-second timing). Run YYYY-MM-DD HH:MM:SS."
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

14. **Clear.** With the same selection, click **Clear Grouping Marks**. *Expect:* "Cleared grouping marks from N images"; the plugin's tags and darktable groups are gone; your own tag and the hand-made group are still there; the cleared images' rows are gone from `ledger.csv`; each RAW+JPEG pair is still one darktable group (two images per stack with grouping on), and the log's `clear:` line counts the `frame groups restored`.
15. **Cancel before applying.** Select all 30-60 frames, run, and cancel from the progress bar straight away. *Expect:* "Cancelled, nothing was changed." and no new tags or groups. (If the run finished before you could cancel, note that instead.) Click **Group Selection** again straight after. *Expect:* it starts at once (no "still stopping" message) and finishes normally.
16. **Both outputs off.** Untick both outputs and click **Group Selection**. *Expect:* the run refuses with "Turn on at least one output (group tags or darktable groups)." and nothing changes.
17. **Browse as pairs and back.** Tick both outputs, run **Group Selection** on RAW+JPEG frames, then select one collapsed burst and click **browse as pairs**. *Expect:* "reset N images to M RAW+JPEG pairs. Tags kept."; every frame of that burst is its own stack of two; the group tags are still on them; the log's `pairs:` line matches. Click **Bursts** on the same frames. *Expect:* "Browsing N images as M bursts from their group tags.", the burst is one darktable group again, and the log has no helper (Python) line. Click **Group Selection** on the same frames too: the burst is one darktable group again.
18. **Old preset upgrade.** Load a preset saved before Layer Trace Tags existed, with `"write_tags": true` and no `trace_tags`. *Expect:* both **Group Tags** and **Layer Trace Tags** are ticked and the log says "preset upgraded: trace_tags set from write_tags". A preset with `"write_tags": false` loads with Layer Trace Tags unticked.
19. **Hand edits survive a re-run.** Run **Group Selection** on two neighbouring bursts. Move one frame (both its files) from burst A into burst B by hand. Select one image of each of two other bursts and click **Merge Groups**. Take one frame of a fourth burst out of its group to stand alone. Run **Group Selection** on all of them again. *Expect:* the moved frame is still in burst B, burst B is unchanged, the merged group is still one group, the frame you took out is still alone, and the log's `native groups:` line counts them as skipped. **Clear Grouping Marks** then leaves the merged group alone.
20. **Clear takes the RAW along.** Tick **Group Tags**, run **Group Selection** on RAW+JPEG frames, then select only their JPEGs and click **Clear Grouping Marks**. *Expect:* "Cleared grouping marks from N images, M of them unselected RAW/JPEG partners"; the RAWs lose their group tag too, each RAW+JPEG pair is still one darktable group, and the log has `clear: M unselected RAW/JPEG partners of the selection included`.
21. **Export and import a preset.** Store a preset named `Rally`, then pick **export preset…** in the actions menu, click **Export** (no folder to pick). *Expect:* `Preset "Rally" exported to <plugin folder>\exports\Rally.atpreset.zip`; that zip holds `manifest.json` and `preset.json`. Export again with nothing changed. *Expect:* `already exported and unchanged`; no `Rally (2).atpreset.zip` appears. Change a setting, pick **update preset** in the actions menu, export again. *Expect:* `exported to …\Rally.atpreset.zip (replaced the earlier export)`; its `preset.json` holds the new value. Pick **import preset…**, choose the `Rally.atpreset.zip` file, click **Import**. *Expect:* `imported "Rally (2)" … ("Rally" was taken); pick it in the preset list`; picking `Rally (2)` shows the same settings as `Rally`. Import the same bundle in Assisted Culling. *Expect:* refused, "the bundle is for assisted_grouping, not this plugin".
22. **Verify Selection.** Run **Group Selection** with both outputs on over two bursts, then move one frame into the other burst by hand, and remove one image's `Group` tag in the tagging module. Select the bursts and click **Verify Selection**. *Expect:* "Verify only, nothing changed. 1 of N images differ…" (the untagged one; the moved frame counts as hand-made); no tag or group changed; a To check row whose details say `<file>: no Group tag`. Click its **Fix**. *Expect:* Group Selection runs on that image, and a second Verify adds no row.
23. **Verify, missing leader.** In darktable, remove the leader image of one burst group from the library (or group one frame with an image outside the selection, then remove that image). Verify the burst. *Expect:* a row `… whose leader is missing or outside it`; its **Fix** makes the lowest image the leader, and a second Verify adds no row.

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
