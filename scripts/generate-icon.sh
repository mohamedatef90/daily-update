#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Assets/AppIcon/AppIcon.png"
ICONSET="$ROOT/Assets/AppIcon/AppIcon.iconset"
ICNS="$ROOT/Assets/AppIcon/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing source icon: $SOURCE" >&2
  exit 1
fi

echo "Generating macOS icon sizes..."
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

make_icon() {
  local size=$1
  local name=$2
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" >/dev/null
}

make_icon 16  icon_16x16.png
make_icon 32  icon_16x16@2x.png
make_icon 32  icon_32x32.png
make_icon 64  icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

echo "Building AppIcon.icns..."
iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Created $ICNS"
