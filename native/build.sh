#!/bin/bash
# Builds the native app and assembles IntroPlayerNative.app next to the web version.
#   ./native/build.sh          release build, universal (arm64 + x86_64)
#   ./native/build.sh debug    faster build while iterating, this machine's arch only
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
CONF="${1:-release}"
APP="$ROOT/IntroPlayerNative.app"
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
[ -f "$ROOT/IntroPlayer.app/Contents/Resources/AppIcon.icns" ] \
  && cp "$ROOT/IntroPlayer.app/Contents/Resources/AppIcon.icns" "$NEW/Contents/Resources/"
cp "$HERE/Info.plist" "$NEW/Contents/Info.plist"
printf 'APPL????' > "$NEW/Contents/PkgInfo"

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
