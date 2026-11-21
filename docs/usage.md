# Using it

Part of [darktable-assisted-grouping](../README.md). What a run does, re-running and clearing, the ledger, cancelling.

## Using it

Select the images in lighttable, pick the layers and outputs in the **Assisted Grouping** panel (right side), and click **Group Selection**. A progress bar appears in darktable's job area; its cancel button stops the run (see [Cancel](#cancel)). When it finishes, the message line says how many images ended up in how many groups, whether timing was sub-second or whole-second, and the run's stamp. Instead of the timing it says "timing off" when **Start From** is *one group* or *last run's groups*, or "no timing needed" when *capture time* has nothing left to time; capture times aren't read in either case.

Running all three plugins? [WORKFLOW.md](../WORKFLOW.md) says which order to pick and what to re-run after what.

Select **whole bursts, or the whole shoot**. Bursts are built from the selected frames only, so selecting part of a burst splits it. The panel shows this warning permanently.

### What you get

Each run has a **stamp**: its start time in UTC as `YYYY-MM-DD HH:MM:SS`, so a later run always sorts after an earlier one, across daylight-saving changes and time zones. Older versions of the plugin stamped local time; within your UTC offset of the upgrade, an old run can sort after a new one, and regrouping those images fixes it. Every tag the run writes sits under `Assisted Grouping|<stamp>|`, so groups from different runs never collide. Two runs started in the same second get stamps one second apart.

With **Group Tags** on, every image gets the `Group` tag. With **Layer Trace Tags** also on, it gets the four layer trace tags too:

| Tag | When | Example |
|---|---|---|
| `Assisted Grouping\|<stamp>\|Group\|NNNN` | always | `Assisted Grouping\|2026-11-08 14:03:21\|Group\|0007` |
| `Assisted Grouping\|<stamp>\|Session\|NNNN` | **session gap** above 0, on images with a capture time | `Assisted Grouping\|2026-11-08 14:03:21\|Session\|0002` |
| `Assisted Grouping\|<stamp>\|Burst\|NNNN` (layer trace) | **Start From** is *capture time* and a camera, tag or parent layer is on, or **minimum burst size** is above 2 (written even when that layer splits nothing) | `Assisted Grouping\|2026-11-08 14:03:21\|Burst\|0003` |
| `Assisted Grouping\|<stamp>\|Camera\|<maker model lens>` (layer trace) | Camera and Lens on | `Assisted Grouping\|2026-11-08 14:03:21\|Camera\|SONY ZV-E10 E PZ 16-50mm F3.5-5.6 OSS` |
| `Assisted Grouping\|<stamp>\|Tag\|has <tag>` or `…\|not <tag>` (layer trace) | a tag is typed | `Assisted Grouping\|2026-11-08 14:03:21\|Tag\|has Red` |
| `Assisted Grouping\|<stamp>\|Parent\|<child>` or `…\|none` (layer trace) | a parent tag is typed | `Assisted Grouping\|2026-11-08 14:03:21\|Parent\|42` |

- `Group` is the final group after every layer; it's the one to read. When timing is the only layer, `Burst` would repeat `Group` exactly, so it is not written. A minimum burst size above 2 counts as a layer: `Burst` then keeps the number of each burst it left as single frames. `Burst` is the timing layer's result alone, for a consumer that only wants bursts. With *last run's groups* or *one group* there is no timing layer, so no `Burst` tag is written.
- `Session` sits above the groups: images in capture order, with a new session after every gap longer than the **session gap**. It never splits or joins a group, and an image with no capture time gets none. The frames of one group can carry different `Session` numbers when the session gap is shorter than the gap inside the group (a session gap below the burst gap, or *one group* / *last run's groups* as the start).
- Numbers are four digits, zero-padded, counted from `0001` within a run.
- `Camera` is maker, model and lens joined with spaces; `unknown` when darktable has none of them.
- `Tag` uses the last segment of the tag you typed (`Cars|Red` gives `has Red`).
- `Parent` is the image's single child directly under the node, or `none` when it has none or several.
- `|`, `;`, `,`, `"` and control characters in a camera, lens or tag name are replaced with spaces, so they can't break the tag hierarchy or the ledger.

With **Apply darktable Groups** on, each final group of two or more images becomes one darktable group, led by its lowest image id. To collapse them, turn grouping on in lighttable; how depends on your darktable version (look for the grouping on/off toggle in the lighttable top bar; unverified). A final group of a single image gets no darktable group (a lone RAW+JPEG frame is two images, so it does get one).

### RAW+JPEG pairs and duplicates

A RAW and a JPEG with the same folder and filename stem (extension and case ignored, as darktable pairs them at import: `DSC0001.ARW`, `DSC0001.JPG` and `dsc0001.jpg` are one frame) are one frame, and so are duplicates (versions) of one file. Every member gets the same group and the same tags. This doesn't depend on darktable's own RAW+JPEG grouping at import: the plugin matches folder and stem either way, and a darktable group that holds only one frame's files doesn't count as hand-made.

### Re-running and clearing

**Replace (the default).** A re-run replaces the plugin's own earlier output on the selected images: tags from earlier runs that the ledger lists are detached, the new run's tags attached, and images are taken out of the plugin's old darktable groups before the new ones are built (each image is first moved into a group of its own, so a re-run can't scatter a group). Nothing the ledger doesn't list is touched. A frame you moved by hand from one plugin group into another keeps its place: both groups count as hand-made and the re-run skips them, as it does a group joined with **Merge Groups**. An image you took out of a plugin group to stand alone stays alone, and so does a plugin group you broke up by hand.

