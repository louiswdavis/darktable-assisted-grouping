# Run with: python python/probe_subsec.py FILE...
# One-off probe: prints each file's capture time and sub-second EXIF fields, to check whether the
# camera writes sub-second precision. Output per file:
#   path | DateTimeOriginal | SubSecTimeOriginal | SubSecDateTimeOriginal
# Fields the file lacks print blank.

import sys

from PIL import Image

EXIF_IFD = 0x8769
DATE_TIME_ORIGINAL = 0x9003
SUBSEC_TIME_ORIGINAL = 0x9291

FIELDS = ("DateTimeOriginal", "SubSecTimeOriginal", "SubSecDateTimeOriginal")


def _text(value):
    if value is None:
        return None
    if isinstance(value, bytes):
        value = value.decode("ascii", errors="replace")
    value = str(value).strip("\x00 ")
    return value or None


def read_subsec_fields(path: str) -> dict:
    """Return DateTimeOriginal, SubSecTimeOriginal and their combination, each str or None.

    A file Pillow cannot open or read EXIF from returns all None instead of raising.
    """
    result = dict.fromkeys(FIELDS)
    try:
        with Image.open(path) as img:
            ifd = img.getexif().get_ifd(EXIF_IFD)
    except Exception:
        return result
    dto = _text(ifd.get(DATE_TIME_ORIGINAL))
    sub = _text(ifd.get(SUBSEC_TIME_ORIGINAL))
    result["DateTimeOriginal"] = dto
    result["SubSecTimeOriginal"] = sub
    if dto and sub:
        result["SubSecDateTimeOriginal"] = f"{dto}.{sub}"
    return result


def format_line(path: str, fields: dict) -> str:
    return " | ".join([path] + [fields[k] or "" for k in FIELDS])


def main(paths: list) -> int:
    if not paths:
        print("usage: python python/probe_subsec.py FILE...")
        return 2
    print(" | ".join(("path",) + FIELDS))
    for path in paths:
        print(format_line(path, read_subsec_fields(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
