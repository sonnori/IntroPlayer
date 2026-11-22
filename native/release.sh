#!/bin/bash
# Packages a release for the crew: one zip anyone can double-click into place.
#
#   ./native/release.sh                      build + package the version in ./VERSION
#   ./native/release.sh --skip-build         package the app bundle as it already stands
#   ./native/release.sh --allow-dirty        package from a tree with uncommitted edits
#   ./native/release.sh --download <url>     put a download URL in the generated manifest.json
#   ./native/release.sh --github             publish to GitHub Releases with `gh` (no manifest
#                                            needed — the app reads the release itself)
#
# Output in dist/:
#   IntroPlayer-<ver>.zip   what you hand over / upload
#   manifest.json           what the app's update check reads (upload it NEXT TO the zip)
#   SHA256SUMS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

SKIP_BUILD=0
ALLOW_DIRTY=0
DL=""
GH=0
while [ $# -gt 0 ]; do
  case "$1" in
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

if [ "$SKIP_BUILD" = "0" ]; then
  "$HERE/build.sh" release
fi

# One source of truth for the bundle name: the installer. If these two ever disagreed the zip
# would carry a bundle the installer does not install.
APPBUNDLE="$(sed -n 's/^APPBUNDLE="\(.*\)"$/\1/p' "$HERE/installer.command" | head -1)"
[ -n "$APPBUNDLE" ] || { echo "✗ อ่าน APPBUNDLE จาก installer.command ไม่ได้"; exit 1; }
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
NAME="IntroPlayer-$VERSION"
STAGE="$DIST/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# Cleaned on EVERY exit, not just the two success paths. A `--github` run that stops at
# `gh auth status`, or any run that refuses for a missing download URL, used to leave the
# unpacked staging tree sitting in dist/ — and that tree looks exactly like an install
# folder. §15 step 3 means the installer would refuse to aim at it (it carries the release
# markers), but it is still a thing a human can mistake for the real folder and copy into.
trap 'rm -rf "$STAGE"' EXIT

# The program, and only the program. config.json / log.json / songs/ are the operator's and are
# never in a release — that split is the whole reason an update can be safe (§5b, §15).
SHIP=(
"$APPBUNDLE"
IntroPlayer.app
server.py
index.html
วิธีใช้งาน-SETUP.md
ตรวจสอบเครื่อง.command
start.command
VERSION
)

# release.sh decides what SHIPS and installer.command decides what LANDS. A file in one list and
# not the other goes stale in place — a new app next to the previous release's diagnostic script,
# which is worse than shipping neither. This was a real miss, so it is a check, not a comment.
#
# Parsed ONE ENTRY PER LINE. The previous version flattened the declaration with `tr '\n' ' '`
# and split it on whitespace, which "RGF Intro Player.app" would have turned into three
# filenames — and this check would then have compared nonsense to nonsense and passed.
read_decl() {
  sed -n "/^$1=(/,/^)/p" "$HERE/installer.command" \
    | sed -e '1d' -e '$d' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' \
    | grep -v '^#' | grep -v '^$'
}
LANDS=(); while IFS= read -r l; do LANDS+=("$l"); done < <(read_decl PROGRAM)
if [ "${#LANDS[@]}" -eq 0 ]; then echo "✗ อ่าน PROGRAM[] จาก installer.command ไม่ได้"; exit 1; fi
if [ "$(printf '%s\n' "${SHIP[@]}" | sort)" != "$(printf '%s\n' "${LANDS[@]}" | sort)" ]; then
  echo "✗ รายการไฟล์ของ release.sh กับ installer.command ไม่ตรงกัน"
  echo "  ships: $(printf '%s ' "${SHIP[@]}")"
  echo "  lands: $(printf '%s ' "${LANDS[@]}")"
  echo "  diff:"
  diff <(printf '%s\n' "${SHIP[@]}" | sort) <(printf '%s\n' "${LANDS[@]}" | sort) | sed 's/^/    /'
  exit 1
fi

# SEED[] too: it was hardcoded here as `cp -R "$ROOT/se"`, so adding an entry to the installer's
# SEED[] would have shipped nothing and the seed would silently never arrive.
SEEDS=(); while IFS= read -r l; do SEEDS+=("$l"); done < <(read_decl SEED)
if [ "${#SEEDS[@]}" -eq 0 ]; then echo "✗ อ่าน SEED[] จาก installer.command ไม่ได้"; exit 1; fi

echo "→ staging $NAME"
for item in "${SHIP[@]}"; do
  [ -e "$ROOT/$item" ] || { echo "  ⚠ ข้าม $item (ไม่มีในโปรเจกต์)"; continue; }
  cp -R "$ROOT/$item" "$STAGE/$item"
done
for item in "${SEEDS[@]}"; do
  [ -e "$ROOT/$item" ] || { echo "✗ SEED '$item' ไม่มีในโปรเจกต์"; exit 1; }
  cp -R "$ROOT/$item" "$STAGE/$item"
done
# A release must be reproducible from the public repo, so it ships exactly what the repo holds.
# Without this the stings would reach the public GitHub release from the maintainer's own disk —
# the one place excluding them from git does not cover. Remove this block together with the two
# .gitignore lines if their licence is ever confirmed.
rm -f "$STAGE/se/correct.mp3" "$STAGE/se/wrong.mp3"
if [ ! -f "$STAGE/se/correct.mp3" ] || [ ! -f "$STAGE/se/wrong.mp3" ]; then
  echo "  ⚠ se/ ไม่มีไฟล์เสียง — ชุดนี้จะไม่มีเสียงตอบถูก/ผิด"
  echo "    (ปกติ — บรรทัดข้างบนลบออกเองทุกครั้ง เพราะ licence ยังไม่ชัด)"
  echo "    คนที่ลงใหม่ต้องวาง correct.mp3 / wrong.mp3 ใน se/ เอง (มีวิธีใน se/README.txt)"
fi
cp "$HERE/installer.command" "$STAGE/ติดตั้ง-อัปเดต.command"
chmod +x "$STAGE/ติดตั้ง-อัปเดต.command" "$STAGE/ตรวจสอบเครื่อง.command" 2>/dev/null || true

# A release is made on this machine and opened on another, so strip this machine's quarantine
# and resource forks rather than shipping them.
xattr -cr "$STAGE" 2>/dev/null || true

# Read the commit back OUT of the bundle rather than recomputing it. build.sh appends `+dirty`
# when the tree is not clean, and recomputing here silently dropped that: the published
# manifest.json asserted a clean sha for a binary that was not that commit — in the one
# machine-readable artifact that outlives the conversation.
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :RGFGitCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
[ -n "$COMMIT" ] || COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo "-")"
cat > "$STAGE/อ่านก่อน.txt" <<EOF
RGF Intro Player $VERSION   ($COMMIT, $(date +%Y-%m-%d))
=========================================================

