# Roadmap

Ideas worth doing deliberately later, not bolted onto whatever's being fixed today.

Background for the items below came from desk research in November 2026: unbuilt ideas found in old specs and audits; how Aftershoot, Narrative Select, Lightroom and others group similar shots; models that run under cv2.dnn or onnxruntime; and the patents and papers behind shot grouping (no tool publishes its algorithm). What matters is written out in each item. A second pass on 2026-11-19 added the darktable Lua events, perceptual-hash burst grouping and import-time grouping.

Competitor figures are vendor claims and have not been checked.

## Hand edits survive a re-run

**Built 2026-11-19, awaiting a Windows run (README test step 19).** `plan_native` skips a frame sharing a group with another frame not of its ledger group, the **Merge groups** button, and `repoint_stale_leaders` in `write_ledger`. Also built 2026-11-19: an image taken out by hand to stand alone stays alone, since `plan_native` skips an image that is alone while the ledger holds another image of its group.

Before, a re-run could regroup images the user moved by hand. Asked for:
- images moved to another group by hand keep that group on the next run
- a **merge groups** step joins two groups the run split
- the ledger drops leader ids that no longer exist (stale leader ids)

Competitors that freeze groups or ignore hand edits get the most complaints.

## Split on car change

Grouping doesn't need to stay time-only; it can use different signals from the other plugins.
- **From tagging's result:** a burst that changes car part-way splits at the change. The tagging result is read from the same ledger the other plugins already share.
- **From looks, without tagging:** split where the livery embedding of adjacent car crops jumps, with a hard group-size cap. Reuses the DINOv2 embeddings tagging already computes for the shared detections. Fixes coarse groups carrying one identity across two cars.
- **Tracks inside a burst:** link each car's boxes frame to frame (box overlap plus embedding) and write a track id. Culling can then keep one frame per track, and tagging can fuse number reads per track. Published sports identification pipelines (bib and jersey-number readers, race-car re-identification) all work per track: they detect, track, then vote across the track's frames, because one frame's read is often wrong.

## Group size

- **Minimum burst size (built 2026-11-18, awaiting a Windows run):** `min_burst_size`, default 2 (as before)
- **Large-group warning**: a group over N frames is flagged, because one oversized group hides several cars
- **Similarity slider**: one setting from "split more" to "join more"
- **Partial-burst check**: the done message reports bursts that look cut short (a gap mid-sequence), instead of the current fixed warning. Part built 2026-11-18: the log lists the 10 widest time gaps inside groups (`weakest links`); no crop distance yet

## Better timing

Today bursts split at a fixed gap (`BURST_GAP_SECONDS` = 2 in `lua/assisted_grouping.lua`, changeable in preferences).
- **Adaptive gap (built, untested on real shoots).** Type `auto` as the burst gap. `M.auto_gap` takes the log10 of the gaps between capture times (per camera when camera split is on), builds a 0.1-decade histogram, smooths it, and cuts at the lowest point between the two biggest peaks. Result clamped to 0.3–10 s; at least 1 s when times are whole seconds. Falls back to 2 s with fewer than 30 gaps or one peak; the log says which. Left to check: on a Rallye folder, does `auto` match the best hand-picked gap?
- **Time cuts, then a visual check.** Cut by time first, then compare the frames on each side of a cut (and inside long groups) and join or split on how alike they look (Kodak patent US6351556; Gozali et al. 2012). Shares the embedding work with "Split on car change". Effort M.
- **More cameras' sub-second times**: read sub-second timestamps from more makers' metadata
- **Visual-neighbour fallback**: when times are missing or tied, join frames that look alike
- **UTC run stamps (built, ticket 50)**: run times are written in UTC, so a laptop changing time zone doesn't reorder runs
- **Metadata cut hints (built 2026-11-18, log only)**: `cut hints:` lines where focal length, focus distance or exposure jumps between neighbours (`M.CUT_HINT_RATIO`, thresholds guessed); no group changes

## Sessions above bursts

**Time layer built 2026-11-18, awaiting a Windows run:** `session_gap_minutes` (0 = off) writes `Session|NNNN` tags. Named sessions and per-session culling caps are not built.

