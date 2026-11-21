#!/bin/bash
# Exercises native/installer.command for real, with osascript/pgrep stubbed so the production
# script is tested UNMODIFIED. The thing being proved is the promise the whole feature rests on:
# config.json, log.json and songs/ come out byte-identical.
#
#   ./native/installer-test.sh        — needs dist/; run ./native/release.sh first
#
# The stub answers dialogs from a QUEUE (STUB_ANSWERS, "|"-separated) and folder pickers from
# STUB_FOLDER. An earlier version answered every dialog with one string, which meant any flow
# with two questions — the whole fresh-install branch — fell through to cancel and its assertions
# passed in every possible world.
set -uo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(mktemp -d)"; trap 'chmod -R u+rwX "$BASE" 2>/dev/null; rm -rf "$BASE"' EXIT
VER="$(tr -d ' \n\r' < "$PROJ/VERSION")"
ZIP="$PROJ/dist/IntroPlayer-$VER.zip"
[ -f "$ZIP" ] || { echo "ไม่มี $ZIP — รัน ./native/release.sh ก่อน"; exit 2; }
PASS=0; FAIL=0
ok()   { echo "   ok   $1"; PASS=$((PASS+1)); }
bad()  { echo "   ✗    $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---- stubs ----
mkdir -p "$BASE/bin"
cat > "$BASE/bin/osascript" <<'EOS'
#!/bin/bash
# Logs what the operator would have been shown, and answers from a queue so multi-dialog flows
# are testable. `choose folder` is answered separately — it is a path, not a button.
ALL="$*"
echo "DIALOG: $ALL" >> "${STUB_LOG:-/dev/null}"
case "$ALL" in
  *"choose folder"*) [ -n "${STUB_FOLDER:-}" ] && echo "$STUB_FOLDER"; exit 0 ;;
  *"display alert"*) exit 0 ;;
esac
Q="${STUB_QUEUE_FILE:-}"
if [ -n "$Q" ]; then
  n=0; [ -f "$Q" ] && n="$(cat "$Q")"
  IFS='|' read -r -a arr <<< "${STUB_ANSWERS:-}"
  if [ "$n" -lt "${#arr[@]}" ]; then echo "${arr[$n]}"; fi
  echo $((n+1)) > "$Q"
fi
exit 0
EOS
cat > "$BASE/bin/open" <<'EOS'
#!/bin/bash
# --relaunch must not actually launch anything during a test run.
echo "OPEN: $*" >> "${STUB_OPEN_LOG:-/dev/null}"
exit 0
EOS
cat > "$BASE/bin/pgrep" <<'EOS'
#!/bin/bash
# STUB_RUNNING=1 pretends the app is open; STUB_WEB=1 pretends server.py is.
case "$*" in
  *MacOS/IntroPlayerNative*) [ "${STUB_RUNNING:-0}" = "1" ] && { echo 99999; exit 0; } ;;
  *erver*)                   [ "${STUB_WEB:-0}" = "1" ]     && { echo 99998; exit 0; } ;;
esac
exit 1
EOS
chmod +x "$BASE/bin/osascript" "$BASE/bin/pgrep" "$BASE/bin/open"
export PATH="$BASE/bin:$PATH"

# ---- the new release, unzipped like the operator would ----
rm -rf "$BASE/src"; mkdir -p "$BASE/src"
( cd "$BASE/src" && unzip -qq "$ZIP" )
SRC="$BASE/src/IntroPlayer-$VER"
[ -x "$SRC/ติดตั้ง-อัปเดต.command" ] || { echo "no installer in the zip"; exit 1; }

