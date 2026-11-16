# Roadmap

Ideas worth doing deliberately later, not bolted onto whatever's being fixed today.

Sources: the shared backlog (`../docs/superpowers/specs/backlog/darktable-plugins-tickets/`, numbered tickets) and three research notes from 2026-11-15 in `../docs/superpowers/research/`:
- `2026-11-15-unbuilt-ideas-harvest.md`: ideas found in old specs, audits and plans that the code doesn't have yet
- `2026-11-15-competitors-and-ux.md`: how Aftershoot, Narrative Select, Lightroom and others group similar shots
- `2026-11-15-model-candidates.md`: models that would run under cv2.dnn or onnxruntime
- `2026-11-15-how-culling-tools-work.md`: how those tools group shots (patents and papers; none publishes its algorithm)

Competitor figures in those notes are vendor claims and have not been checked.

## Hand edits survive a re-run

Today a re-run can regroup images the user moved by hand. Instead:
- images moved to another group by hand keep that group on the next run
- a **merge groups** step joins two groups the run split
- the ledger drops leader ids that no longer exist (stale leader ids)

Competitors that freeze groups or ignore hand edits get the most complaints.

## Split on car change

Grouping doesn't need to stay time-only; it can use different signals from the other plugins.
- **From tagging's result:** a burst that changes car part-way splits at the change. The tagging result is read from the same ledger the other plugins already share.
- **From looks, without tagging:** split where the livery embedding of adjacent car crops jumps, with a hard group-size cap. Reuses the DINOv2 embeddings tagging already computes for the shared detections. Fixes coarse groups carrying one identity across two cars.
- **Tracks inside a burst:** link each car's boxes frame to frame (box overlap plus embedding) and write a track id. Culling can then keep one frame per track, and tagging can fuse number reads per track. Every sports pipeline in `../docs/superpowers/research/2026-11-15-identification-techniques.md` works per track.

## Group size

- **Large-group warning**: a group over N frames is flagged, because one oversized group hides several cars
- **Similarity slider**: one setting from "split more" to "join more"
- **Partial-burst check**: the done message reports bursts that look cut short (a gap mid-sequence), instead of the current fixed warning

## Better timing

Today bursts split at a fixed gap (`BURST_GAP_SECONDS` = 2 in `lua/assisted_grouping.lua`, changeable in preferences).
- **Adaptive gap.** Fit a two-part mixture to the log of the time gaps in the collection (in-burst gaps vs between-car gaps) and cut at the valley between them. A hillclimb shot at 10 fps and a slow circuit session then get different cut points without touching the setting. The fixed gap stays as the fallback when the gaps don't form two humps. Effort S.
- **Time cuts, then a visual check.** Cut by time first, then compare the frames on each side of a cut (and inside long groups) and join or split on how alike they look (Kodak patent US6351556; Gozali et al. 2012). Shares the embedding work with "Split on car change". Effort M.
- **More cameras' sub-second times**: read sub-second timestamps from more makers' metadata
- **Visual-neighbour fallback**: when times are missing or tied, join frames that look alike
- **UTC run stamps**: write run times in UTC, so a laptop changing time zone doesn't reorder runs

## Sessions above bursts

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

Clear marks on the unselected partner of a RAW/JPEG pair, so the pair doesn't show two different states.

## Smaller known gaps

- **Diagnostic tags switch**: turn the diagnostic tags off for a clean tag list
- **Minimum darktable version**: check it at load and say which version is needed
- **README is stale**: it says the other plugins "can later read groups"; they already do
