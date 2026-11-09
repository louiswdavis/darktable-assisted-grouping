# Run with: python python/test_exif_times.py
# Exercises exif_times.py on JPEGs written with Pillow into a temp dir.

import calendar
import csv
import os
import subprocess
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import exif_times as E
from test_probe_subsec import write_tiff_exif

failures = 0

EXIF_IFD = 0x8769
DATE_TIME_ORIGINAL = 0x9003
SUBSEC_TIME_ORIGINAL = 0x9291

# 2026:06:01 14:30:00 read as UTC
BASE = 1780324200


def check(name, got, want):
    global failures
    if got != want:
        failures += 1
        print(f"FAIL {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {name}")


def check_close(name, got, want):
    global failures
    if got is None or abs(got - want) > 1e-6:
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


def run_cli(tmp, rows):
    manifest = os.path.join(tmp, "manifest.csv")
    results = os.path.join(tmp, "results.csv")
    with open(manifest, "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(rows)
    run = subprocess.run([sys.executable, os.path.join(HERE, "exif_times.py"), manifest, results],
                         capture_output=True, text=True)
    check(f"CLI exit code ({run.stderr.strip()})", run.returncode, 0)
    with open(results, newline="", encoding="utf-8") as f:
        return list(csv.reader(f))


def run_tests():
    with tempfile.TemporaryDirectory() as tmp:
        sub47 = os.path.join(tmp, "sub47.jpg")
        write_jpeg(sub47, {DATE_TIME_ORIGINAL: "2026:06:01 14:30:00", SUBSEC_TIME_ORIGINAL: "47"})
        check_close("SubSec '47' -> +0.47", E.read_capture_epoch(sub47), BASE + 0.47)

        sub5 = os.path.join(tmp, "sub5.jpg")
        write_jpeg(sub5, {DATE_TIME_ORIGINAL: "2026:06:01 14:30:00", SUBSEC_TIME_ORIGINAL: "5"})
        check_close("SubSec '5' -> +0.5", E.read_capture_epoch(sub5), BASE + 0.5)

        sub047 = os.path.join(tmp, "sub047.jpg")
        write_jpeg(sub047, {DATE_TIME_ORIGINAL: "2026:06:01 14:30:00", SUBSEC_TIME_ORIGINAL: "047"})
        check_close("SubSec '047' -> +0.047", E.read_capture_epoch(sub047), BASE + 0.047)

        whole = os.path.join(tmp, "whole.jpg")
        write_jpeg(whole, {DATE_TIME_ORIGINAL: "2026:06:01 14:30:00"})
        got = E.read_capture_epoch(whole)
        check("no subsec -> whole epoch", got, BASE)
        check("no subsec -> integral value", got is not None and float(got).is_integer(), True)

        sub8a = os.path.join(tmp, "sub8a.jpg")
        write_jpeg(sub8a, {DATE_TIME_ORIGINAL: "2026:06:01 14:30:00", SUBSEC_TIME_ORIGINAL: "8a"})
        check("non-digit SubSec '8a' -> whole epoch", E.read_capture_epoch(sub8a), BASE)
        check("non-digit SubSec '8a' -> CLI whole precision", run_cli(tmp, [["1", sub8a]]),
              [["1", str(BASE)], ["#precision", "whole"]])

        zero_date = os.path.join(tmp, "zero_date.jpg")
        write_jpeg(zero_date, {DATE_TIME_ORIGINAL: "0000:00:00 00:00:00", SUBSEC_TIME_ORIGINAL: "47"})
        check("DateTimeOriginal 0000:00:00 00:00:00 -> None", E.read_capture_epoch(zero_date), None)

        plain = os.path.join(tmp, "plain.jpg")
        write_jpeg(plain)
        check("no EXIF -> None", E.read_capture_epoch(plain), None)

        missing = os.path.join(tmp, "missing.jpg")
        check("missing file -> None", E.read_capture_epoch(missing), None)

        raw = os.path.join(tmp, "raw.arw")
        write_tiff_exif(raw)
        raw_whole = calendar.timegm((2026, 11, 7, 14, 11, 44, 0, 0, 0))
        check_close("synthetic ARW via exifread: SubSec '897' -> +0.897", E.read_capture_epoch(raw),
                    raw_whole + 0.897)

        junk = os.path.join(tmp, "junk.arw")
        with open(junk, "wb") as f:
            f.write(b"II*\x00garbage")
        check("junk ARW -> None", E.read_capture_epoch(junk), None)

        odd_dir = os.path.join(tmp, 'a, "b"')
        os.makedirs(odd_dir)
        odd = os.path.join(odd_dir, "odd.jpg")
        write_jpeg(odd, {DATE_TIME_ORIGINAL: "2026:06:01 14:30:00", SUBSEC_TIME_ORIGINAL: "47"})

        out = run_cli(tmp, [["1", sub47], ["2", whole], ["3", missing], ["4", odd]])
        check("CLI row count", len(out), 5)
        check("CLI subsec row id", out[0][0], "1")
        check_close("CLI subsec row epoch", float(out[0][1]), BASE + 0.47)
        check("CLI whole row", out[1], ["2", str(BASE)])
        check("CLI missing file -> blank epoch", out[2], ["3", ""])
        check("CLI path with comma and quotes", out[3][0], "4")
        check_close("CLI path with comma and quotes epoch", float(out[3][1]), BASE + 0.47)
        check("CLI mixed precision -> whole", out[4], ["#precision", "whole"])

        out = run_cli(tmp, [["1", sub47], ["2", sub5], ["3", missing]])
        check("CLI all subsec (unreadable ignored) -> subsecond", out[-1], ["#precision", "subsecond"])


if __name__ == "__main__":
    run_tests()
    sys.exit(1 if failures else 0)
