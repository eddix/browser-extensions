#!/usr/bin/env python3
"""Blocks intranet identifiers from reaching this public repository.

    python3 tools/scrub-check.py            # working tree
    python3 tools/scrub-check.py --history  # working tree + what a push adds

Why this exists: the leak that prompted it did not happen because nobody
scanned. It happened because the scan *was* a grep command, retyped from memory
each time it was needed, and one term dropped out of the pattern during a
rewrite. After that the check kept running, kept printing nothing, and kept
looking exactly like a check that was working — while no longer covering the
term that leaked. A word list in a file shows up in a diff and can be reviewed;
a word list in someone's shell history degrades in silence and takes the
evidence with it.

The second leak was worse, and is why `--history` exists. The scan had moved
into this file by then, but it only ever looked at the working tree — so when
two terms sat in nineteen already-pushed commits while the tip was clean, it
printed "no intranet identifiers" and meant it. A repository publishes its
history, not its tip.

The third was a property of the tool rather than the list: `git grep -E` treats
`\\b` as nothing in particular, because POSIX ERE has no word boundary, so
`\\bLark\\b` matched no line in any commit and said so quietly. Python's `re`
does support `\\b`, which is the only reason the patterns below work — and the
reason the self-test at the bottom exists is that nothing else would have
caught that class of failure.

Scope comes from git rather than a hand-written skip list. "What could get
published" is "what git will publish": tracked files plus untracked ones the
ignore rules don't already cover, plus the commits themselves. Deriving it that
way means build output, `.git`, and every future generated directory are
excluded by the `.gitignore` that already exists, instead of by a second list
here that would quietly fall behind it.

The word list itself is the one thing this file cannot scan — it is made of the
words it looks for — so the script skips its own path. Anything else added to
`ALLOW` needs a reason next to it: an exemption is how the list starts rotting
again.
"""

import re
import subprocess
import sys
from pathlib import Path


def term(word, *, glued=False):
    """A boundary that treats `_` as a separator rather than a word character.

    `\\b` disagrees: `_` is a word character to it, so `\\becom\\b` sails past
    `ecom_service` while doing its real job of not firing on `ecommerce`.
    Spelling the boundary out as "not preceded/followed by a letter or digit"
    keeps the second behaviour and fixes the first.

    `glued=True` drops the trailing boundary, for names that grow suffixes:
    `lark` has to catch `larksuite`, `byted` has to catch `bytedcli`. Both were
    missed by the earlier `\\b` spelling.
    """
    left = r"(?<![A-Za-z0-9])"
    right = "" if glued else r"(?![A-Za-z0-9])"
    return left + word + right


# Company, product, platform and namespace names that identify the intranet this
# code was written on. Every entry is a regex, matched case-insensitively.
#
# Boundaries are not decoration. A bare `psm` or `tcc` inside a longer
# identifier is almost always somebody else's word, and a gate that cries wolf
# is a gate people learn to skip — which is the failure this file exists to
# prevent. The exception is `gaze`, also an ordinary English noun: it stays,
# because the cost of a false hit is a five-second glance and the cost of a miss
# is a public commit.
BANNED = [
    r"bytedance",
    r"tiktok",
    term("byted", glued=True),
    term("recas"),
    term("dorado"),
    term("dataleap"),
    term("argos"),
    term("tcc"),
    term("oec"),
    term("ecom"),
    term("psm"),
    term("bdee"),
    r"ttp-us",
    r"eu-ttp",
    r"us-ttp",
    r"i18n_sdk",
    r"recon_mng",
    r"飞书",
    term("lark", glued=True),
    term("gaze"),
]

# Paths that carry a banned word for a legitimate reason. Keep it empty if you
# can; each line here is a hole in the gate.
ALLOW = {
    # The list above is made of the words themselves.
    "nodia/tools/scrub-check.py",
}

PATTERN = re.compile("|".join(BANNED), re.I)

# Inputs whose verdict is known, checked on every run. A word list can rot in
# two directions and both are silent: a term stops matching what it was added
# for, or it starts matching ordinary English and gets deleted by whoever it
# annoys. Neither shows up as an error anywhere else.
SELF_TEST = [
    ("Wiki/Lark titles", True),
    ("larksuite.com", True),
    ("bytedcli run", True),
    ("ecom_service", True),
    ("oec.arch.demo", True),
    ("the psm is", True),
    ("tcc_config", True),
    ("ecommerce checkout", False),
    ("a gazebo in the park", False),
    ("clark kent", False),
    ("example.com/team/repo", False),
]


def run(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True, text=True, check=True,
    ).stdout


