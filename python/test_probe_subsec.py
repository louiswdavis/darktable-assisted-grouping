# Run with: python python/test_probe_subsec.py
# Exercises probe_subsec.py on JPEGs written with Pillow into a temp dir.

import os
import struct
import sys
import tempfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_subsec as P

failures = 0

EXIF_IFD = 0x8769
DATE_TIME_ORIGINAL = 0x9003
SUBSEC_TIME_ORIGINAL = 0x9291


def check(name, got, want):
    global failures
    if got != want:
        failures += 1
        print(f"FAIL {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {name}")


def write_jpeg(path, exif_fields=None):
    img = Image.new("RGB", (8, 8), (40, 80, 120))
    if exif_fields is None:
        img.save(path, "JPEG")
        return
    exif = Image.Exif()
    ifd = exif.get_ifd(EXIF_IFD)
    for tag, value in exif_fields.items():
        ifd[tag] = value
    img.save(path, "JPEG", exif=exif)


def write_tiff_exif(path, dto=b"2026:11:07 14:11:44\x00", sub=b"897\x00"):
    """Write a minimal little-endian TIFF holding only an EXIF IFD, standing in for a RAW file.

    It has no image tags, so Pillow cannot identify it, but exifread parses its EXIF.
    `sub` is stored inline, so it must be at most 4 bytes including the NUL.
    """
    exif_off = 8 + 2 + 12 + 4
    data_off = exif_off + 2 + 24 + 4
    out = b"II*\x00" + struct.pack("<I", 8)
    out += struct.pack("<H", 1) + struct.pack("<HHII", EXIF_IFD, 4, 1, exif_off) + struct.pack("<I", 0)
    out += struct.pack("<H", 2)
    out += struct.pack("<HHII", DATE_TIME_ORIGINAL, 2, len(dto), data_off)
    out += struct.pack("<HHI", SUBSEC_TIME_ORIGINAL, 2, len(sub)) + sub.ljust(4, b"\x00")
    out += struct.pack("<I", 0)
    with open(path, "wb") as f:
        f.write(out + dto)


def pillow_rejects(path):
    try:
        with Image.open(path):
            return False
    except Exception:
        return True


def run_tests():
    with tempfile.TemporaryDirectory() as tmp:
        with_subsec = os.path.join(tmp, "subsec.jpg")
        write_jpeg(with_subsec, {DATE_TIME_ORIGINAL: "2026:06:14 10:21:33", SUBSEC_TIME_ORIGINAL: "47"})
        got = P.read_subsec_fields(with_subsec)
        check("subsec JPEG: SubSecTimeOriginal", got["SubSecTimeOriginal"], "47")
        check("subsec JPEG: DateTimeOriginal", got["DateTimeOriginal"], "2026:06:14 10:21:33")
        check("subsec JPEG: SubSecDateTimeOriginal", got["SubSecDateTimeOriginal"], "2026:06:14 10:21:33.47")

        no_exif = os.path.join(tmp, "plain.jpg")
        write_jpeg(no_exif)
        check("no EXIF: all None", P.read_subsec_fields(no_exif),
              {"DateTimeOriginal": None, "SubSecTimeOriginal": None, "SubSecDateTimeOriginal": None})

        not_image = os.path.join(tmp, "broken.arw")
        with open(not_image, "wb") as f:
            f.write(b"not an image")
        check("unreadable file: all None, no raise", P.read_subsec_fields(not_image),
              {"DateTimeOriginal": None, "SubSecTimeOriginal": None, "SubSecDateTimeOriginal": None})

        blank = {"DateTimeOriginal": None, "SubSecTimeOriginal": None, "SubSecDateTimeOriginal": None}

        raw = os.path.join(tmp, "raw.arw")
        write_tiff_exif(raw)
        check("synthetic ARW: Pillow cannot open it", pillow_rejects(raw), True)
        check("synthetic ARW: exifread fallback reads it", P.read_subsec_fields(raw),
              {"DateTimeOriginal": "2026:11:07 14:11:44", "SubSecTimeOriginal": "897",
               "SubSecDateTimeOriginal": "2026:11:07 14:11:44.897"})

        padded = os.path.join(tmp, "padded.arw")
        write_tiff_exif(padded, sub=b"89 \x00")
        check("synthetic ARW: SubSec padding stripped", P.read_subsec_fields(padded)["SubSecTimeOriginal"], "89")

        no_sub = os.path.join(tmp, "nosub.arw")
        write_tiff_exif(no_sub, sub=b"\x00")
        check("synthetic ARW: empty SubSec -> None, no combination", P.read_subsec_fields(no_sub),
              {"DateTimeOriginal": "2026:11:07 14:11:44", "SubSecTimeOriginal": None,
               "SubSecDateTimeOriginal": None})

        # None in sys.modules makes `import exifread` raise ImportError, as on a Pillow-only install.
        saved = sys.modules.get("exifread")
        sys.modules["exifread"] = None
        try:
            check("exifread not installed: blanks, no raise", P.read_subsec_fields(raw), blank)
        finally:
            if saved is None:
                del sys.modules["exifread"]
            else:
                sys.modules["exifread"] = saved

        real_pillow = P._read_pillow
        P._read_pillow = lambda path: ("2026:11:07 14:11:44", None)
        try:
            check("Pillow has date but no SubSec: exifread fills SubSec", P.read_subsec_fields(raw),
                  {"DateTimeOriginal": "2026:11:07 14:11:44", "SubSecTimeOriginal": "897",
                   "SubSecDateTimeOriginal": "2026:11:07 14:11:44.897"})
            check("Pillow has date, exifread finds nothing: Pillow's date kept",
                  P.read_subsec_fields(not_image),
                  {"DateTimeOriginal": "2026:11:07 14:11:44", "SubSecTimeOriginal": None,
                   "SubSecDateTimeOriginal": None})
        finally:
            P._read_pillow = real_pillow

        import exifread
        real_process = exifread.process_file

        def boom(*args, **kwargs):
            raise RuntimeError("corrupt RAW")

        exifread.process_file = boom
        try:
            check("exifread raises: blanks, no raise", P.read_subsec_fields(raw), blank)
        finally:
            exifread.process_file = real_process

        check("format_line: blanks where absent",
              P.format_line("a.jpg", {"DateTimeOriginal": "2026:06:14 10:21:33", "SubSecTimeOriginal": None,
                                      "SubSecDateTimeOriginal": None}),
              "a.jpg | 2026:06:14 10:21:33 |  | ")

    if failures == 0:
        print("all tests passed")
        sys.exit(0)
    print(f"{failures} test(s) failed")
    sys.exit(1)


if __name__ == "__main__":
    run_tests()
