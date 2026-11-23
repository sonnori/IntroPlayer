#!/bin/bash
# Packages a release for the crew: one zip anyone can double-click into place.
#
#   ./native/release.sh                      build + package the version in ./VERSION
#   ./native/release.sh --skip-build         package the app bundle as it already stands
#   ./native/release.sh --allow-dirty        package from a tree with uncommitted edits
#   ./native/release.sh --download <url>     put a download URL in the generated manifest.json
#   ./native/release.sh --github             publish to GitHub Releases with `gh` (no manifest
#                                            needed — the app reads the release itself)
#   ./native/release.sh --crew               INCLUDE se/*.mp3 and brand/logo.png
#
# Output in dist/:
#   IntroPlayer-<ver>.zip   what you hand over / upload
#   manifest.json           what the app's update check reads (upload it NEXT TO the zip)
#   SHA256SUMS
#
# About --crew. The default strips SEED_PAYLOAD (the stings and the show's logo) because this
# repo is public and those are the production's, not this program's — §15, and the day `brand`
# joined SEED[] they went into a public GitHub release before anyone noticed. --crew is for a
# package the owner hands to their own crew, so it keeps them, and three things keep the two
# apart rather than one:
#   * refused together with --github, in the pre-flight, before anything is built;
#   * a DIFFERENT zip name and a different checksum file, so a crew zip can never be mistaken
#     for the asset on the release page or clobber its SHA256SUMS;
#   * the payload assertions INVERT rather than switch off — a crew zip missing a sting fails
#     just as hard as a public zip carrying one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

SKIP_BUILD=0
ALLOW_DIRTY=0
DL=""
GH=0
CREW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --crew) CREW=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --download)
      shift
      [ $# -gt 0 ] || { echo "--download ต้องตามด้วย URL"; exit 2; }
      DL="$1"
      ;;
    --no-download) DL="-" ;;
    --github) GH=1 ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

VERSION="$(tr -d ' \n\r' < VERSION)"
[ -n "$VERSION" ] || { echo "VERSION is empty"; exit 1; }
# VERSION is hand-edited and is interpolated into a path this script rm -rf's. `tr` above strips
# whitespace but not `/` or `.`, so refuse anything that is not a plain version string.
case "$VERSION" in
  *[!0-9.a-zA-Z_-]*|*..*|.*|"") echo "✗ VERSION ใช้ได้แต่ตัวเลข ตัวอักษร . _ - (ได้: '$VERSION')"; exit 1 ;;
esac

# A build handed to other people has to be reproducible: once it is on three machines, "which
# code is this" can only be answered by the commit it names. `+dirty` makes that unanswerable.
# `git diff --quiet HEAD --` returns 0 when the only change is an UNTRACKED file — which is the
# commonest form of uncommitted work and was the state this very feature was written in, VERSION
# included. `git status --porcelain` sees untracked files too.
DIRT="$(git status --porcelain 2>/dev/null)"
if [ "$ALLOW_DIRTY" = "0" ] && [ -n "$DIRT" ]; then
  echo "✗ มีไฟล์ที่แก้/เพิ่มแล้วยังไม่ commit — commit ก่อน หรือใช้ --allow-dirty"
  printf '%s\n' "$DIRT" | sed 's/^/    /'
  exit 1
fi

# ---- --crew pre-flight, BEFORE the build, for the same reason the GitHub one is ----
if [ "$CREW" = "1" ]; then
  if [ "$GH" = "1" ]; then
    echo "✗ --crew กับ --github ใช้ด้วยกันไม่ได้"
    echo "  --crew ใส่ไฟล์เสียงกับโลโก้ของรายการลงไป และ repo นี้เป็น public"
    echo "  จะปล่อยขึ้น GitHub ให้รันแยกโดยไม่ใส่ --crew"
    exit 1
  fi
  # A crew zip with no stings is exactly the thing --crew exists to prevent, so say so here
  # rather than let it ship and be discovered on a shoot.
  missing=""
  for f in se/correct.mp3 se/wrong.mp3 brand/logo.png; do
    [ -f "$ROOT/$f" ] || missing="$missing  $f"
  done
  if [ -n "$missing" ]; then
    echo "✗ --crew แต่หาไฟล์พวกนี้ในโฟลเดอร์นี้ไม่เจอ:"
    printf '%s\n' "$missing" | tr ' ' '\n' | grep -v '^$' | sed 's/^/    /'
    exit 1
  fi
fi