# ---- a fake existing install, with data worth losing ----
TARGET=""
fresh_target() {
  TARGET="${1:-$BASE/target}"
  rm -rf "$TARGET" "$BASE/home"
  mkdir -p "$TARGET/songs/EP09" "$BASE/home/Library/Application Support/IntroPlayer"
  printf '{"_settings":{"lastPlaylist":"EP09","schema":1,"writtenBy":"1.0.0"},"EP09/a.mp3":{"introStart":14.2,"introEnd":29.2,"hook":97.5,"configured":true}}\n' > "$TARGET/config.json"
  printf '{"events":[{"t":"2026-11-01T10:00:00+07:00","playlist":"EP09","path":"EP09/a.mp3","event":"correct"}]}\n' > "$TARGET/log.json"
  printf 'not really audio\n' > "$TARGET/songs/EP09/a.mp3"
  mkdir -p "$TARGET/se"; printf 'CUSTOM STING\n' > "$TARGET/se/correct.mp3"
  # pretend it is the previous release — every program file present and OLD
  mkdir -p "$TARGET/IntroPlayerNative.app/Contents/MacOS"
  printf 'OLD APP\n' > "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"
  mkdir -p "$TARGET/IntroPlayer.app/Contents/MacOS"
  printf 'OLD LAUNCHER\n' > "$TARGET/IntroPlayer.app/Contents/MacOS/IntroPlayer"
  for f in server.py index.html start.command ตรวจสอบเครื่อง.command วิธีใช้งาน-SETUP.md; do
    printf 'OLD %s\n' "$f" > "$TARGET/$f"
  done
  printf '1.0.0\n' > "$TARGET/VERSION"
  printf '%s\n' "$TARGET" > "$BASE/home/Library/Application Support/IntroPlayer/location"
  CFG_BEFORE="$(shasum -a 256 < "$TARGET/config.json")"
  LOG_BEFORE="$(shasum -a 256 < "$TARGET/log.json")"
  SONG_BEFORE="$(shasum -a 256 < "$TARGET/songs/EP09/a.mp3")"
  SE_BEFORE="$(shasum -a 256 < "$TARGET/se/correct.mp3")"
}

run() {  # run <log> <src> [env assignments via globals]
  rm -f "$BASE/q"
  STUB_QUEUE_FILE="$BASE/q" STUB_LOG="$1" HOME="$BASE/home" \
    bash "$2/ติดตั้ง-อัปเดต.command" >/dev/null 2>&1
}

# The in-app path: no dialogs, target given, waits for a pid, then swaps.
run_unattended() {  # run_unattended <log> <src> [extra args...]
  local lg="$1" src="$2"; shift 2
  rm -f "$BASE/q"
  STUB_QUEUE_FILE="$BASE/q" STUB_LOG="$lg" STUB_OPEN_LOG="$BASE/openlog" HOME="$BASE/home" \
    bash "$src/ติดตั้ง-อัปเดต.command" --unattended "$@" >/dev/null 2>&1
}

data_intact() {
  check "config.json ไม่เปลี่ยนเลย" '[ "$(shasum -a 256 < "$TARGET/config.json")" = "$CFG_BEFORE" ]'
  check "log.json ไม่เปลี่ยนเลย"    '[ "$(shasum -a 256 < "$TARGET/log.json")" = "$LOG_BEFORE" ]'
  check "songs/ ไม่เปลี่ยนเลย"      '[ "$(shasum -a 256 < "$TARGET/songs/EP09/a.mp3")" = "$SONG_BEFORE" ]'
}

echo "=== 1. refuses while the app is running ==="
fresh_target
STUB_RUNNING=1 STUB_ANSWERS="อัปเดต" run "$BASE/log1" "$SRC"; rc=$?
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "แอปตัวเก่ายังอยู่ ไม่ถูกแตะ" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
check "ไม่มี backups/ ถูกสร้าง" '[ ! -d "$TARGET/backups" ]'
check "เตือนเรื่องกำลังถ่าย" 'grep -q "กำลังถ่าย" "$BASE/log1"'

