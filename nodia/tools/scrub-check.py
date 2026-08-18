#!/usr/bin/env python3
"""Blocks intranet identifiers from reaching this public repository.

Run it before pushing, and after any rewrite of prose or examples:

    python3 tools/scrub-check.py

Why this exists: the leak that prompted it did not happen because nobody
scanned. It happened because the scan *was* a grep command, retyped from memory
each time it was needed, and one term dropped out of the pattern during a
rewrite. After that the check kept running, kept printing nothing, and kept
looking exactly like a check that was working — while no longer covering the
term that leaked. A word list in a file shows up in a diff and can be reviewed;
a word list in someone's shell history degrades in silence and takes the
evidence with it.

Scope comes from git rather than a hand-written skip list, for the same reason.
"What could get published" is precisely "what git will publish": tracked files
plus untracked ones the ignore rules don't already cover. Deriving it that way
means build output, `.git`, and every future generated directory are excluded by
the `.gitignore` that already exists, instead of by a second list here that
would quietly fall behind it.

The word list itself is the one thing this file cannot scan — it is made of the
words it looks for — so the script skips its own path. Anything else added to
`ALLOW` needs a reason next to it: an exemption is how the list starts rotting
again.
"""

import re
import subprocess
import sys
from pathlib import Path

# Company, product, platform and namespace names that identify the intranet this
# code was written on. Every entry is a regex, matched case-insensitively.
#
# Word boundaries are not decoration. Bare `psm` or `tcc` inside a longer
# identifier is almost always somebody else's word, and a gate that cries wolf is
# a gate people learn to skip — which is the failure this file exists to prevent.
# `(\b|_)` where it appears is the same rule minus one hole: `_` counts as a word
# character to `\b`, so `\becom\b` would sail past `ecom_service` while still
# doing its real job of not firing on `ecommerce`.
#
# The exception is the reverse risk, `gaze`, which is also an ordinary English
# noun: it stays anyway, because the cost of a false hit here is a five-second
# glance and the cost of a miss is a public commit.
BANNED = [
    r"bytedance",
    r"tiktok",
    r"\bbyted\b",
    r"\brecas\b",
    r"\bdorado\b",
    r"\bdataleap\b",
    r"\bargos\b",
    r"\btcc\b",
    r"\boec(\b|_)",
    r"\becom(\b|_)",
    r"\bpsm\b",
    r"\bbdee\b",
    r"ttp-us",
    r"eu-ttp",
    r"us-ttp",
    r"i18n_sdk",
    r"recon_mng",
    r"飞书",
    r"\blark\b",
    r"\bgaze\b",
]

# Paths that carry a banned word for a legitimate reason. Keep it empty if you
# can; each line here is a hole in the gate.
ALLOW = {
    # The list above is made of the words themselves.
    "nodia/tools/scrub-check.py",
}

PATTERN = re.compile("|".join(BANNED), re.I)


def tracked_files(root):
    """Everything git would publish: tracked, plus untracked and not ignored."""
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def scan(path):
    """Hits in one file, as (line number, matched word, line). Binaries skipped.

    Read as text and abandoned on the first byte that isn't: an icon or a
    compiled artifact has no prose to leak, and decoding it as latin-1 to be
    thorough would only produce matches nobody can act on.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []
    hits = []
    for number, line in enumerate(text.splitlines(), start=1):
        for m in PATTERN.finditer(line):
            hits.append((number, m.group(0), line.strip()))
    return hits


def main():
    root = Path(subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=Path(__file__).resolve().parent, capture_output=True, text=True, check=True,
    ).stdout.strip())

    findings, scanned = [], 0
    for relative in tracked_files(root):
        if relative in ALLOW:
            continue
        scanned += 1
        for number, word, line in scan(root / relative):
            findings.append((relative, number, word, line))

    if findings:
        print(f"发现 {len(findings)} 处内网标识：\n")
        for relative, number, word, line in findings:
            print(f"  {relative}:{number}  [{word}]")
            print(f"    {line[:120]}")
        print("\n这是公开仓库。示例请改用 example.com / ConfigHub / Metrics / Ledger 这类通用名。")
        return 1

    print(f"扫描 {scanned} 个文件，{len(BANNED)} 条词表，没有内网标识。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
