#!/bin/sh
# Renders every icons/*.svg in this repository to the PNG sizes the manifests
# ask for. Run it after editing any of the SVGs.
#
#     tools/render-icons.sh
#
# The SVG is the source and the PNG is output, which needs saying because the
# repository contains both and nothing else marks which is which. Chrome will
# not take an SVG for `manifest.icons` or `chrome.action.setIcon` — those are
# raster only — so the drawing has to be committed twice, once in the form you
# can edit and once in the form the browser accepts. An SVG nobody can rebuild
# the PNGs from is decoration: the next person edits it, sees no change, and
# eventually edits the PNG instead.
#
# Headless Chrome does the rasterising because it is the one renderer this
# machine is guaranteed to have — the extensions run in it. No rsvg, no
# ImageMagick, no npm install.
#
# Each size goes through a generated HTML wrapper that draws the SVG at exactly
# that many CSS pixels. Pointing Chrome at the .svg directly and shrinking
# `--window-size` does *not* scale it: the SVG declares its own width, so a
# 16x16 window simply captures the top-left corner of a 128px drawing, and the
# icons came out as an arc of the rounded corner with nothing else in them.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHROME=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}

if [ ! -x "$CHROME" ]; then
  echo "找不到 Chrome：$CHROME" >&2
  echo "装在别处的话，用 CHROME=/path/to/chrome $0" >&2
  exit 1
fi

# Colours are checked before anything is rasterised, so a colour that fails is
# caught while the SVG is still the only thing that changed. Rendering first
# would leave twelve committed PNGs carrying the bad value.
python3 "$ROOT/tools/icon-contrast.py"

# Wrappers live under the repository so the same server can serve both them and
# the SVGs they point at; the directory is ignored and removed on the way out.
WORK="$ROOT/.icon-render"
rm -rf "$WORK" && mkdir -p "$WORK"
PORT=8975
# Served over http rather than opened as file://, because a file:// page is not
# allowed to load the SVG sitting next to it.
(cd "$ROOT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; rm -rf "$WORK"' EXIT INT TERM

for _ in $(seq 1 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.1
done

find "$ROOT" -path '*/icons/*.svg' -not -path '*/node_modules/*' | sort | while read -r svg; do
  dir=$(dirname "$svg")
  base=$(basename "$svg" .svg)          # icon | icon-green | icon-red
  suffix=${base#icon}                   # "" | -green | -red
  rel=${svg#"$ROOT"/}

  for size in 16 48 128; do
    name="$(echo "$rel" | tr / _)-$size.html"
    page="$WORK/$name"
    # margin:0 and a matching body size, so the drawing starts at the very
    # first pixel and the window has nothing else in it to capture.
    cat > "$page" <<HTML
<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;padding:0;width:${size}px;height:${size}px;background:transparent}
  img{display:block;width:${size}px;height:${size}px}
</style>
<img src="/$rel">
HTML
    out="$dir/icon$size$suffix.png"
    "$CHROME" --headless --disable-gpu --hide-scrollbars --no-first-run \
      --default-background-color=00000000 \
      --window-size="$size,$size" \
      --screenshot="$out" \
      "http://127.0.0.1:$PORT/.icon-render/$name" >/dev/null 2>&1
    [ -s "$out" ] || { echo "渲染失败：$out" >&2; exit 1; }
  done
  echo "  $rel → icon{16,48,128}$suffix.png"
done

echo "完成。PNG 是生成物，别手改——改 SVG 再跑一次。"
