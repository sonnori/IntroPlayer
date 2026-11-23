#!/bin/bash
# Package "RGF Intro Player.app" as a drag-to-Applications disk image.
#
#   ./native/dmg.sh              build the app first, then package it
#   ./native/dmg.sh --skip-build package the bundle as it stands
#
# Output: dist/IntroPlayer-<ver>.dmg
#
# Deliberately plain: the app, a symlink to /Applications, and a note. A positioned-icon window
# with a background image needs Finder automation against a mounted read/write image, which is
# flaky on a machine where Finder is not in a known state and buys nothing an operator needs. The
# standard two-icon layout is what everyone already recognises.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APPBUNDLE="RGF Intro Player.app"
APP="$ROOT/$APPBUNDLE"
DIST="$ROOT/dist"

SKIP_BUILD=0
PAYLOAD=""
for a in "$@"; do
  case "$a" in
    --skip-build) SKIP_BUILD=1 ;;
    --with-payload) PAYLOAD="--with-payload" ;;
    *) echo "unknown argument: $a"; exit 2 ;;
  esac
done

VERSION="$(tr -d ' \n\r' < "$ROOT/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "✗ ไม่มีไฟล์ VERSION"; exit 1; }

if [ "$SKIP_BUILD" = "0" ]; then
  # shellcheck disable=SC2086
  "$HERE/build.sh" $PAYLOAD
fi
[ -d "$APP" ] || { echo "✗ ไม่มี $APPBUNDLE — รัน ./native/build.sh ก่อน"; exit 1; }

# The stamped version has to be the one in VERSION, or a release gets cut from a stale app and
# nobody finds out until a support call. Same assertion release.sh makes.
STAMPED="$("$APP/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | awk '{print $1}')"
[ "$STAMPED" = "$VERSION" ] || {
  echo "✗ แอปที่จะแพ็กเป็นเวอร์ชั่น ${STAMPED:-—} แต่ VERSION บอก $VERSION"
  echo "  รัน ./native/build.sh ใหม่"
  exit 1
}

mkdir -p "$DIST"
# The suffix is the safety, not decoration: a crew image carries the stings and the show's logo
# and must never sit in dist/ under the public asset's name. `release.sh` uses the same rule for
# its zip, and §15 records what it cost the one time an artifact and its payload disagreed.
if [ -n "$PAYLOAD" ]; then DMG="$DIST/IntroPlayer-$VERSION-ครบชุด.dmg"
else DMG="$DIST/IntroPlayer-$VERSION.dmg"; fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rgf-dmg-XXXXXX")"
# On EVERY exit, not just success: a failed run used to leave an unpacked release tree in dist/
# that looks exactly like an install folder (§15).
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/$APPBUNDLE"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/อ่านก่อน.txt" <<EOF
RGF Intro Player $VERSION

ติดตั้ง
  ลาก "RGF Intro Player" ไปใส่โฟลเดอร์ Applications ที่อยู่ข้าง ๆ กัน
  แล้วปิดหน้าต่างนี้ และ eject ตัวดิสก์

เปิดครั้งแรก
  แอปนี้ยังไม่ได้เซ็น (ไม่ได้จ่ายค่า Developer ID) macOS จะเตือนในครั้งแรก
  ให้คลิกขวาที่ไอคอนแอปใน Applications แล้วเลือก Open แล้วกด Open อีกที
  ถ้ายังไม่ได้ ไปที่ System Settings > Privacy & Security แล้วกด "Open Anyway"

ไฟล์เพลงกับโจทย์
  อยู่คนละที่กับตัวแอป และไม่ถูกแตะตอนอัปเดต
  เปิดแอปครั้งแรกมันจะถามว่าโฟลเดอร์งานอยู่ที่ไหน
  - ถ้าเคยใช้เวอร์ชั่นเก่าอยู่แล้ว มันจะหาเจอเอง ไม่ต้องตอบอะไร
  - ถ้าเริ่มใหม่ ให้กด "สร้างใหม่…" แล้วเลือกโฟลเดอร์ที่จะเก็บงาน
  เปลี่ยนทีหลังได้ที่ ⋯ > เกี่ยวกับแอป > เปลี่ยนโฟลเดอร์งาน