# ---- GitHub pre-flight, BEFORE the build ----
# Every one of these used to be checked at the very END, after ~30 s of building, staging,
# zipping and verifying. That ordering had a real cost measured on 1.3.0: a second
# `--github` run rebuilt and RE-ZIPPED, then refused because v1.3.0 already existed — and
# zip output is not byte-reproducible (it stores timestamps), so the same commit re-zipped
# gives a different file. `dist/IntroPlayer-1.3.0.zip` and `dist/SHA256SUMS` were left
# describing a zip that is NOT the one the team downloads, with identical size and version
# and a different hash. Anyone using SHA256SUMS to check a zip fetched from the release page
# would conclude a good download was corrupt — the same failure this script was just fixed
# for, one level up. Refusing before anything is written is what actually prevents it.
if [ "$GH" = "1" ]; then
  command -v gh >/dev/null 2>&1 || { echo "✗ ไม่มีคำสั่ง gh — ติดตั้ง GitHub CLI ก่อน"; exit 1; }
  # Show what `gh` ACTUALLY said. This used to throw stderr away and then assert the cause
  # ("ยังไม่ได้ login"), which is a guess: `gh auth status` also fails on a locked keyring, an
  # expired token and missing scopes, and the fix for each is different. Measured on this
  # machine — the check failed here while `gh auth status` reported a perfectly good
  # `Logged in to github.com account sonnori (keyring)`, and the message sent the operator off
  # to re-run `gh auth login` they did not need. Same shape as §12's `saveNow()` reporting
  # "saved ✓" unconditionally: swallow the real error, print the one you assumed.
  if ! GH_AUTH="$(gh auth status 2>&1)"; then
    echo "✗ gh ใช้งานไม่ได้ — ข้างล่างนี้คือสิ่งที่ gh บอกมาจริงๆ:"
    printf '%s\n' "$GH_AUTH" | sed 's/^/    /'
    echo "  ถ้ามันบอกว่ายังไม่ได้ login ให้รัน: gh auth login"
    exit 1
  fi
  SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")"
  [ -n "$SLUG" ] || { echo "✗ โฟลเดอร์นี้ยังไม่ได้ผูกกับ repo บน GitHub"; exit 1; }
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "✗ มี release v$VERSION อยู่แล้วบน $SLUG — ไม่ได้ build อะไร และไม่ได้แตะ dist/"
    echo "  ถ้าจะปล่อยซ้ำ: ลบอันเก่าก่อน  gh release delete v$VERSION"
    echo "  ถ้าจะปล่อยของใหม่: ขยับเลขใน VERSION"
    exit 1
  fi
fi

if [ "$SKIP_BUILD" = "0" ]; then
  # --crew now means "build the bundle with the payload inside", not "copy extra files next to
  # it": once the app lives in /Applications there is nothing next to it to copy into (§5d).
  if [ "$CREW" = "1" ]; then "$HERE/build.sh" release --with-payload
  else "$HERE/build.sh" release; fi
fi

# The bundle name. It used to be read out of the (now retired) installer.command so the two
# could not disagree
# about what gets installed; the installer is gone, so this is the source and `Install.bundleName`
# in Swift is the copy — which `--updatestage` against a real release is what proves still agrees.
APPBUNDLE="RGF Intro Player.app"
APP="$ROOT/$APPBUNDLE"
[ -d "$APP" ] || { echo "✗ ไม่มี $APPBUNDLE — รัน ./native/build.sh ก่อน"; exit 1; }

# The bundle must actually carry the version we are naming the zip after. Without this the
# release could be built from a stale app and nobody would find out until a support call.
STAMPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "$STAMPED" != "$VERSION" ]; then
  echo "✗ แอปใน bundle เป็น '$STAMPED' แต่ VERSION คือ '$VERSION' — รัน ./native/build.sh ใหม่"
  exit 1
fi

DIST="$ROOT/dist"
# The suffix is the safety, not decoration: it keeps a crew zip out of the public asset's
# name and out of its SHA256SUMS. See the --crew note at the top.
if [ "$CREW" = "1" ]; then NAME="IntroPlayer-$VERSION-ครบชุด"; else NAME="IntroPlayer-$VERSION"; fi
if [ "$CREW" = "1" ]; then SUMFILE="SHA256SUMS-ครบชุด"; else SUMFILE="SHA256SUMS"; fi
STAGE="$DIST/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# Cleaned on EVERY exit, not just the two success paths. A `--github` run that stops at
# `gh auth status`, or any run that refuses for a missing download URL, used to leave the
# unpacked staging tree sitting in dist/ — and that tree looks exactly like an install
# folder. §15 step 3 means the installer would refuse to aim at it (it carries the release
# markers), but it is still a thing a human can mistake for the real folder and copy into.
trap 'rm -rf "$STAGE"' EXIT

