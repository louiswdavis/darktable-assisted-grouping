# Run with: python python/run_tests.py [name ...]
# Runs every python/test_*.py (or just the named ones, e.g. match overlap) with this interpreter and
# writes each one's output to tests/<name>.txt in the repo root, then prints a one-line summary each.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "tests")


def main(names: list) -> int:
    tests = sorted(f for f in os.listdir(HERE) if f.startswith("test_") and f.endswith(".py"))
    if names:
        wanted = {n.removeprefix("test_").removesuffix(".py") for n in names}
        tests = [t for t in tests if t.removeprefix("test_").removesuffix(".py") in wanted]
    os.makedirs(OUT, exist_ok=True)
    bad = 0
    for t in tests:
        run = subprocess.run([sys.executable, os.path.join(HERE, t)], capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        text = run.stdout + (("\n--- stderr ---\n" + run.stderr) if run.stderr else "")
        out = os.path.join(OUT, t[:-3] + ".txt")
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        fails = sum(1 for line in run.stdout.splitlines() if line.startswith("FAIL"))
        passed = sum(1 for line in run.stdout.splitlines() if line.startswith("ok"))
        failed = run.returncode != 0 or fails
        bad += bool(failed)
        print(f"{'FAIL' if failed else 'ok  '} {t}: {passed} ok, {fails} FAIL, exit {run.returncode} -> {out}")
    print(f"{len(tests) - bad}/{len(tests)} test files passed")
    return 1 if bad or not tests else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