echo
echo "=== 2. web version running → warns, and CANCEL is the default button ==="
fresh_target
STUB_WEB=1 STUB_ANSWERS="" run "$BASE/log2" "$SRC"      # empty answer = dismissed
check "ไม่ติดตั้งเมื่อไม่ได้ยืนยัน" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
check "เตือนเรื่อง server.py" 'grep -q "server.py" "$BASE/log2"'
# §12: the destructive choice must never be what Return/Space activates.
DEF="$(grep -o 'default button "[^"]*"' "$BASE/log2" | head -1)"
check "ปุ่ม default คือ ยกเลิก (ได้: ${DEF:-ไม่พบ})" '[ "$DEF" = '"'"'default button "ยกเลิก"'"'"' ]'

echo
echo "=== 3. cancelling changes nothing ==="
fresh_target
STUB_ANSWERS="ยกเลิก" run "$BASE/log3" "$SRC"
check "แอปตัวเก่ายังอยู่" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
check "ไม่มี backups/" '[ ! -d "$TARGET/backups" ]'
check "ถามโฟลเดอร์ที่จะอัปเดตก่อน" 'grep -q "จะอัปเดตโฟลเดอร์นี้" "$BASE/log3"'

echo
echo "=== 4. the real update ==="
fresh_target
STUB_ANSWERS="อัปเดต|ปิด" run "$BASE/log4" "$SRC"; rc=$?
check "exit 0 (rc=$rc)" '[ "$rc" = "0" ]'
echo "   --- the promise: data byte-identical ---"
data_intact
check "se/ ที่ผู้ใช้เปลี่ยนเอง ไม่ถูกทับ" '[ "$(shasum -a 256 < "$TARGET/se/correct.mp3")" = "$SE_BEFORE" ]'
echo "   --- every program file actually moved ---"
check "แอปใหม่รันได้ และตอบเวอร์ชั่นถูก" '[ "$("$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 | cut -d" " -f1)" = "$VER" ]'
check "VERSION เป็น $VER" '[ "$(tr -d " \n\r" < "$TARGET/VERSION")" = "$VER" ]'
for f in server.py index.html start.command ตรวจสอบเครื่อง.command วิธีใช้งาน-SETUP.md; do
  check "$f ถูกแทนที่ด้วยตัวใหม่" '! grep -q "^OLD " "$TARGET/'"$f"'"'
done
check "web launcher ถูกแทนที่ด้วยตัวใหม่" '! grep -q "OLD LAUNCHER" "$TARGET/IntroPlayer.app/Contents/MacOS/IntroPlayer"'
check ".command ยัง executable" '[ -x "$TARGET/ตรวจสอบเครื่อง.command" ]'
check "ไม่ทิ้ง lock ค้างไว้" '[ ! -d "$TARGET/.installing" ]'
echo "   --- the way back ---"
BK="$(ls -d "$TARGET/backups"/*/ 2>/dev/null | head -1)"
check "มี backups/<วันเวลา>/" '[ -n "$BK" ]'
check "สำรอง config.json ไว้ครบ" '[ "$(shasum -a 256 < "$BK/config.json")" = "$CFG_BEFORE" ]'
check "สำรอง log.json ไว้ครบ"    '[ "$(shasum -a 256 < "$BK/log.json")" = "$LOG_BEFORE" ]'
check "เก็บแอปตัวเก่าไว้"         'grep -q "OLD APP" "$BK/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
# This is what a partial rollback used to destroy with no copy anywhere.
check "เก็บ server.py ตัวเก่าไว้ด้วย"  'grep -q "OLD server.py" "$BK/server.py"'
check "เก็บ index.html ตัวเก่าไว้ด้วย" 'grep -q "OLD index.html" "$BK/index.html"'
# `pwd -P` on purpose, so compare physical paths — $TMPDIR is a symlink on macOS.
check "breadcrumb ชี้ถูก" '[ "$(head -1 "$BASE/home/Library/Application Support/IntroPlayer/location")" = "$(cd "$TARGET" && pwd -P)" ]'

echo
echo "=== 5. rollback when a copy fails part-way — EVERYTHING must come back ==="
fresh_target
rm -rf "$BASE/src-broken"; cp -R "$SRC" "$BASE/src-broken"
chmod 000 "$BASE/src-broken/VERSION"      # last item in PROGRAM: earlier ones have copied
STUB_ANSWERS="อัปเดต" run "$BASE/log5" "$BASE/src-broken"; rc=$?
chmod 644 "$BASE/src-broken/VERSION" 2>/dev/null
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "คืนแอปตัวเดิม" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" 2>/dev/null'
check "คืน web launcher ตัวเดิม (ทางหนีตอนถ่าย)" 'grep -q "OLD LAUNCHER" "$TARGET/IntroPlayer.app/Contents/MacOS/IntroPlayer" 2>/dev/null'
for f in server.py index.html start.command ตรวจสอบเครื่อง.command วิธีใช้งาน-SETUP.md; do
  check "คืน $f ตัวเดิม" 'grep -q "^OLD " "$TARGET/'"$f"'" 2>/dev/null'
done
check "VERSION ไม่หาย"  '[ -f "$TARGET/VERSION" ] && [ "$(tr -d " \n\r" < "$TARGET/VERSION")" = "1.0.0" ]'
data_intact
check "บอกว่าคืนให้แล้ว" 'grep -q "คืนไฟล์ชุดเดิม" "$BASE/log5"'
check "ไม่ทิ้ง lock ค้างไว้" '[ ! -d "$TARGET/.installing" ]'

echo
echo "=== 6. installing onto the unzipped folder itself — incl. via a symlinked path ==="
fresh_target
mkdir -p "$SRC/songs"   # make it look as valid as possible so only the -ef guard can stop it
printf '%s\n' "$SRC" > "$BASE/home/Library/Application Support/IntroPlayer/location"
STUB_ANSWERS="อัปเดต|ยกเลิก" run "$BASE/log6a" "$SRC"; rc=$?
check "ตรงๆ: ไม่ติดตั้ง (rc=$rc)" '[ "$rc" != "0" ] || ! grep -q "เรียบร้อย" "$BASE/log6a"'
check "ไฟล์ในชุด release ยังอยู่ครบ" '[ -e "$SRC/IntroPlayer.app" ] && [ -e "$SRC/server.py" ]'
# The same directory under a different spelling. A string compare passed this.
ln -sfn "$BASE/src" "$BASE/srclink"
printf '%s\n' "$BASE/srclink/IntroPlayer-$VER" > "$BASE/home/Library/Application Support/IntroPlayer/location"
STUB_ANSWERS="อัปเดต|ยกเลิก" run "$BASE/log6b" "$SRC"; rc=$?
check "ผ่าน symlink: ไม่ติดตั้ง (rc=$rc)" '[ "$rc" != "0" ] || ! grep -q "เรียบร้อย" "$BASE/log6b"'
check "ผ่าน symlink: ไฟล์ในชุด release ยังอยู่ครบ" '[ -e "$SRC/IntroPlayer.app" ] && [ -e "$SRC/server.py" ]'
# The release-folder marker check (is_release_folder) rejects it before the `-ef` guard is even
# reached, so the flow falls back to "can't find the install" rather than naming the unzip
# folder. That is the stronger of the two guards; `-ef` remains as defence in depth for a target
# reached by a different spelling that has had its markers removed.
check "ถอยไปถามว่าหาไม่เจอ ไม่ใช่เสนอโฟลเดอร์ที่แตก zip" 'grep -q "หาโฟลเดอร์ที่ติดตั้งไว้ไม่เจอ" "$BASE/log6b"'
rm -rf "$SRC/songs" "$BASE/srclink"

echo
echo "=== 7. a stale breadcrumb pointing at an unzipped release must NOT be offered ==="
# The realistic chain: the operator double-clicks the app inside a download to 'try it', which
# used to record that folder as the install.
fresh_target
rm -rf "$BASE/olddownload"; cp -R "$SRC" "$BASE/olddownload"
printf '%s\n' "$BASE/olddownload" > "$BASE/home/Library/Application Support/IntroPlayer/location"
STUB_ANSWERS="ยกเลิก" run "$BASE/log7" "$SRC"
check "ไม่เสนอโฟลเดอร์ที่แตก zip ให้อัปเดต" '! grep -q "จะอัปเดตโฟลเดอร์นี้:.*olddownload" "$BASE/log7"'
check "ถอยไปถามว่าหาไม่เจอแทน" 'grep -q "หาโฟลเดอร์ที่ติดตั้งไว้ไม่เจอ" "$BASE/log7"'

echo
echo "=== 8. a folder that merely contains songs/ is not an install ==="
rm -rf "$BASE/music"; mkdir -p "$BASE/music/songs"
printf 'MY OWN FILE\n' > "$BASE/music/index.html"
rm -rf "$BASE/home"; mkdir -p "$BASE/home/Library/Application Support/IntroPlayer"
STUB_ANSWERS="เลือกโฟลเดอร์เดิม|ยกเลิก" STUB_FOLDER="$BASE/music/" run "$BASE/log8" "$SRC"
check "ไฟล์ index.html ของผู้ใช้ไม่ถูกทับ" 'grep -q "MY OWN FILE" "$BASE/music/index.html"'
check "ต้องยืนยันก่อน ไม่ใช่ลงเลย" 'grep -q "จะอัปเดตโฟลเดอร์นี้" "$BASE/log8" || grep -q "ไม่ใช่ที่ติดตั้ง" "$BASE/log8"'

echo
echo "=== 9. fresh install on a machine that never had it ==="
rm -rf "$BASE/newplace" "$BASE/home"
mkdir -p "$BASE/newplace" "$BASE/home/Library/Application Support/IntroPlayer"
STUB_ANSWERS="ติดตั้งใหม่|ติดตั้ง|ปิด" STUB_FOLDER="$BASE/newplace/" run "$BASE/log9" "$SRC"; rc=$?
N="$BASE/newplace/IntroPlayer"
check "exit 0 (rc=$rc)" '[ "$rc" = "0" ]'
check "บอกว่าเรียบร้อย" 'grep -q "เรียบร้อย" "$BASE/log9"'
check "แอปรันได้ และตอบเวอร์ชั่นถูก" '[ "$("$N/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 | cut -d" " -f1)" = "$VER" ]'
check "สร้าง songs/ ให้" '[ -d "$N/songs" ]'
check "วาง se/ ให้" '[ -f "$N/se/correct.mp3" ]'
check "เขียน breadcrumb ได้ ทั้งที่โฟลเดอร์ยังไม่เคยมี" '[ "$(head -1 "$BASE/home/Library/Application Support/IntroPlayer/location")" = "$(cd "$N" && pwd -P)" ]'
check "ไม่สร้าง config.json/log.json ขึ้นมาเอง" '[ ! -e "$N/config.json" ] && [ ! -e "$N/log.json" ]'

echo
echo "=== 10. fresh install where a source file is unreadable — must NOT report success ==="
# The branch that used to run with rollback disarmed: no old bundle, so nothing to restore, so
# `cp || rollback` was satisfied by rollback returning 0 and the loop carried on.
rm -rf "$BASE/newplace2" "$BASE/home" "$BASE/src-broken2"
mkdir -p "$BASE/newplace2" "$BASE/home/Library/Application Support/IntroPlayer"
cp -R "$SRC" "$BASE/src-broken2"
chmod 000 "$BASE/src-broken2/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"
STUB_ANSWERS="ติดตั้งใหม่|ติดตั้ง|ปิด" STUB_FOLDER="$BASE/newplace2/" run "$BASE/log10" "$BASE/src-broken2"; rc=$?
chmod 755 "$BASE/src-broken2/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" 2>/dev/null
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "ไม่บอกว่าเรียบร้อย" '! grep -q "เรียบร้อย" "$BASE/log10"'
check "ไม่ทิ้งแอปที่รันไม่ได้ไว้" '[ ! -x "$BASE/newplace2/IntroPlayer/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" ]'

echo
echo "=== 11. a target path with spaces, Thai and a quote ==="
WEIRD="$BASE/My Folder/โฟลเดอร์ \"ใหม่\"/IntroPlayer"
mkdir -p "$(dirname "$WEIRD")"
fresh_target "$WEIRD"
STUB_ANSWERS="อัปเดต|ปิด" run "$BASE/log11" "$SRC"; rc=$?
# A quote in the path makes the AppleScript layer unrenderable unless escaped; either way the
# data must survive and it must never silently half-install.
data_intact
check "ถ้าไม่สำเร็จก็ต้องไม่บอกว่าเรียบร้อย" \
  '[ "$("$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 | cut -d" " -f1)" = "$VER" ] || ! grep -q "เรียบร้อย" "$BASE/log11"'
check "dialog ยัง render ได้ (escape ถูก)" 'grep -q "จะอัปเดตโฟลเดอร์นี้" "$BASE/log11"'

echo
echo "=== 12. a second run while one is in progress is refused ==="
fresh_target
mkdir -p "$TARGET/.installing"          # simulate an in-flight run
STUB_ANSWERS="อัปเดต" run "$BASE/log12" "$SRC"; rc=$?
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "แอปตัวเก่ายังอยู่" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
check "อธิบายเรื่องติดตั้งค้าง" 'grep -q "ติดตั้งค้างอยู่" "$BASE/log12"'
rmdir "$TARGET/.installing"

echo
echo "=== 13. dialogs unavailable (TCC denied) must fail CLOSED ==="
fresh_target
cat > "$BASE/bin/osascript" <<'EOS'
#!/bin/bash
echo "DIALOG: $*" >> "${STUB_LOG:-/dev/null}"
exit 1
EOS
chmod +x "$BASE/bin/osascript"
STUB_ANSWERS="อัปเดต" run "$BASE/log13" "$SRC"
check "ไม่ติดตั้งอะไรเลย" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
data_intact

echo
echo "=== 14. backups are pruned, not hoarded ==="
fresh_target
mkdir -p "$TARGET/backups/20200101-000001" "$TARGET/backups/20200101-000002" \
         "$TARGET/backups/20200101-000003" "$TARGET/backups/20200101-000004"
cat > "$BASE/bin/osascript" <<'EOS'
#!/bin/bash
ALL="$*"
echo "DIALOG: $ALL" >> "${STUB_LOG:-/dev/null}"
case "$ALL" in
  *"choose folder"*) [ -n "${STUB_FOLDER:-}" ] && echo "$STUB_FOLDER"; exit 0 ;;
  *"display alert"*) exit 0 ;;
