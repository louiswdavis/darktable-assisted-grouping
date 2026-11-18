# Run with: python python/exif_times.py MANIFEST RESULTS
"""Read capture times with sub-second precision, which darktable's Lua does not expose.

MANIFEST is a CSV of `id,path` rows, or `id,path,camera` rows when the plugin splits by camera.
RESULTS gets one `id,epoch` row per manifest row (epoch blank when the file has no readable
DateTimeOriginal or is missing). With cameras, one `#precision,<value>,<camera>` row per camera
follows, sorted by camera. A final `#precision,subsecond` or `#precision,whole` line ends the file.
A precision is `whole` when any readable file it covers lacked a sub-second value.

Epochs use the core's constant-offset convention: the naive EXIF time is read as UTC, no DST.

Times come from probe_subsec.read_subsec_fields: Pillow for JPEGs, exifread for RAW files such as
ARW (confirmed on one Sony ZV-E10 file). A file with no sub-second value falls back to whole seconds.
"""

import calendar
import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_subsec import log, read_subsec_fields


def _parse(path: str):
    """Return (epoch, has_subsec), or (None, False) when there is no usable DateTimeOriginal."""
    fields = read_subsec_fields(path)
    dto = fields["DateTimeOriginal"]
    if not dto:
        return None, False
    try:
        whole = calendar.timegm(time.strptime(dto, "%Y:%m:%d %H:%M:%S"))
    except ValueError:
        return None, False
    sub = (fields["SubSecTimeOriginal"] or "").strip()
    if not sub.isdigit():
        return whole, False
    # A decimal fraction's digits: "47" is .47, "047" is .047.
    return whole + int(sub) / 10 ** len(sub), True


def read_capture_epoch(path: str):
    """Seconds since epoch with the sub-second fraction, or None when there is no DateTimeOriginal.

    Returns an int when the file has no sub-second field.
    """
    return _parse(path)[0]


def _format(epoch) -> str:
    if epoch is None:
        return ""
    return str(epoch) if isinstance(epoch, int) else repr(epoch)


def main(manifest: str, results: str) -> int:
    with open(manifest, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.reader(f) if r]
    all_subsec = True
    started, no_time = time.time(), 0
    log(f"capture times: started, {len(rows)} files")
    subsec_of = {}  # camera -> every readable file of it had a sub-second value
    with open(results, "w", newline="", encoding="utf-8") as f:
        out = csv.writer(f)
        for row in rows:
            image_id, path = row[0], row[1]
            epoch, has_subsec = _parse(path)
            if len(row) > 2:
                subsec_of[row[2]] = subsec_of.get(row[2], True) and (epoch is None or has_subsec)
            if epoch is None:
                no_time += 1
            elif not has_subsec:
                all_subsec = False
            out.writerow([image_id, _format(epoch)])
        for camera in sorted(subsec_of):
            out.writerow(["#precision", "subsecond" if subsec_of[camera] else "whole", camera])
        out.writerow(["#precision", "subsecond" if all_subsec else "whole"])
    log(f"capture times: done, {len(rows)} files, {no_time} without a readable capture time, {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: exif_times.py MANIFEST RESULTS", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
