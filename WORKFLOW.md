# Workflow: grouping, tagging, culling

## One workflow, any order

The three plugins hand off through tags and groups. Each runs alone, and a later re-run only improves the result.

## Recommended orders

- **Default:** group, tag, cull. Groups first, tag everything, cull per car.
- **Keepers tonight, tags later:** group, cull, then tag the keepers (filter `Assisted Culling|Keeper`); tag everything when there is time.
- **Start list in hand, groups uncertain:** tag, group with **Parent tag** = the tagging prefix, cull, then tag again to fill gaps.

Culling before grouping gives a batch-wide star ranking and no keepers. The done message says so: `no groups found: every frame judged alone (group first for keepers)`.

## What to re-run after what

| You re-ran | Then re-run | Why |
|---|---|---|
| Grouping | Tagging (if it used groups), Culling | both pick within groups |
| Tagging | Culling (if a **tag node** box holds the tagging prefix) | keepers per car |
| Culling | nothing: nobody reads culling's output | none |

Caches keep detections, OCR, embeddings and sharpness per frame, so a re-run is a decision-only pass: minutes, not the first-run hour.

## Rally setup: groups travel as tags

**browse as pairs** in grouping and darktable's own grouping toggle both break native groups. Tags survive both, and **browse as bursts** restores the groups from the tags without Python. Three settings:

- Grouping: **Group tags** on; save as your rally preset in the grouping panel.
- Tagging: **grouping support** = grouping tags, **grouping tag node** blank (each photo's latest run).
- Culling: **Cull by native groups** off; **tag node 1** = `Assisted Grouping` (each photo's latest run); **tag node 2** = the tagging prefix; save as your rally preset in the culling panel. The prefix node splits per car for number-only entries and per team for `team|name` entries (see the culling README).

Darktable groups stay the template default for other shoot types.

## Where each plugin writes

| Plugin | Writes | Reads from the others |
|---|---|---|
| Grouping | darktable groups; `Assisted Grouping\|<stamp>\|Group\|NNNN` (+ Burst, Camera, Tag, Parent with **Layer trace tags**) when **Group tags** is on | any tag, via its **Tag** and **Parent tag** layers (e.g. tagging's `Rally\|2026` as the parent node) |
| Tagging | `<prefix>\|<number>` entry tags, `Assisted Tagging\|Colour\|<name>`, `Assisted Tagging\|Identification\|…` diagnostics | groups: native darktable groups (default) or `Assisted Grouping\|<stamp>\|Group` tags, for burst consensus |
| Culling | stars; `Assisted Culling\|Keeper`, `Rejected`, flags, `Why\|…` | groups: native darktable groups or **tag node** boxes (e.g. `Assisted Grouping`); car identity from a tag node holding the tagging prefix |
