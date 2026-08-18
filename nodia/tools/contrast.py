#!/usr/bin/env python3
"""WCAG contrast check for the palettes in Sources/nodia/Palettes.swift.

Run it after adding or editing a palette:

    python3 tools/contrast.py

Why this exists: the palettes are borrowed from editor themes, where the
de-emphasized color is a comment color picked against one solid background.
Here it lands on two — the frosted background, and the selection wash painted
over it for the current row — and the wash *lightens*, which is exactly the
direction that kills a dim color. Measured before this check existed, all nine
palettes failed on a selected row; Dracula's `#6272A4` came out at 1.8:1.

The background is an approximation and says so. The panel is an
NSVisualEffectView over whatever happens to be behind the window, so the true
value moves. What doesn't move is the shape of the problem, and a palette that
fails here fails on any desktop.
"""

import re
import sys
from pathlib import Path

# NSVisualEffectView output, as a *range*.
#
# The panel blurs whatever is behind the window, so its background is not one
# color — a dark editor and a white document land in different places, and the
# window's own opacity has no say in it (that alpha applies after the view has
# already drawn a picture of your desktop). Everything below is evaluated at
# both ends and reported at the worse one, because a palette tuned to the
# middle looked fine in a screenshot and fell to 3.4:1 the moment the panel
# happened to sit over something pale.
MATERIAL_DARK = (0x141416, 0x5A5A5E)
MATERIAL_LIGHT = (0xDCDCDC, 0xFFFFFF)

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
    r'tint:\s*(?:Color\(hex:\s*(?P<tint>0x[0-9A-Fa-f]+)\)|nil),\s*'
    r'tintOpacity:\s*(?P<ta>[\d.]+),\s*'
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
        dark = m["dark"] == "true"
        extremes = MATERIAL_DARK if dark else MATERIAL_LIGHT

        def against(color, on_band):
            """Worst contrast across the backdrop range."""
            worst = None
            for base in extremes:
                bg = over(rgb(int(m["tint"], 16)), rgb(base), float(m["ta"])) if m["tint"] else rgb(base)
                target = over(rgb(int(m["sel"], 16)), bg, float(m["sa"])) if on_band else bg
                r = contrast(color, target)
                worst = r if worst is None else min(worst, r)
            return worst

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

    # The System palette is skipped by construction: it uses semantic colors
    # (.primary / .secondary / .accentColor) that the OS adapts and guarantees,
    # and there is no hex to measure.
    if not rows:
        sys.exit("没有解析到任何配色 —— Palettes.swift 的写法可能变了，正则要跟着改")

    labels = [n for n, _, _ in rows[0][1]]
    print(f"{'配色':<14}" + "".join(f"{l:>11}" for l in labels))
    print("-" * (14 + 11 * len(labels)))
    for name, checks in rows:
        cells = "".join(f"{v:>10.1f}{'!' if v < bar else ' '}" for _, v, bar in checks)
        print(f"{name:<14}{cells}")

    print(f"\n阈值：正文/次要 {BAR_TEXT}，强调/高亮 {BAR_DECOR}，主次层级 {BAR_HIERARCHY}")
    print("每格取背景区间两端里较差的一侧 —— 面板压在浅色窗口上是最坏情况")

    if failures:
        print(f"\n{len(failures)} 处不达标：")
        for name, check, value, bar in failures:
            print(f"  {name:<14}{check:<12}{value:>5.2f}  (需 ≥{bar})")
        return 1
    print(f"\n{len(rows)} 套配色全部达标。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
