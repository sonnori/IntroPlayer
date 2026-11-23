#!/bin/bash
# Builds the native app and assembles "RGF Intro Player.app" next to the web version.
# The bundle name carries a space; the EXECUTABLE inside stays `IntroPlayerNative`,
# which is what pgrep matches on and what every documented diagnostic invokes.
#   ./native/build.sh                 release build, universal (arm64 + x86_64)
#   ./native/build.sh debug           faster build while iterating, this machine's arch only
#   ./native/build.sh --with-payload  ALSO bundle se/*.mp3 and brand/logo.png as first-run seed
#
# About --with-payload (CLAUDE.md §5d/§15). Once the app lives in /Applications it cannot seed a
# new questions folder from files sitting next to itself, so the stings and the show's logo have
# to travel inside the bundle — and they must NOT travel in a public build. This repo is public
# and §15 records the day `brand` joined SEED[] and the logo went into a GitHub release before
# anyone noticed. So the default build carries no payload at all and `release.sh --crew` is the
# only thing that passes this flag.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
CONF="release"
PAYLOAD=0
for a in "$@"; do
  case "$a" in
    --with-payload) PAYLOAD=1 ;;
    debug|release) CONF="$a" ;;
    *) echo "unknown argument: $a"; exit 2 ;;
  esac
done
APP="$ROOT/RGF Intro Player.app"
NEW="$APP.new"
OLD="$APP.old"

# The version comes from one file so it cannot drift from the source it was built out of. The
# commit and date go in as custom keys; `AppVersion` reads all three back out of Info.plist.
VERSION="$(tr -d ' \n\r' < "$ROOT/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "no VERSION file at $ROOT/VERSION"; exit 1; }
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
# A build made with uncommitted edits is NOT the commit it names — saying so here is what keeps
# "which build is this" answerable once the folder is in other people's hands.
if [ -n "$COMMIT" ] && ! git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null; then
  COMMIT="$COMMIT+dirty"
fi
BUILT="$(date +%Y-%m-%d)"

cd "$HERE"

# Release builds go universal so the folder can be copied to an Intel Mac and still run; debug
# stays single-arch because the only reader is this machine and the build time matters.
BIN=""
if [ "$CONF" = "release" ]; then
  echo "→ swift build (release, universal)"
  if swift build -c release --arch arm64 --arch x86_64; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/IntroPlayerNative"
  else
    echo "  universal build failed — falling back to this machine's arch only"
  fi
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "→ swift build ($CONF)"
  swift build -c "$CONF"
  BIN="$(swift build -c "$CONF" --show-bin-path)/IntroPlayerNative"
fi
[ -x "$BIN" ] || { echo "build produced no binary at $BIN"; exit 1; }

# Assemble into a side path and swap at the end. The old script did `rm -rf "$APP"` first, so any
# failure after that point (or running it while the app was open) left no app at all.
echo "→ assembling $(basename "$APP")"
rm -rf "$NEW" "$OLD"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp "$BIN" "$NEW/Contents/MacOS/IntroPlayerNative"
# reuse the icon already generated for the web launcher
# The master lives at native/AppIcon.icns — that is where change-icon.sh keeps it. Reading the
# web launcher's copy first meant deleting IntroPlayer.app lost the icon on the next rebuild even
# though the master was right there.
for ICNS in "$HERE/AppIcon.icns" "$ROOT/IntroPlayer.app/Contents/Resources/AppIcon.icns"; do
  [ -f "$ICNS" ] && { cp "$ICNS" "$NEW/Contents/Resources/AppIcon.icns"; break; }
done
cp "$HERE/Info.plist" "$NEW/Contents/Info.plist"
printf 'APPL????' > "$NEW/Contents/PkgInfo"

# The on-site diagnostic. "ดับเบิลคลิกไฟล์นี้ที่เครื่องที่มีปัญหา" has to work when the app does
# not, so it ships here and the app seeds it into the questions folder on first run. It used to be
# a sibling of the data by virtue of the old layout; that stops being a place once the app can
# live in /Applications.
#
# The WEB fallback is deliberately not here. It stays in the repo and still works in a
# classic-layout folder (`server.py --root` makes it work from anywhere), but it is no longer
# shipped or seeded — the native app being solid is the thing worth the effort.
mkdir -p "$NEW/Contents/Resources/scripts"
[ -f "$ROOT/ตรวจสอบเครื่อง.command" ] || { echo "missing ตรวจสอบเครื่อง.command"; exit 1; }
cp "$ROOT/ตรวจสอบเครื่อง.command" "$NEW/Contents/Resources/scripts/ตรวจสอบเครื่อง.command"
chmod +x "$NEW/Contents/Resources/scripts/ตรวจสอบเครื่อง.command"

# The swap helper for in-app updates. Tiny compared with the installer it replaces, because the
# questions are no longer anywhere near what it touches.
[ -f "$HERE/swap-app.sh" ] || { echo "missing native/swap-app.sh"; exit 1; }
cp "$HERE/swap-app.sh" "$NEW/Contents/Resources/swap-app.sh"
chmod +x "$NEW/Contents/Resources/swap-app.sh"

if [ "$PAYLOAD" = "1" ]; then
  echo "  ● --with-payload: ใส่เสียงตอบถูก/ผิด และโลโก้รายการเข้า bundle — ห้ามปล่อยขึ้นที่สาธารณะ"
  mkdir -p "$NEW/Contents/Resources/seed/se" "$NEW/Contents/Resources/seed/brand"
  miss=""
  for f in se/correct.mp3 se/wrong.mp3; do
    if [ -f "$ROOT/$f" ]; then cp "$ROOT/$f" "$NEW/Contents/Resources/seed/$f"; else miss="$miss $f"; fi
  done
  if [ -f "$ROOT/brand/logo.png" ]; then
    cp "$ROOT/brand/logo.png" "$NEW/Contents/Resources/seed/brand/logo.png"
  else miss="$miss brand/logo.png"; fi
  # A crew build that lost a sting is exactly what this flag exists to prevent, so it is fatal
  # rather than a warning — the same inversion release.sh applies to its own payload check.
  [ -z "$miss" ] || { echo "✗ --with-payload แต่หาไฟล์พวกนี้ไม่เจอ:$miss"; exit 1; }
fi

PB=/usr/libexec/PlistBuddy
plist="$NEW/Contents/Info.plist"
"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$plist"
"$PB" -c "Set :CFBundleVersion $VERSION" "$plist"
for k in RGFGitCommit RGFBuildDate; do
  "$PB" -c "Delete :$k" "$plist" >/dev/null 2>&1 || true
done
"$PB" -c "Add :RGFGitCommit string $COMMIT" "$plist"
"$PB" -c "Add :RGFBuildDate string $BUILT" "$plist"

# Unsigned bundles are quarantined when copied between machines; ad-hoc signing at least keeps
# macOS from re-prompting on this machine after every rebuild.
codesign --force --deep --sign - "$NEW" >/dev/null 2>&1 || true

if [ -d "$APP" ]; then mv "$APP" "$OLD"; fi
mv "$NEW" "$APP"
rm -rf "$OLD"

echo "✓ $APP"
echo "  version: $VERSION${COMMIT:+ ($COMMIT)} built $BUILT"
lipo -archs "$APP/Contents/MacOS/IntroPlayerNative" 2>/dev/null | sed 's/^/  arch: /' || true
if [ -d "$APP/Contents/Resources/seed" ]; then
  echo "  seed: มีไฟล์ของรายการอยู่ใน bundle (crew build)"
else
  echo "  seed: ไม่มี (บิลด์สาธารณะ)"
fi
