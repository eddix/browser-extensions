#!/usr/bin/env python3
"""Checks that every colour in the icon SVGs survives both toolbars.

    python3 tools/icon-contrast.py

The icons sit on a transparent background, so the toolbar shows through and
there are two of them: a near-white one under the light theme and a near-black
one under the dark. Chrome does not tint extension icons the way Safari tints a
template image — the PNG is drawn exactly as authored — so one set of colours
has to clear both.

That is a squeeze, and it has a ceiling most people do not expect. A colour is
pinned between the two backgrounds: darken it for the light toolbar and it
loses the dark one, and the best a single colour can do is the point where both
sides come out equal. For the two backgrounds below that point is 3.55:1, and
no amount of adjusting gets past it. So if a number here looks low, the fix is
not a darker colour. It is either a different pair of reference backgrounds or
two sets of icons swapped on `prefers-color-scheme`, which the extension does
not currently do.

The bar is 3.0 — WCAG's threshold for graphics rather than text, which is what
these are. It leaves about half a stop of room under the ceiling, which is the
whole margin available.
"""

import re
import sys
from pathlib import Path

# Stand-ins for the two toolbars. Sampled rather than assumed pure white and
# pure black: a mid-grey background is *harder* than a pure one, because it
# leaves less room on the side it is closer to, and using #FFF/#000 here would
# report a ceiling that the real thing cannot reach.
LIGHT = "#F2F2F4"
DARK = "#2B2B30"
BAR = 3.0

FILL_RE = re.compile(r'fill="(#[0-9A-Fa-f]{6})"')

# Known answers, checked on every run. Contrast code is easy to get subtly
# wrong — a missing gamma step still produces plausible-looking numbers, in the
# right ballpark and wrong everywhere it matters — and nothing else here would
# notice.
SELF_TEST = [
    ("#000000", "#FFFFFF", 21.0),
    ("#FFFFFF", "#FFFFFF", 1.0),
    ("#777777", "#FFFFFF", 4.48),
]


def luminance(colour):
    channels = [int(colour.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def ceiling():
    """Best a single colour can do against both backgrounds at once."""
    best = ((luminance(LIGHT) + 0.05) * (luminance(DARK) + 0.05)) ** 0.5 - 0.05
    return (luminance(LIGHT) + 0.05) / (best + 0.05)


def self_test():
    broken = [
        (a, b, want, contrast(a, b))
        for a, b, want in SELF_TEST
        if abs(contrast(a, b) - want) > 0.01
    ]
    for a, b, want, got in broken:
        print(f"自检失败：{a} 对 {b} 应为 {want}，实际 {got:.2f}")
    return not broken


def main():
    root = Path(__file__).resolve().parent.parent
    if not self_test():
        return 2

    svgs = sorted(root.glob("*/icons/*.svg")) + sorted(root.glob("*/*/icons/*.svg"))
    if not svgs:
        print("没有找到任何图标 SVG —— 检查跑了个空，比失败更糟，当失败处理。")
        return 2

    print(f"两端上限 {ceiling():.2f}:1（{LIGHT} 与 {DARK}），门槛 {BAR}\n")
    failures, checked = [], 0
    for svg in svgs:
        colours = sorted(set(FILL_RE.findall(svg.read_text())))
        if not colours:
            failures.append((svg.relative_to(root), "—", 0.0, 0.0))
            continue
        print(f"  {svg.relative_to(root)}")
        for colour in colours:
            light, dark = contrast(colour, LIGHT), contrast(colour, DARK)
            checked += 1
            mark = "" if min(light, dark) >= BAR else "   低于门槛"
            print(f"    {colour}  浅 {light:.2f}  深 {dark:.2f}{mark}")
            if min(light, dark) < BAR:
                failures.append((svg.relative_to(root), colour, light, dark))

    if failures:
        print(f"\n{len(failures)} 个颜色在某一侧的工具栏上看不清：")
        for path, colour, light, dark in failures:
            if colour == "—":
                print(f"  {path}  没有解析到任何 fill —— 是不是改用了 style 或 currentColor？")
            else:
                print(f"  {path}  {colour}  浅 {light:.2f}  深 {dark:.2f}")
        return 1

    print(f"\n{len(svgs)} 个 SVG、{checked} 个颜色，两侧工具栏都过 {BAR}。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
