#!/usr/bin/env python3
"""The quick start in README.md and in the plugin's README (pub.dev) is, line for line, the marked region of
packages/quranlab_tajweedformer/example/lib/quick_start.dart, which CI compiles. Exit 1 when one differs."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "packages/quranlab_tajweedformer/example/lib/quick_start.dart"
READMES = [ROOT / "README.md", ROOT / "packages/quranlab_tajweedformer/README.md"]


def region(text):
    lines = text.replace("\r\n", "\n").split("\n")
    b = [i for i, ln in enumerate(lines) if "README:begin" in ln]
    e = [i for i, ln in enumerate(lines) if "README:end" in ln]
    if len(b) != 1 or len(e) != 1 or e[0] <= b[0]:
        return None
    return "\n".join(lines[b[0] + 1:e[0]]) + "\n"


def quick_start_block(text):
    m = re.search(r"(?ms)^## Quick start[ \t]*\n(.*?)(?=^## |\Z)", text.replace("\r\n", "\n"))
    if not m:
        return None
    c = re.search(r"(?ms)^```dart[ \t]*\n(.*?)^```[ \t]*$", m.group(1))
    return c.group(1) if c else None


def main():
    want = region(SOURCE.read_text(encoding="utf-8"))
    bad = 0
    if want is None:
        print(f"{SOURCE}: no single README:begin / README:end pair")
        return 1
    for r in READMES:
        got = quick_start_block(r.read_text(encoding="utf-8"))
        if got != want:
            print(f"{r.relative_to(ROOT)}: the quick start is not the marked region of {SOURCE.relative_to(ROOT)}")
            bad += 1
        text = r.read_text(encoding="utf-8")
        for ch in (chr(0x2014), chr(0x2013)):
            if ch in text:
                print(f"{r.relative_to(ROOT)}: an em or en dash")
                bad += 1
    print("readmes ok" if not bad else f"{bad} problem(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
