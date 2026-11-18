#!/bin/bash
# เปลี่ยนไอคอนแอป — ใช้:  ./native/change-icon.sh รูปของคุณ.png [--full]
#   --full = รูปมีขอบมน/พื้นโปร่งใสมาแล้ว ไม่ต้องให้สคริปต์จัดให้
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SRC="${1:-}"
[ -f "$SRC" ] || { echo "ใช้: $0 <รูป.png> [--full]"; exit 2; }
FULL="${2:-}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$HERE"
swift build -c release --product MakeIcon >/dev/null
"$(swift build -c release --show-bin-path)/MakeIcon" "$SRC" "$WORK/icon1024.png" $FULL

ISET="$WORK/AppIcon.iconset"; mkdir -p "$ISET"
gen() { sips -z "$1" "$1" "$WORK/icon1024.png" --out "$ISET/$2.png" >/dev/null; }
gen 16 icon_16x16;    gen 32 icon_16x16@2x
gen 32 icon_32x32;    gen 64 icon_32x32@2x
gen 128 icon_128x128; gen 256 icon_128x128@2x
gen 256 icon_256x256; gen 512 icon_256x256@2x
gen 512 icon_512x512; gen 1024 icon_512x512@2x
iconutil -c icns "$ISET" -o "$WORK/AppIcon.icns"

for APP in "$ROOT/IntroPlayerNative.app" "$ROOT/IntroPlayer.app"; do
  if [ -d "$APP" ]; then
    mkdir -p "$APP/Contents/Resources"
    cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
    touch "$APP"
    echo "  ✓ $(basename "$APP")"
  fi
done
# เก็บต้นฉบับไว้ให้ build.sh ใช้ตอน build ใหม่
cp "$WORK/AppIcon.icns" "$HERE/AppIcon.icns"
# Finder ชอบจำไอคอนเก่า — เขี่ยให้รีเฟรช
touch "$ROOT"/*.app 2>/dev/null || true
killall Dock >/dev/null 2>&1 || true
echo "เปลี่ยนไอคอนแล้ว (ถ้ายังเห็นของเก่า ให้รอสักครู่หรือ log out/in)"