วิธีที่ง่ายที่สุด: ไม่ต้องใช้ไฟล์นี้เลย
--------------------------------------
ถ้าเครื่องนั้นตั้งที่อยู่สำหรับเช็กเวอร์ชั่นไว้แล้ว ให้เปิดแอปแล้วกด "อัปเดตเลย"
บนแถบฟ้าด้านบน แอปจะโหลด ตรวจไฟล์ ปิดตัวเอง สลับตัวโปรแกรม แล้วเปิดใหม่ให้เอง
-- และทางนั้นไม่ติด Gatekeeper ไม่ต้องคลิกขวา Open

ด้านล่างคือวิธีทำมือ ใช้เมื่อกดปุ่มในแอปไม่ได้ หรือได้ไฟล์มาทางอื่น

ติดตั้ง / อัปเดต (ทำมือ)
------------------------
1. ปิดแอปก่อน ถ้ากำลังเปิดอยู่ (Cmd+Q)   ** ห้ามอัปเดตตอนกำลังถ่าย **
2. ดับเบิลคลิก   ติดตั้ง-อัปเดต.command
3. ถ้า macOS เตือนว่า "เปิดไม่ได้ / ไม่รู้จักผู้พัฒนา"
   -> คลิกขวาที่ไฟล์ > Open > กด Open อีกครั้ง
   -> ถ้ายังไม่ได้: System Settings > Privacy & Security > กด "Open Anyway"
   ** ขั้นนี้ต้องทำใหม่ทุกครั้งที่ดาวน์โหลดไฟล์ชุดใหม่ ไม่ใช่ครั้งเดียวจบ **
   (ถ้ารับไฟล์ผ่านโฟลเดอร์ที่ sync ไว้แทนการดาวน์โหลด จะไม่ติดธงนี้เลย)
4. ตัวติดตั้งจะถามว่าจะลงที่โฟลเดอร์ไหน ถ้าเคยใช้แล้วมันจะหาให้เอง
   -> ดูให้ชัวร์ว่า path ที่มันบอกคือโฟลเดอร์จริงของคุณ แล้วกด "อัปเดต"
5. เปิดแอป แล้วดูเลขเวอร์ชั่นในแถบหัวรายชื่อเพลง (ถัดจากปุ่ม ⟳) ต้องขึ้น v$VERSION

สิ่งที่ "ไม่" ถูกแตะเลย
----------------------
  config.json   โจทย์ที่ตั้งไว้ (จุด intro / hook / ระดับเสียง)
  log.json      log การถ่าย
  songs/        ไฟล์เพลงทั้งหมด

ตัวติดตั้งเปลี่ยนแค่ตัวโปรแกรม และก่อนเปลี่ยนจะคัดลอก config.json กับ log.json
เก็บไว้ใน  backups/<วันเวลา>/  พร้อมแอปตัวเก่า เผื่อต้องย้อนกลับ