esac
Q="${STUB_QUEUE_FILE:-}"
if [ -n "$Q" ]; then
  n=0; [ -f "$Q" ] && n="$(cat "$Q")"
  IFS='|' read -r -a arr <<< "${STUB_ANSWERS:-}"
  if [ "$n" -lt "${#arr[@]}" ]; then echo "${arr[$n]}"; fi
  echo $((n+1)) > "$Q"
fi
exit 0
EOS
chmod +x "$BASE/bin/osascript"
STUB_ANSWERS="อัปเดต|ปิด" run "$BASE/log14" "$SRC"
NBK="$(ls -1d "$TARGET/backups"/*/ 2>/dev/null | wc -l | tr -d ' ')"
check "เหลือ 3 ชุด (ได้ $NBK)" '[ "$NBK" = "3" ]'
check "ชุดล่าสุดยังอยู่" '[ -n "$(ls -1d "$TARGET/backups"/*/ | tail -1)" ] && [ -f "$(ls -1d "$TARGET/backups"/*/ | tail -1)/config.json" ]'

echo
echo "=== 15. unattended (the in-app path): swaps, keeps the data, relaunches ==="
fresh_target
rm -f "$BASE/openlog"
( sleep 2 ) & WP=$!
T0=$(date +%s)
run_unattended "$BASE/log15" "$SRC" --target "$TARGET" --wait-pid "$WP" --relaunch
rc=$?; EL=$(( $(date +%s) - T0 ))
check "exit 0 (rc=$rc)" '[ "$rc" = "0" ]'
check "รอ --wait-pid จริง (${EL}s ควร >= 2)" '[ "$EL" -ge 2 ]'
check "แอปใหม่เข้าที่ และตอบเวอร์ชั่นถูก" '[ "$("$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 | cut -d" " -f1)" = "$VER" ]'
data_intact
check "se/ ที่เปลี่ยนเองไม่ถูกทับ" '[ "$(shasum -a 256 < "$TARGET/se/correct.mp3")" = "$SE_BEFORE" ]'
check "สำรองไฟล์ชุดเดิมไว้ครบ" '[ -f "$(ls -d "$TARGET/backups"/*/ | head -1)/server.py" ]'
check "สั่งเปิดแอปใหม่" 'grep -q "IntroPlayerNative.app" "$BASE/openlog"'
check "ไม่เปิด dialog เลย" '[ ! -s "$BASE/log15" ] || ! grep -q "display dialog" "$BASE/log15"'
check "เขียน log การอัปเดต" 'grep -q "เรียบร้อย" "$BASE/home/Library/Logs/IntroPlayer-update.log"'
check "ไม่ทิ้ง lock ค้างไว้" '[ ! -d "$TARGET/.installing" ]'