**start from: last run's groups.** Instead of burst timing, the starting groups are each image's `Group` tag from the latest earlier run (latest stamp wins when an image has several). Images with no group tag share one starting group, and the burst gap is hidden and unused. Camera, tag and parent layers then divide as usual. The tags are the source of truth here: changes you made to darktable groups by hand are not read. The old tags are then replaced as in a normal run.

**Clear Grouping Marks** removes, from the selected images, the tags and darktable groups the ledger says the plugin made, and drops their ledger rows. It takes along the unselected images of a selected frame (the RAW of a selected JPEG, or the other way round, found in the same film roll), so a pair never ends up half cleared. An image you moved out of a plugin group by hand is left where it is. Your own tags and groups stay. The selected images of one frame (a RAW+JPEG pair or duplicates, same folder and filename stem) that Clear takes out of a plugin group are put back into one darktable group, led by the lowest id, so Clear doesn't break up the pairs darktable grouped at import.

**browse as pairs** takes the selected images, and every image grouped with them, out of their darktable groups, then puts each frame's files (same folder and filename stem) back into one group led by the lowest id, as darktable does at import. Tags stay, including the group tags, so you can switch between burst groups and pairs: **browse as pairs** after culling to browse each kept frame with its JPEG stacked, then click **browse as bursts** to come back. Hand-made groups are reset too, and the ledger forgets the plugin's darktable groups for these images. **browse as bursts** puts the selected images back into darktable groups from each image's newest `Group` tag (images without one stay alone; images in a hand-made group are skipped), with no Python and no capture times read; it needs Group Tags to have been on, and on untagged frames it says "Nothing to browse. The selection has no group tags; run Group Selection with Group Tags on first.". **Group Selection** also brings the bursts back, but runs the whole pipeline.

### The ledger

The plugin records what it made in `assisted_grouping/ledger.csv` in darktable's config directory (`%LOCALAPPDATA%\darktable\assisted_grouping\ledger.csv` on Windows). Rows are `<library>,id,tag,<tag name>` for each tag it attached and `<library>,id,group,<leader id>` for each image it put in a darktable group. `<library>` is a hash of the library file's path (image ids restart in every library, so each library's rows are kept apart; rows from before this column belong to the library in use when they're first read). Anything not in the ledger is yours. A plugin tag you removed by hand drops out of the ledger the next time a run writes tags on that image, and rows for images removed from the library are dropped whenever the ledger is saved. A group whose leader image was removed is then re-pointed to its lowest remaining id (log: `ledger: N groups had a leader no longer in the library`), and a group with one image left is no longer counted as the plugin's. A failed save is tried once more before the on-screen error. Deleting the file makes every existing `Assisted Grouping` tag and group look hand-made: re-runs and Clear then leave them alone. A library opened with `--library` on the command line is not visible to the plugin and counts as the configured one.

### Cancel

- **Before anything is written** (while the helper reads times, or while groups are worked out) a cancel changes nothing: "Cancelled, nothing was changed."
- **While tags are being written** a cancel stops partway and says how many images were updated; run again to finish. The ledger is saved, so the partial tags are still the plugin's.
- **Once darktable groups have started** a cancel is ignored, so no group is left half-built. The log says when that step starts.

If a job is already running, a second click queues the new job; it starts when the current one finishes. A cancel drops every queued job too ("N queued jobs dropped"): it means "stop what I started".

A cancel doesn't wait for the helper. If it is still reading files, it finishes in the background and leaves its temp files in darktable's tmp folder; the next run starts straight away with new ones.