อัปเดตครั้งต่อไป
  กดในแอปได้เลย ไม่ต้องโหลด .dmg อีก — โจทย์ไม่ถูกแตะ
EOF

echo "→ hdiutil create $(basename "$DMG")"
rm -f "$DMG"
hdiutil create -quiet -volname "RGF Intro Player $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# ---- verify the thing that will actually be downloaded, not the folder we just built ----------
# Permissions and bundle structure are what survive or fail to survive the packaging, a Drive
# upload and a double-click. Checking the staging folder proves nothing about that (§15).
MNT="$(mktemp -d "${TMPDIR:-/tmp}/rgf-dmgchk-XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
ok=1
say() { if eval "$2"; then echo "  ok   $1"; else echo "  ✗    $1"; ok=0; fi; }
say "มีแอปอยู่ในดิสก์"            '[ -d "$MNT/$APPBUNDLE" ]'
say "ตัวโปรแกรมยัง executable"     '[ -x "$MNT/$APPBUNDLE/Contents/MacOS/IntroPlayerNative" ]'
say "ตัวสลับโปรแกรมยัง executable" '[ -x "$MNT/$APPBUNDLE/Contents/Resources/swap-app.sh" ]'
# The script the app seeds into the questions folder on first run. A bundle missing it ships an
# app that silently cannot place it — the same shape as the SHIP[]-vs-PROGRAM[] cross-check the
# retired installer needed, in the one place it still applies.
say "มีตัวตรวจสอบเครื่อง และยัง executable" \
    '[ -x "$MNT/$APPBUNDLE/Contents/Resources/scripts/ตรวจสอบเครื่อง.command" ]'
say "มีทางลัดไป /Applications"     '[ -L "$MNT/Applications" ]'
say "มีไฟล์อ่านก่อน"              '[ -f "$MNT/อ่านก่อน.txt" ]'
say "ไม่มี config.json/log.json/songs ติดไป" \
    '[ ! -e "$MNT/config.json" ] && [ ! -e "$MNT/log.json" ] && [ ! -e "$MNT/songs" ]'
ARCHS="$(lipo -archs "$MNT/$APPBUNDLE/Contents/MacOS/IntroPlayerNative" 2>/dev/null || echo "")"
say "universal (arm64 + x86_64) — ได้: ${ARCHS:-?}" \
    'case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) true ;; *) false ;; esac'
GOT="$("$MNT/$APPBUNDLE/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | awk '{print $1}')"
say "แอปในดิสก์ตอบเวอร์ชั่น $VERSION — ได้: ${GOT:-?}" '[ "$GOT" = "$VERSION" ]'
# The payload must not ride along in a public image. Inverted when it was asked for, so a crew
# image that LOST a sting fails as hard as a public one that gained it (§15).
SEEDED=0
[ -d "$MNT/$APPBUNDLE/Contents/Resources/seed" ] && SEEDED=1
if [ -n "$PAYLOAD" ]; then
  say "มีไฟล์ของรายการครบตามที่สั่ง --with-payload" \
      '[ "$SEEDED" = "1" ] && [ -f "$MNT/'"$APPBUNDLE"'/Contents/Resources/seed/se/correct.mp3" ] && [ -f "$MNT/'"$APPBUNDLE"'/Contents/Resources/seed/brand/logo.png" ]'
else
  say "ไม่มีเสียง/โลโก้ของรายการติดไปในดิสก์สาธารณะ" '[ "$SEEDED" = "0" ]'
fi
hdiutil detach -quiet "$MNT" || true
rmdir "$MNT" 2>/dev/null || true
[ "$ok" = "1" ] || { echo "✗ ตรวจดิสก์ไม่ผ่าน"; rm -f "$DMG"; exit 1; }

shasum -a 256 "$DMG" | awk '{print $1"  "FILENAME}' FILENAME="$(basename "$DMG")" \
  > "$DIST/$(basename "$DMG").sha256"
echo "✓ $DMG"
echo "  $(du -h "$DMG" | awk '{print $1}')  ·  sha256 $(awk '{print $1}' < "$DIST/$(basename "$DMG").sha256")"
