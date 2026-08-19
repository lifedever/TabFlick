#!/bin/bash
# 从 assets/appicon.svg 生成 macOS 的 .icns。
#
# 依赖 rsvg-convert（brew install librsvg）。用 SVG 逐尺寸重新栅格化，
# 而不是缩放同一张大 PNG —— 16/32 这种小尺寸缩出来会糊。
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="assets/appicon.svg"
ICONSET="$(mktemp -d)/TabFlick.iconset"
OUT="assets/TabFlick.icns"

command -v rsvg-convert >/dev/null || {
    echo "❌ 缺少 rsvg-convert：brew install librsvg" >&2
    exit 1
}

mkdir -p "$ICONSET"

# iconutil 要求的文件名固定成这套，多一个少一个都会报错
render() {  # render <像素尺寸> <文件名>
    rsvg-convert -w "$1" -h "$1" "$SVG" -o "$ICONSET/$2"
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns "$ICONSET" --output "$OUT"
rm -rf "$(dirname "$ICONSET")"

echo "✅ $OUT ($(du -h "$OUT" | cut -f1))"