A day at a circuit or hillclimb has sessions (practice, runs, races) separated by long gaps.
- a second layer of groups: gaps over N minutes (setting, or the adaptive-gap valley at a
  larger scale) start a new session, tagged `Session|1`, `Session|2`…
- with tagging's run-time import, sessions get real names (`Practice`, `Run 2`)
- lets culling cap keepers per car per session, not per day
Effort S for the time layer.

## Two camera bodies

A shooter with two bodies (long lens + wide) gets two sets of bursts of the same car, offset by
however far the two clocks have drifted. Today grouping can keep cameras apart (`camera` option).
Next:
- a **per-camera clock offset** (shared with tagging's "Camera clock offset" idea), so a
  car's bursts from both bodies line up in time
- an optional **cross-camera group**: bursts from different bodies within a few seconds of each
  other that tagging read as the same entry join one group, so culling picks one keeper across
  both bodies or one per body (setting)
- estimating the offset automatically: once tagging has numbers, the median time difference
  between the same entry's bursts on each body gives the offset

## Calibrate similarity thresholds

Any embedding cut-off (split on car change, visual check, similarity slider) needs a number taken from real photos. SSCD's 0.75 is meant for edited copies of the same image, and DINOv2 has no standard cut-off. Label ~100 frame pairs from a real shoot (same car / different car), pick the threshold from them, and share the set with tagging, which needs the same calibration.

## RAW + JPEG pairs

**Built 2026-11-19, awaiting a Windows run (README test step 20).** Clear reads the selection's film rolls and takes along the unselected images of a selected frame that the ledger lists (`M.plan_partners`).

Clear marks on the unselected partner of a RAW/JPEG pair, so the pair doesn't show two different states.

## Notice hand edits when they happen

darktable fires `image-group-information-changed` on every grouping change, with a reason
(`add`, `remove`, `leader-change`, `remove-leader`), the image and its leader (Lua API manual,
events). A callback could note a hand change in the ledger at the moment it happens, instead of
`plan_native` inferring it on the next run. That would also close the "group mates removed from the
library" limitation, which today counts as hand-made for one run.
- the plugin's own `group_with` calls fire the event too: ignore it while a run or Clear is writing
- check first on Windows which UI actions fire which reason (the manual doesn't say)
Effort S–M.

## Group on import

The `post-import-film` event fires when a film roll finishes importing. An opt-in preference runs
grouping on the new roll straight away, so the lighttable opens already stacked. Effort S; the
run itself is unchanged.

## Cheap hash before embeddings

A 64-bit perceptual hash (dHash) per frame costs almost nothing. A burst patent (USPTO 11763369)
joins frames whose hashes differ by 4 bits or fewer; snapsift (Apple Photos tool) uses time gaps
first, then dHash for near-duplicates across time. For grouping:
- a first pass for "Time cuts, then a visual check": hash-identical frames on both sides of a cut
  join without computing embeddings
- the same hash as the "Visual-neighbour fallback" when times are missing or tied
Hashes can't tell two cars in the same spot apart, so they only ever join frames within a
short time window. Effort S on the Python side.

## Export and import presets

**Status (2026-11-19):** layer 1 built, awaiting the Windows run (README acceptance step 21).
**export preset…** and **import preset…** in the actions menu write and read a `<name>.atpreset`
folder (`manifest.json` + `preset.json`); a taken name imports as `<name> (2)`. The rally set and
zip bundles are not built.

Asked for 2026-11-19. Full design in tagging's ROADMAP ("Export and import presets"): an
**Export preset…** dialog with tick boxes per layer, a folder bundle with a `manifest.json`,
import through `M.upgrade_preset_text`. For grouping only layer 1 applies: the preset JSON from
`<config dir>/assisted_grouping/presets/`. The ledger is never exported (image ids are
per-library). The "rally set" bundle (same-named preset from all three panels, per WORKFLOW.md)
is the part grouping users gain most from. Shared code in `plugin_common.lua`, so all three repos
and COMMON_HASH change together. Effort S here once the shared part exists.

## Smaller known gaps

- **Diagnostic tags switch**: turn the diagnostic tags off for a clean tag list
- **Minimum darktable version**: the plugin checks Lua API 7.0.0 at load; the darktable version that maps to has not been confirmed
