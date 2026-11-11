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
| Tagging | Culling (if **car tag node** is set) | keepers per car |
| Culling | nothing: nobody reads culling's output | none |

Caches keep detections, OCR, embeddings and sharpness per frame, so a re-run is a decision-only pass: minutes, not the first-run hour.

## Rally setup: groups travel as tags

**Reset to RAW+JPEG pairs** in grouping and darktable's own grouping toggle both break native groups. Tags survive both. Three settings:

- Grouping preset: **Write group tags** on.
- Tagging collection: **grouping support** = Grouping tags, node blank (newest run).
- Culling preset: **grouping support** = Grouping tags, node blank; **car tag node** = the collection prefix.

Native groups stay the template default for other shoot types.

## Where each plugin writes

| Plugin | Writes | Reads from the others |
|---|---|---|
| Grouping | darktable groups; `Assisted Grouping\|<stamp>\|Group\|NNNN` (+ Burst, Camera, Tag, Parent layers) when **Write group tags** is on | any tag, via its **Tag** and **Parent tag** layers (e.g. tagging's `Rally\|2026` as the parent node) |
| Tagging | `<prefix>\|<number>` entry tags, `Assisted Tagging\|Colour\|<name>`, `Assisted Tagging\|Identification\|…` diagnostics | groups: native darktable groups (default) or `Assisted Grouping\|<stamp>\|Group` tags, for burst consensus |
| Culling | stars; `Assisted Culling\|Keeper`, `Rejected`, flags, `Why\|…` | groups, the same two ways; car identity from the **car tag node** |
