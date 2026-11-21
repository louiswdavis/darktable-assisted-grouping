# How it works

Part of [darktable-assisted-grouping](../README.md). Timing precision and how bursts and groups are decided.

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

If a RAW format other than ZV-E10 ARW comes back whole-second, **keep the JPEGs selected when sub-second timing matters**, and check what the helper reads with `.venv\Scripts\python python\probe_subsec.py <file>` (macOS/Linux: `.venv/bin/python python/probe_subsec.py <file>`; see [Running the helper on its own](testing.md#running-the-helper-on-its-own)).

Capture times use a constant offset with no daylight saving (`isdst = false`), so a DST change can't split a burst.
