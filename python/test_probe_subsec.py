# Run with: python python/test_probe_subsec.py
# Exercises probe_subsec.py on JPEGs written with Pillow into a temp dir.

import os
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
