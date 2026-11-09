# Run with: python python/probe_subsec.py FILE...
# One-off probe: prints each file's capture time and sub-second EXIF fields, to check whether the
# camera writes sub-second precision. Output per file:
#   path | DateTimeOriginal | SubSecTimeOriginal | SubSecDateTimeOriginal
# Fields the file lacks print blank. Reads with Pillow, then exifread for RAW files Pillow cannot open.

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


def _read_pillow(path: str):
    """Return raw (DateTimeOriginal, SubSecTimeOriginal) via Pillow, or (None, None)."""
    try:
        with Image.open(path) as img:
            ifd = img.getexif().get_ifd(EXIF_IFD)
    except Exception:
        return None, None
    return ifd.get(DATE_TIME_ORIGINAL), ifd.get(SUBSEC_TIME_ORIGINAL)


def _read_exifread(path: str):
    """Return raw (DateTimeOriginal, SubSecTimeOriginal) via exifread, or (None, None).

    Covers RAW files Pillow cannot open, such as Sony ARW. Missing exifread is not an error.
    """
    try:
        import exifread
    except ImportError:
        return None, None
    try:
        with open(path, "rb") as f:
            tags = exifread.process_file(f, details=False)
    except Exception:
        return None, None
    dto = tags.get("EXIF DateTimeOriginal")
    sub = tags.get("EXIF SubSecTimeOriginal")
    return (str(dto.values) if dto is not None else None,
            str(sub.values) if sub is not None else None)


def read_subsec_fields(path: str) -> dict:
    """Return DateTimeOriginal, SubSecTimeOriginal and their combination, each str or None.

    Tries Pillow first, then exifread for whichever field Pillow left missing (RAW files); a
    value Pillow found is kept. A file neither can read returns all None instead of raising.
    """
    result = dict.fromkeys(FIELDS)
    dto_raw, sub_raw = _read_pillow(path)
    dto = _text(dto_raw)
    sub = _text(sub_raw)
    if dto is None or sub is None:
        ex_dto, ex_sub = _read_exifread(path)
        dto = dto or _text(ex_dto)
        sub = sub or _text(ex_sub)
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