def tracked_files(root):
    """Everything git would publish: tracked, plus untracked and not ignored."""
    out = run(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    return [p for p in out.split("\0") if p]


def scan_text(text):
    """Hits in a blob of text, as (line number, matched word, line)."""
    hits = []
    for number, line in enumerate(text.splitlines(), start=1):
        for m in PATTERN.finditer(line):
            hits.append((number, m.group(0), line.strip()))
    return hits


def scan_file(path):
    """Hits in one file. Returns (hits, was_read).

    Binaries are skipped: an icon has no prose to leak, and decoding it as
    latin-1 to be thorough would only produce matches nobody can act on. The
    second return value keeps the summary honest — counting a file the script
    never managed to read is how a number starts overstating its coverage.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return [], False
    return scan_text(text), True


def push_range(root):
    """What this push would add, as a git range, or None if there's nothing.

    `@{push}` is the branch's own answer to "what has the remote already seen",
    and it stays right after a rebase or a force-push in a way that a hardcoded
    `origin/main` does not.
    """
    for candidate in ("@{push}..HEAD", "@{upstream}..HEAD", "origin/main..HEAD"):
        try:
            out = run(root, "rev-list", "--count", candidate).strip()
        except subprocess.CalledProcessError:
            continue
        return candidate if out and out != "0" else None
    return None


def scan_history(root, rng):
    """Hits in the commits a push would add: messages, identities, added lines.

    Per commit rather than as one combined diff, because the leak this was
    written for was invisible in the combined form — introduced in one commit
    and cleaned up in a later one, it nets to nothing while still being
    published in between. Removed lines are ignored: taking a word out is the
    fix, not a reason to block.
    """
    out = run(
        root, "log", "-p", "--no-color", "--no-merges",
        "--format=%x00%H%x00%an <%ae>%x00%cn <%ce>%x00%B", rng,
    )
    findings, commit, path = [], "?", None
    for line in out.splitlines():
        if line.startswith("\0"):
            parts = line.split("\0")
            commit, path = (parts[1][:9] if len(parts) > 1 else "?"), None
            for field in parts[2:]:
                for _, word, text in scan_text(field):
                    findings.append((f"{commit} (提交元数据)", 0, word, text))
            continue
        if line.startswith("+++ "):
            # ALLOW has to apply here too. It didn't at first, and the gate's
            # own commit was the first thing it blocked: the file that holds the
            # word list necessarily adds those words in its diff.
            path = line[6:] if line.startswith("+++ b/") else None
            continue
        if path in ALLOW:
            continue
        if line.startswith("+"):
            for _, word, text in scan_text(line[1:]):
                findings.append((f"{commit} (新增行)", 0, word, text))
        elif not line.startswith(("-", "diff ", "index ", "@@", "\\")):
            for _, word, text in scan_text(line):
                findings.append((f"{commit} (提交信息)", 0, word, text))
    return findings


def self_test():
    """Fails loudly if the patterns stopped doing what they were added to do."""
    broken = [
        (probe, expected)
        for probe, expected in SELF_TEST
        if bool(PATTERN.search(probe)) != expected
    ]
    if broken:
        print("词表自检失败 —— 闸门本身坏了，先修它再谈扫描结果：")
        for probe, expected in broken:
            print(f"  {probe!r} 应当{'命中' if expected else '不命中'}，实际相反")
        return False
    return True


def report(findings, what):
    print(f"{what}发现 {len(findings)} 处内网标识：\n")
    for where, number, word, line in findings:
        location = f"{where}:{number}" if number else where
        print(f"  {location}  [{word}]")
        print(f"    {line[:120]}")
    print("\n这是公开仓库。示例请改用 example.com / ConfigHub / Metrics / Ledger 这类通用名。")


def main():
    root = Path(run(Path(__file__).resolve().parent, "rev-parse", "--show-toplevel").strip())
    if not self_test():
        return 2

    findings, scanned, skipped = [], 0, 0
    for relative in tracked_files(root):
        if relative in ALLOW:
            continue
        # The name is published too, and a file called after an internal
        # platform gives it away with a perfectly clean interior.
        for _, word, _ in scan_text(relative):
            findings.append((relative, 0, word, "（文件名）"))
        hits, was_read = scan_file(root / relative)
        scanned, skipped = scanned + was_read, skipped + (not was_read)
        for number, word, line in hits:
            findings.append((relative, number, word, line))

    if findings:
        report(findings, "工作区")
        return 1

    rng = push_range(root) if "--history" in sys.argv else None
    if rng:
        history = scan_history(root, rng)
        if history:
            report(history, f"待推送的提交（{rng}）")
            return 1

    where = f"，以及 {rng} 的提交" if rng else ""
    print(f"扫描 {scanned} 个文本文件（跳过 {skipped} 个二进制）{where}，"
          f"{len(BANNED)} 条词表，没有内网标识。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