ถ้ามีปัญหา
----------
ดับเบิลคลิก  ตรวจสอบเครื่อง.command  แล้วถ่ายรูปหน้าจอส่งมา
(มันจะบอกเวอร์ชั่น สิทธิ์ไฟล์ และ error ล่าสุดให้ครบในหน้าเดียว)

วิธีใช้งานทั้งหมดอยู่ใน  วิธีใช้งาน-SETUP.md
EOF

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
check "ติดตั้ง-อัปเดต.command ยัง executable" '[ -x "$U/ติดตั้ง-อัปเดต.command" ]'
check "ตรวจสอบเครื่อง.command ยัง executable" '[ -x "$U/ตรวจสอบเครื่อง.command" ]'
check "แอป executable ยังรันได้"               '[ -x "$U/$APPBUNDLE/Contents/MacOS/IntroPlayerNative" ]'
check "web launcher ยัง executable"            '[ -x "$U/IntroPlayer.app/Contents/MacOS/IntroPlayer" ]'
check "ไม่มี config.json ติดไปด้วย"             '[ ! -e "$U/config.json" ]'
check "ไม่มี log.json ติดไปด้วย"                '[ ! -e "$U/log.json" ]'
check "ไม่มี songs/ ติดไปด้วย"                  '[ ! -e "$U/songs" ]'
# The folder and its instructions, not the audio: the stings are not redistributed (see
# .gitignore), so asserting they are present would make every release fail by design.
check "se/ มีโฟลเดอร์ + คำอธิบาย"                '[ -f "$U/se/README.txt" ]'
check "ไม่มีไฟล์เสียงที่ไม่รู้ licence ติดไปด้วย"  '[ ! -f "$U/se/correct.mp3" ] && [ ! -f "$U/se/wrong.mp3" ]'
ARCHS="$(lipo -archs "$U/$APPBUNDLE/Contents/MacOS/IntroPlayerNative" 2>/dev/null || echo "")"
check "universal (arm64 + x86_64) — arch: $ARCHS" '[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]'
# The strongest check available: ask the unzipped binary what it is.
GOT="$("$U/$APPBUNDLE/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 || echo "")"
check "แอปที่แตกออกมารายงานเวอร์ชั่น $VERSION — ได้: ${GOT:-ไม่ตอบ}" '[[ "$GOT" == "$VERSION"* ]]'
# A stale SHA256SUMS beside a zip is worse than none: it names the file sitting next to it,
# so whoever hands the zip over by hand checks it, gets a mismatch, and concludes a perfectly
# good release is corrupt. Remove it rather than leave it describing a zip it does not.
[ "$fail" = "0" ] || { rm -f "$DIST/SHA256SUMS"; echo "✗ zip ไม่ผ่านการตรวจ"; exit 1; }

# ---- checksum, written HERE: it is a property of the ZIP, not of the manifest ----
# It used to be written further down, after the `--github` early exit and after the refusal for
# a missing download URL — so both of those paths left the PREVIOUS run's SHA256SUMS in place,
# naming this run's zip. Measured on 1.3.0: the file claimed a97f96cd… for a zip that hashes
# to 1f2ca771…. The in-app installer verifies against the MANIFEST's sha256 and so was never
# affected; the person checking a hand-delivered zip is the one this misled.
( cd "$DIST" && shasum -a 256 "$NAME.zip" > SHA256SUMS )
ZIPSHA="$(shasum -a 256 "$DIST/$NAME.zip" | awk '{print $1}')"

# ---- publish to GitHub Releases ----
# This is the channel with the fewest moving parts: `gh release create` puts the tag, the notes
# and the zip in one place, and the app reads the release directly — so there is no manifest.json
# to keep in step with the zip, which is the step most likely to be got wrong by hand.
if [ "$GH" = "1" ]; then
  command -v gh >/dev/null 2>&1 || { echo "✗ ไม่มีคำสั่ง gh — ติดตั้ง GitHub CLI ก่อน"; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "✗ gh ยังไม่ได้ login — รัน: gh auth login"; exit 1; }
  SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")"
  [ -n "$SLUG" ] || { echo "✗ โฟลเดอร์นี้ยังไม่ได้ผูกกับ repo บน GitHub"; exit 1; }
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "✗ มี release v$VERSION อยู่แล้วบน $SLUG"
    echo "  ถ้าจะปล่อยซ้ำ ให้ลบอันเก่าก่อน: gh release delete v$VERSION"
    exit 1
  fi
  echo "→ gh release create v$VERSION  ($SLUG)"
  gh release create "v$VERSION" "$DIST/$NAME.zip" \
    --title "IntroPlayer $VERSION" \
    --notes "บิลด์ $COMMIT · $(date +%Y-%m-%d)

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
echo "✓ dist/$NAME.zip  ($SIZE)"
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
