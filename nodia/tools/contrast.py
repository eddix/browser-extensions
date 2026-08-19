#!/usr/bin/env python3
"""Relative contrast check for the palettes in Sources/nodia/Palettes.swift.

Run it after adding or editing a palette:

    python3 tools/contrast.py

**These numbers are not predictions of what the screen will do.** The panel is
a piece of macOS 26 glass: the compositor decides its actual color from the
desktop behind it, the refraction, the specular edge and the palette's tint,
and there is no public API to read the result back. Modeling that would be
guessing with extra steps.

So the reference surface here is the palette's own tint color, at full
strength — a stand-in that is fixed, known, and in the right neighbourhood.
What this checks is that a palette holds together *internally*: body text and
secondary text separated enough to read as a hierarchy, secondary still legible
where the selection wash lightens the ground under it, accent and highlight
strong enough to be seen. Those relationships are properties of the palette and
don't move when the desktop does.

Why it exists at all: the palettes are borrowed from editor themes, where the
de-emphasized color is a comment color picked against one solid background.
Here it lands on two — the panel background, and the selection wash painted
over it for the current row — and the wash *lightens*, which is exactly the
direction that kills a dim color. Measured before this check existed, all nine
palettes failed on a selected row; Dracula's `#6272A4` came out at 1.8:1.

A palette that fails here is broken on any desktop. A palette that passes has
only cleared the bar it can be held to, so a real screen still deserves a look
— glass thins the tint the user chooses, which pulls every number down.
"""

import re
import sys
from pathlib import Path

# Body and de-emphasized text both have to clear normal-text contrast. The
# accent and the matched-character highlight are allowed the large-text bar:
# they are always short, always bold, and never the only way to read a row.
BAR_TEXT = 4.5
BAR_DECOR = 3.0
# Below this the secondary stops reading as secondary and the hierarchy is gone
# — which is its own kind of failure, just a quieter one.
BAR_HIERARCHY = 1.35

PALETTE_RE = re.compile(
    r'id:\s*"(?P<id>\w+)",\s*name:\s*"(?P<name>[^"]+)",\s*isDark:\s*(?P<dark>true|false|nil),\s*'
    r'tint:\s*Color\(hex:\s*(?P<tint>0x[0-9A-Fa-f]+)\),\s*'
    r'foreground:\s*Color\(hex:\s*(?P<fg>0x[0-9A-Fa-f]+)\),\s*'
    r'secondary:\s*Color\(hex:\s*(?P<sec>0x[0-9A-Fa-f]+)\),\s*'
    r'accent:\s*Color\(hex:\s*(?P<acc>0x[0-9A-Fa-f]+)\),\s*'
    r'selection:\s*Color\(hex:\s*(?P<sel>0x[0-9A-Fa-f]+)\)\.opacity\((?P<sa>[\d.]+)\),\s*'
    r'highlight:\s*Color\(hex:\s*(?P<hl>0x[0-9A-Fa-f]+)\)',
    re.S,
)


def rgb(value):
    return ((value >> 16) & 255, (value >> 8) & 255, value & 255)


def over(front, back, alpha):
    """Source-over composite of `front` at `alpha` onto `back`."""
    return tuple(front[i] * alpha + back[i] * (1 - alpha) for i in range(3))


def luminance(color):
    def channel(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(c) for c in color)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    if la < lb:
        la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)


def main():
    source = Path(__file__).resolve().parent.parent / "Sources/nodia/Palettes.swift"
    text = source.read_text()

    rows, failures = [], []
    for m in PALETTE_RE.finditer(text):
        base = rgb(int(m["tint"], 16))

        def against(color, on_band):
            """Contrast against the palette's own tint, bare or under the wash."""
            target = over(rgb(int(m["sel"], 16)), base, float(m["sa"])) if on_band else base
            return contrast(color, target)

        fg, sec = rgb(int(m["fg"], 16)), rgb(int(m["sec"], 16))
        checks = [
            ("正文/底", against(fg, False), BAR_TEXT),
            ("正文/选中", against(fg, True), BAR_TEXT),
            ("次要/底", against(sec, False), BAR_TEXT),
            ("次要/选中", against(sec, True), BAR_TEXT),
            ("强调/底", against(rgb(int(m["acc"], 16)), False), BAR_DECOR),
            ("高亮/选中", against(rgb(int(m["hl"], 16)), True), BAR_DECOR),
        ]
        lf, ls = luminance(fg) + 0.05, luminance(sec) + 0.05
        checks.append(("主次层级", max(lf, ls) / min(lf, ls), BAR_HIERARCHY))

        rows.append((m["name"], checks))
        failures += [(m["name"], n, v, bar) for n, v, bar in checks if v < bar]

    # The System palette is skipped by construction, twice over: it uses
    # semantic colors (.primary / .secondary / .accentColor) that the OS adapts
    # and guarantees, so there is no hex to measure, and it has no tint, so
    # there would be nothing to measure it against either.
    if not rows:
        sys.exit("没有解析到任何配色 —— Palettes.swift 的写法可能变了，正则要跟着改")

    # Counted, not assumed. The pattern above matches a palette by its shape,
    # so one written a little differently is not an error here — it simply
    # isn't in `rows`, and the run goes green having checked one fewer palette
    # than exists. That is the same silent-shrinkage failure the scrub gate was
    # built to stop, one file over.
    declared = len(re.findall(r"static let \w+ = Palette\(", text))
    untinted = len(re.findall(r"tint:\s*nil", text))
    if len(rows) != declared - untinted:
        sys.exit(f"解析到 {len(rows)} 套配色，但 Palettes.swift 里有 {declared} 套"
                 f"（其中 {untinted} 套无 tint，按设计跳过）—— 正则漏掉了一些，先修它")

    labels = [n for n, _, _ in rows[0][1]]
    print(f"{'配色':<14}" + "".join(f"{l:>11}" for l in labels))
    print("-" * (14 + 11 * len(labels)))
    for name, checks in rows:
        cells = "".join(f"{v:>10.1f}{'!' if v < bar else ' '}" for _, v, bar in checks)
        print(f"{name:<14}{cells}")

    print(f"\n阈值：正文/次要 {BAR_TEXT}，强调/高亮 {BAR_DECOR}，主次层级 {BAR_HIERARCHY}")
    print("底色 = 配色自己的 tint 原色，是个替身 —— 玻璃的真实底色由合成器决定，读不回来")
    print("所以这里量的是色板内部的相对关系，不是屏幕上的真实对比度")

    if failures:
        print(f"\n{len(failures)} 处不达标：")
        for name, check, value, bar in failures:
            print(f"  {name:<14}{check:<12}{value:>5.2f}  (需 ≥{bar})")
        return 1
    print(f"\n{len(rows)} 套配色的内部关系全部达标 —— 上屏还得自己看一眼。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