# **The zip holds the bundle and nothing else.** Everything that used to sit beside it —
# `server.py`, `index.html`, `ตรวจสอบเครื่อง.command`, `start.command`, `VERSION`, the installer,
# `se/`, `brand/` — either moved inside the bundle (§5d) or stopped being a thing a release has to
# place. config.json / log.json / songs/ were never in a release and now cannot be: the swap
# helper replaces one directory and has no idea where the questions are.
#
# So the SHIP[]-vs-PROGRAM[] cross-check is gone with the installer that was its other half. What
# replaced it is the verification below, which asserts the BUNDLE's own contents — the web
# fallback, the swap helper, and the presence or absence of the payload — because those are now
# the things that can go stale in place.
echo "→ staging $NAME"
cp -R "$APP" "$STAGE/$APPBUNDLE"

if [ "$CREW" = "1" ]; then
  echo "  ● --crew: เสียงตอบถูก/ผิด และโลโก้รายการอยู่ใน bundle แล้ว — ห้ามอัปโหลดขึ้นที่สาธารณะ"
fi

# A release is made on this machine and opened on another, so strip this machine's quarantine
# and resource forks rather than shipping them.
xattr -cr "$STAGE" 2>/dev/null || true

# Read the commit back OUT of the bundle rather than recomputing it. build.sh appends `+dirty`
# when the tree is not clean, and recomputing here silently dropped that: the published
# manifest.json asserted a clean sha for a binary that was not that commit — in the one
# machine-readable artifact that outlives the conversation.
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :RGFGitCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
[ -n "$COMMIT" ] || COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo "-")"
# The human-facing instructions live on the .dmg now (`อ่านก่อน.txt`, written by dmg.sh): the zip
# is what the in-app updater fetches, and it unpacks into a temp directory nobody reads.
echo "→ zipping"
# Every entry is prefixed `IntroPlayer-<ver>/`, so the old `-x '.*'` matched nothing at all.
( cd "$DIST" && rm -f "$NAME.zip" && zip -qry "$NAME.zip" "$NAME" -x '*/.DS_Store' -x '*/__MACOSX/*' )

# ---- verify the zip, not the staging folder ----
# Permissions and bundle structure are what survive or do not survive a trip through a zip, a
# Drive upload and Archive Utility. Checking the folder we just built proves nothing about that.
echo "→ verifying the zip round-trips"
TMP="$(mktemp -d)"
# BOTH, because a second `trap ... EXIT` REPLACES the first — which is how the staging-folder
# cleanup above would have been silently disarmed by the line that cleans the unzip dir.
trap 'rm -rf "$TMP" "$STAGE"' EXIT
( cd "$TMP" && unzip -qq "$DIST/$NAME.zip" )
U="$TMP/$NAME"
fail=0
check() { if eval "$2"; then echo "   ok   $1"; else echo "   ✗    $1"; fail=1; fi; }
B="$U/$APPBUNDLE"
check "มีแอปใน zip"                    '[ -d "$B" ]'
check "ตัวโปรแกรมยัง executable"        '[ -x "$B/Contents/MacOS/IntroPlayerNative" ]'
# The updater refuses a zip without this (`Install.missingSwapHelper`), and a zip that cannot be
# installed is worse than no release: the operator is told there is an update and it then fails
# halfway. §12 records `--updatestage` spelling its subject literally and therefore only ever
# being able to report failure — so this is driven off the same constant the app uses.
check "ตัวสลับโปรแกรมยัง executable"    '[ -x "$B/Contents/Resources/swap-app.sh" ]'
check "มีตัวตรวจสอบเครื่อง และยัง executable" \
      '[ -x "$B/Contents/Resources/scripts/ตรวจสอบเครื่อง.command" ]'
