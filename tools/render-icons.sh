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
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHROME=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}

if [ ! -x "$CHROME" ]; then
  echo "找不到 Chrome：$CHROME" >&2
  echo "装在别处的话，用 CHROME=/path/to/chrome $0" >&2
  exit 1
fi

# Served over http rather than opened as file://, because a file:// page cannot
# fetch its own siblings and the renderer needs the SVG to resolve.
PORT=8975
(cd "$ROOT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT INT TERM

# Wait for it rather than sleeping a guessed amount.
for _ in $(seq 1 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.1
done

count=0
find "$ROOT" -path '*/icons/*.svg' -not -path '*/node_modules/*' | while read -r svg; do
  dir=$(dirname "$svg")
  base=$(basename "$svg" .svg)          # icon | icon-green | icon-red
  suffix=${base#icon}                   # "" | -green | -red
  rel=${svg#"$ROOT"/}

  for size in 16 48 128; do
    out="$dir/icon$size$suffix.png"
    "$CHROME" --headless --disable-gpu --hide-scrollbars --no-first-run \
      --default-background-color=00000000 \
      --window-size="$size,$size" \
      --screenshot="$out" \
      "http://127.0.0.1:$PORT/$rel" >/dev/null 2>&1
    [ -s "$out" ] || { echo "渲染失败：$out" >&2; exit 1; }
  done
  echo "  $rel → icon{16,48,128}$suffix.png"
  count=$((count + 1))
done

echo "完成。PNG 是生成物，别手改——改 SVG 再跑一次。"
