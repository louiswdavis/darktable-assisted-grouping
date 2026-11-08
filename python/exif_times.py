# Run with: python python/exif_times.py MANIFEST RESULTS
"""Read capture times with sub-second precision, which darktable's Lua does not expose.

MANIFEST is a CSV of `id,path` rows. RESULTS gets one `id,epoch` row per manifest row (epoch blank
when the file has no readable DateTimeOriginal or is missing), then a final `#precision,subsecond`
or `#precision,whole` line. It is `whole` when any readable file lacked a sub-second value.

Epochs use the core's constant-offset convention: the naive EXIF time is read as UTC, no DST.

JPEG sub-seconds are tested. ARW support is unverified until the Windows probe of a real ARW is in:
it uses whatever probe_subsec.read_subsec_fields returns and falls back to whole seconds.
"""

import calendar
import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_subsec import read_subsec_fields


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
    with open(results, "w", newline="", encoding="utf-8") as f:
        out = csv.writer(f)
        for image_id, path in rows:
            epoch, has_subsec = _parse(path)
            if epoch is not None and not has_subsec:
                all_subsec = False
            out.writerow([image_id, _format(epoch)])
        out.writerow(["#precision", "subsecond" if all_subsec else "whole"])
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: exif_times.py MANIFEST RESULTS", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