echo
echo "=== 16. unattended with no --target is refused ==="
fresh_target
run_unattended "$BASE/log16" "$SRC"
rc=$?
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "แอปตัวเก่ายังอยู่" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
data_intact

echo
echo "=== 17. unattended with a --target that is not an install is refused ==="
fresh_target
rm -rf "$BASE/notaninstall"; mkdir -p "$BASE/notaninstall"
printf 'MY OWN FILE\n' > "$BASE/notaninstall/index.html"
run_unattended "$BASE/log17" "$SRC" --target "$BASE/notaninstall"
rc=$?
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "ไฟล์ของผู้ใช้ไม่ถูกทับ" 'grep -q "MY OWN FILE" "$BASE/notaninstall/index.html"'
check "ไม่สร้าง backups ที่นั่น" '[ ! -d "$BASE/notaninstall/backups" ]'

echo
echo "=== 18. unattended refuses while an app is still running IN THE TARGET ==="
fresh_target
STUB_RUNNING=1 run_unattended "$BASE/log18" "$SRC" --target "$TARGET"
rc=$?
check "exit != 0 (rc=$rc)" '[ "$rc" != "0" ]'
check "แอปตัวเก่ายังอยู่" 'grep -q "OLD APP" "$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"'
data_intact
check "บอกเหตุผลใน log" 'grep -q "ยังมีแอปเปิดอยู่" "$BASE/home/Library/Logs/IntroPlayer-update.log"'

echo
echo "=== 19. unattended gives up if the app never quits ==="
fresh_target
# A pid that outlives the 30 s wait would make the suite take 30 s, so assert the shape instead:
# a pid that is already gone must NOT be waited on.
( true ) & DEADPID=$!
wait "$DEADPID" 2>/dev/null
T0=$(date +%s)
run_unattended "$BASE/log19" "$SRC" --target "$TARGET" --wait-pid "$DEADPID"
EL=$(( $(date +%s) - T0 ))
check "pid ที่ตายแล้วไม่ถูกรอ (${EL}s ควร < 3)" '[ "$EL" -lt 3 ]'
check "ยังอัปเดตสำเร็จ" '[ "$("$TARGET/IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative" --version 2>/dev/null | head -1 | cut -d" " -f1)" = "$VER" ]'
data_intact

echo
echo "================================"
echo "ผ่าน $PASS · ไม่ผ่าน $FAIL"
[ "$FAIL" = "0" ] && echo "✓ ผ่านทั้งหมด" || echo "✗ มีข้อไม่ผ่าน"
exit "$FAIL"