check "ไม่มี config.json ติดไปด้วย"      '[ ! -e "$U/config.json" ] && [ ! -e "$B/config.json" ]'
check "ไม่มี log.json ติดไปด้วย"         '[ ! -e "$U/log.json" ] && [ ! -e "$B/log.json" ]'
check "ไม่มี songs/ ติดไปด้วย"           '[ ! -e "$U/songs" ]'
# Inverted rather than skipped under --crew: a crew zip that LOST a sting fails as hard as a
# public zip that gained one. A check that switches off is a check that stops covering the case
# it was added for (§15).
SEED_DIR="$B/Contents/Resources/seed"
if [ "$CREW" = "1" ]; then
  check "มีเสียง + โลโก้ครบตามที่สั่งด้วย --crew" \
        '[ -f "$SEED_DIR/se/correct.mp3" ] && [ -f "$SEED_DIR/se/wrong.mp3" ] && [ -f "$SEED_DIR/brand/logo.png" ]'
else
  check "ไม่มีไฟล์ของรายการที่ไม่รู้ licence ติดไปด้วย" '[ ! -d "$SEED_DIR" ]'
fi
ARCHS="$(lipo -archs "$B/Contents/MacOS/IntroPlayerNative" 2>/dev/null || echo "")"
check "universal (arm64 + x86_64) — arch: $ARCHS" '[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]'
# The strongest check available: ask the unzipped binary what it is.
GOT="$("$B/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 || echo "")"
check "แอปที่แตกออกมารายงานเวอร์ชั่น $VERSION — ได้: ${GOT:-ไม่ตอบ}" '[[ "$GOT" == "$VERSION"* ]]'
# A stale SHA256SUMS beside a zip is worse than none: it names the file sitting next to it,
# so whoever hands the zip over by hand checks it, gets a mismatch, and concludes a perfectly
# good release is corrupt. Remove it rather than leave it describing a zip it does not.
[ "$fail" = "0" ] || { rm -f "$DIST/$SUMFILE"; echo "✗ zip ไม่ผ่านการตรวจ"; exit 1; }

# ---- checksum, written HERE: it is a property of the ZIP, not of the manifest ----
# It used to be written further down, after the `--github` early exit and after the refusal for
# a missing download URL — so both of those paths left the PREVIOUS run's SHA256SUMS in place,
# naming this run's zip. Measured on 1.3.0: the file claimed a97f96cd… for a zip that hashes
# to 1f2ca771…. The in-app installer verifies against the MANIFEST's sha256 and so was never
# affected; the person checking a hand-delivered zip is the one this misled.
( cd "$DIST" && shasum -a 256 "$NAME.zip" > "$SUMFILE" )
ZIPSHA="$(shasum -a 256 "$DIST/$NAME.zip" | awk '{print $1}')"

# ---- the .dmg: what a PERSON downloads and drags ----
# Two artifacts from one build, with different readers:
#   .dmg  a human installing for the first time — drag to Applications, familiar, self-explaining
#   .zip  the in-app updater, which stages the bundle and hands it to the swap helper
# `--skip-build` so the image is packaged from the exact bundle the zip above was just verified
# against, rather than from a rebuild — §15 records that zip output is not byte-reproducible, and
# the same is true here: two packagings of one commit are two different files.
echo "→ building the disk image"
if [ "$CREW" = "1" ]; then "$HERE/dmg.sh" --skip-build --with-payload
else "$HERE/dmg.sh" --skip-build; fi
DMGNAME="$NAME.dmg"
[ -f "$DIST/$DMGNAME" ] || { echo "✗ ไม่พบ dist/$DMGNAME หลังสร้าง"; exit 1; }
# Appended to the same SHA256SUMS, so one file describes everything this run produced. dmg.sh
# also writes its own .sha256 for when it is run on its own.
( cd "$DIST" && shasum -a 256 "$DMGNAME" >> "$SUMFILE" )

# ---- publish to GitHub Releases ----
# This is the channel with the fewest moving parts: `gh release create` puts the tag, the notes
# and the zip in one place, and the app reads the release directly — so there is no manifest.json
# to keep in step with the zip, which is the step most likely to be got wrong by hand.
if [ "$GH" = "1" ]; then
  # `gh`, the login, $SLUG and "does v$VERSION already exist" were all settled in the
  # pre-flight above, before anything was built — see the comment there for why that
  # ordering is load-bearing rather than tidy. Re-checked here only because the release
  # could have been created by someone else while this build was running.
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "✗ มี release v$VERSION โผล่ขึ้นมาระหว่างที่ build อยู่ — ไม่ปล่อยทับ"
    exit 1
  fi
  echo "→ gh release create v$VERSION  ($SLUG)"
  # Both assets. The .dmg first so it is the one a person sees at the top of the page; the .zip
  # has to be there too because that is what the in-app updater fetches.
  gh release create "v$VERSION" "$DIST/$DMGNAME" "$DIST/$NAME.zip" \
    --title "IntroPlayer $VERSION" \
    --notes "บิลด์ $COMMIT · $(date +%Y-%m-%d)

**ลงใหม่ / ลงเครื่องใหม่** โหลด \`$DMGNAME\` แล้วลากแอปไปใส่ Applications
**อัปเดตจากเครื่องที่มีอยู่แล้ว** กดอัปเดตในแอปได้เลย ไม่ต้องโหลดอะไร — ไฟล์เพลงและโจทย์ไม่ถูกแตะ

แก้อะไรไปบ้าง — เขียนที่นี่ ข้อความนี้จะไปโผล่ในแถบแจ้งเตือนของทุกเครื่อง" \
    || { echo "✗ gh release create ไม่สำเร็จ"; exit 1; }
  echo "✓ ปล่อยแล้ว: https://github.com/$SLUG/releases/tag/v$VERSION"
  echo
  echo "ขั้นต่อไป:"
  echo "  1. แก้ release notes บน GitHub ให้บอกว่าเวอร์ชั่นนี้เปลี่ยนอะไร"
  echo "     gh release edit v$VERSION --notes '...'"
  echo "  2. ตั้งช่องเช็กเวอร์ชั่นในแอปแต่ละเครื่องเป็น:  $SLUG"
  echo "     (ทำครั้งเดียว หลังจากนั้นทุกเครื่องกด 'อัปเดตเลย' ได้เอง)"
  rm -rf "$STAGE"
  exit 0
fi

# ---- manifest ----
# `ZIPSHA` is computed above, before any early exit. The in-app installer checks it before it
# unpacks anything, which is what catches the realistic failure: a truncated download or a
# half-synced Drive file.
# An empty `download` produces a dead-end banner: the operator is told there is a new version
# and then told to "unzip the file you were given" — a file they have no way to get. Refuse it
# rather than publish it, unless explicitly told there is no URL yet.
if [ -z "$DL" ]; then
  echo "✗ ไม่ได้ใส่ที่อยู่ดาวน์โหลด — แถบแจ้งเตือนจะบอกว่ามีของใหม่แต่ไม่มีทางให้ไปโหลด"
  echo "  ใส่ --download <url หรือ path> หรือ --no-download ถ้ายังไม่มี (manifest จะไม่ถูกเขียน)"
  rm -f "$DIST/manifest.json"
  echo
  echo "✓ dist/$NAME.zip  ($(du -h "$DIST/$NAME.zip" | cut -f1 | tr -d ' '))  — zip พร้อมแจกมือได้เลย"
  exit 1
fi
if [ "$DL" = "-" ]; then
  echo "→ ข้าม manifest.json (--no-download)"
  rm -f "$DIST/manifest.json"
else
cat > "$DIST/manifest.json" <<EOF
{
  "version": "$VERSION",
  "notes": "",
  "download": "$DL",
  "minMacOS": "13.0",
  "sha256": "$ZIPSHA",
  "commit": "$COMMIT",
  "released": "$(date +%Y-%m-%d)"
}
EOF
fi

rm -rf "$STAGE"
SIZE="$(du -h "$DIST/$NAME.zip" | cut -f1 | tr -d ' ')"
echo
echo "✓ dist/$NAME.zip  ($SIZE)   — ตัวที่แอปโหลดเองตอนกดอัปเดต"
echo "✓ dist/$DMGNAME  ($(du -h "$DIST/$DMGNAME" | cut -f1 | tr -d ' '))   — ตัวที่คนโหลดไปลากลง Applications"
if [ -f "$DIST/manifest.json" ]; then echo "✓ dist/manifest.json"; fi
echo
echo "ขั้นต่อไป:"
if [ "$DL" = "-" ]; then
  echo "  • ยังไม่มี manifest.json — แจกไฟล์ zip มือได้เลย"
  echo "    พอมีที่วางไฟล์แล้ว รันใหม่ด้วย --download <url หรือ path> เพื่อให้แอปเช็กเองได้"
else
  echo "  1. แก้ \"notes\" ใน dist/manifest.json ให้บอกว่าเวอร์ชั่นนี้เปลี่ยนอะไร"
  echo "     (ข้อความนี้จะไปโผล่ในแถบแจ้งเตือนของทุกเครื่อง)"
  echo "  2. วาง zip ไว้ที่ $DL"
  echo "  3. วาง manifest.json ไว้ที่ feed ที่ตั้งไว้ในแอป — ปกติคือโฟลเดอร์เดียวกับ zip (ดู §15)"
fi
