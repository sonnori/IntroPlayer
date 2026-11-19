#!/bin/bash
# ติดตั้ง / อัปเดต RGF Intro Player
#
# Double-clicked by the operator. It replaces the PROGRAM inside their project folder and never
# touches the DATA — `config.json`, `log.json` and `songs/` are siblings of the bundle, not
# contents of it (§5), which is what makes a surgical swap possible at all.
#
# Four things it must get right, in order of how bad getting them wrong is:
#   1. Never run while the app is open. A taping is the only thing this machine does.
#   2. Never write to config.json / log.json / songs/.
#   3. Never report success unless the installed app actually runs.
#   4. Leave a way back: EVERY program file it is about to replace, plus a copy of the data, goes
#      to backups/ before anything moves — and any failure restores all of it.
#
# There is no `set -e`: every step is checked explicitly so it can report in Thai through a
# dialog. Anything added here must check its own exit status.
#
# Every `rm -rf` writes its target as "${TARGET:?}/${item:?}" so the shell aborts rather than
# running the command if either variable is somehow empty — an empty expansion there is `rm -rf /`.
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BREADCRUMB="$HOME/Library/Application Support/IntroPlayer/location"
APPEXE="IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative"
# What the installer owns. Everything NOT in this list is the operator's and is left alone.
# Must match SHIP[] in release.sh — release.sh asserts it, because a file in one list and not
# the other goes stale in place.
PROGRAM=(IntroPlayerNative.app IntroPlayer.app server.py index.html
         วิธีใช้งาน-SETUP.md ตรวจสอบเครื่อง.command start.command VERSION)
# Seeded on a fresh install, never overwritten — an operator may have swapped in their own stings.
SEED=(se)
# Copied aside before the swap but never replaced. The questions and the taping record.
DATA=(config.json log.json)
# Files that exist only in an unzipped RELEASE. Their presence means "this is the source, not an
# install" — see valid_target.
RELEASE_MARKERS=(ติดตั้ง-อัปเดต.command อ่านก่อน.txt)
KEEP_BACKUPS=3

NEWVER="$(( tr -d ' \n\r' < "$SRC/VERSION" ) 2>/dev/null || echo "?")"

# ---------- dialogs ----------
# Finder opens Terminal.app for a .command, so stdout IS visible — print as well as dialog, or a
# failure that cannot be rendered as AppleScript leaves the operator with nothing at all.
#
# `"` and `\` must be escaped: the text is interpolated into an AppleScript double-quoted literal,
# and an unescaped one is a compile error that osascript reports on stderr and we discard — so a
# folder called `IntroPlayer "ใหม่"` made every dialog, `die` included, a silent no-op.
esc() {
  local t=${1//\\/\\\\}       # every backslash doubled
  t=${t//\"/\\\"}            # quotes escaped
  # …which also doubled the `\n` line breaks in every message, so AppleScript rendered a literal
  # backslash-n instead of a newline. Put those back. (A genuine `\n` inside a path would be
  # rendered as a break; no path on this machine has one, and the alternative is losing every
  # line break in every dialog.)
  printf '%s' "${t//\\\\n/\\n}"
}

say() {  # say <text> [buttons...]  -> prints the chosen button; LAST button is the default
  local txt="$1"; shift
  # STDERR, not stdout: the caller does `ans="$(say …)"`, so echoing the message on stdout made
  # every comparison against a button label fail — the dialogs rendered, the operator pressed
  # "อัปเดต", and the script took the cancel branch every time.
  printf '\n%b\n' "$txt" >&2
  local e; e="$(esc "$txt")"
  if [ $# -gt 0 ]; then
    local btns="" last="${!#}"
    for b in "$@"; do btns="$btns\"$(esc "$b")\", "; done
    osascript -e "button returned of (display dialog \"$e\" buttons {${btns%, }} default button \"$(esc "$last")\" with title \"RGF Intro Player $(esc "$NEWVER")\" with icon note)" 2>/dev/null
  else
    osascript -e "display dialog \"$e\" buttons {\"ตกลง\"} default button \"ตกลง\" with title \"RGF Intro Player $(esc "$NEWVER")\" with icon note" >/dev/null 2>&1
  fi
}
die() {
  printf '\n✗ %b\n\n' "$1" >&2
  osascript -e "display alert \"ติดตั้งไม่สำเร็จ\" message \"$(esc "$1")\" as critical" >/dev/null 2>&1
  exit 1
}
cancelled() { printf '\nยกเลิก — ไม่มีอะไรถูกเปลี่ยน\n\n' >&2; exit 0; }

[ -d "$SRC/IntroPlayerNative.app" ] || die "ไม่พบ IntroPlayerNative.app ข้างไฟล์นี้ — แตก zip ให้ครบก่อน แล้วรันไฟล์นี้จากในโฟลเดอร์ที่แตกออกมา"
[ -x "$SRC/$APPEXE" ] || die "ไฟล์แอปในชุดนี้ไม่ครบ (ขาดตัวโปรแกรมข้างใน) — แตก zip ใหม่ หรือขอไฟล์ใหม่"

# ---------- 1. the app must not be running ----------
# Matched on the executable path, not the word "IntroPlayer", so this script's own argv (which
# contains the app name in its folder) cannot look like a running app.
running() { pgrep -f "$APPEXE" 2>/dev/null | grep -vx -e "$$" -e "$PPID" | head -1; }
if [ -n "$(running)" ]; then
  die "RGF Intro Player ยังเปิดอยู่\n\nปิดแอปก่อน (Cmd+Q) แล้วดับเบิลคลิกไฟล์นี้อีกครั้ง\n\nถ้ากำลังถ่ายอยู่ — อย่าอัปเดตตอนนี้ รอให้เสร็จรอบก่อน"
fi
if pgrep -f "[s]erver\.py" >/dev/null 2>&1; then
  # Default is CANCEL. §12 records this lesson for `confirmDestructive`: the destructive choice
  # must never be what Return or Space activates — and this dialog's own text says the latest
  # questions may be overwritten. `say` makes the LAST button the default, so cancel goes last.
  if [ "$(say "ตรวจพบว่าเวอร์ชั่นเว็บ (server.py) กำลังทำงานอยู่\n\nมันถือ config.json ไว้ในหน่วยความจำ ถ้าไม่ปิดก่อน โจทย์ที่แก้ล่าสุดอาจถูกเขียนทับ\n\nปิดหน้าเว็บและหยุด server ก่อน แล้วค่อยกดไปต่อ" "ปิดแล้ว ไปต่อ" "ยกเลิก")" != "ปิดแล้ว ไปต่อ" ]; then
    cancelled
  fi
fi

# ---------- 2. where does it go ----------
# The data is what makes a folder the install. Requiring only "songs/ OR config.json OR the
# bundle" was wrong twice over: any folder with a subdirectory called `songs` qualified (~/Music,
# a parent folder, a web project) — and index.html / server.py / start.command have generic
# names, so a wrong answer silently destroyed the operator's own files — AND an unzipped RELEASE
# folder qualified via the bundle clause, which is how the installer could end up aiming at
# ~/Downloads and leaving the real install untouched.
is_release_folder() {
  local d="$1" f
  for f in "${RELEASE_MARKERS[@]}"; do [ -e "$d/$f" ] && return 0; done
  return 1
}
valid_target() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  is_release_folder "$1" && return 1
  [ -f "$1/config.json" ] || [ -d "$1/songs" ]
}

confirm_target() {  # confirm_target <path> -> 0 to proceed
  local t="$1" old
  old="$(( tr -d ' \n\r' < "$t/VERSION" ) 2>/dev/null || echo "เดิม (ไม่มีเลขเวอร์ชั่น)")"
  [ "$(say "จะอัปเดตโฟลเดอร์นี้:\n$t\n\nจาก  $old\nเป็น  $NEWVER\n\nโจทย์ · log · เพลง ไม่ถูกแตะ" "ยกเลิก" "อัปเดต")" = "อัปเดต" ]
}

TARGET=""
if [ -f "$BREADCRUMB" ]; then
  CAND="$(head -1 "$BREADCRUMB" | tr -d '\r')"
  if valid_target "$CAND"; then TARGET="$CAND"; fi
fi

if [ -n "$TARGET" ]; then
  if ! confirm_target "$TARGET"; then
    ans="$(say "ไม่อัปเดตโฟลเดอร์นั้น จะทำอะไรต่อ" "ยกเลิก" "เลือกโฟลเดอร์อื่น")"
    [ "$ans" = "เลือกโฟลเดอร์อื่น" ] || cancelled
    TARGET=""
  fi
fi

if [ -z "$TARGET" ]; then
  ans="$(say "หาโฟลเดอร์ที่ติดตั้งไว้ไม่เจอ\n\nถ้าเคยใช้แล้ว เลือกโฟลเดอร์เดิม (โฟลเดอร์ที่มี songs/ กับ config.json)\nถ้ายังไม่เคยใช้ ให้ติดตั้งใหม่" "ยกเลิก" "ติดตั้งใหม่" "เลือกโฟลเดอร์เดิม")"
  case "$ans" in
    "เลือกโฟลเดอร์เดิม")
      TARGET="$(osascript -e 'POSIX path of (choose folder with prompt "เลือกโฟลเดอร์ IntroPlayer เดิม (ที่มี songs/ และ config.json)")' 2>/dev/null)"
      [ -n "$TARGET" ] || cancelled
      TARGET="${TARGET%/}"
      valid_target "$TARGET" || die "โฟลเดอร์นี้ไม่ใช่ที่ติดตั้ง IntroPlayer\n($TARGET)\n\nต้องมี songs/ หรือ config.json อยู่ข้างใน และต้องไม่ใช่โฟลเดอร์ที่แตก zip ออกมา\n\nระวัง: เลือกผิดโฟลเดอร์จะทับไฟล์ชื่อเดียวกันของคุณ"
      # The branch where the OPERATOR navigated by hand is the one that most needs confirming,
      # and it was the one that went straight from the folder picker to the swap.
      confirm_target "$TARGET" || cancelled
      ;;
    "ติดตั้งใหม่")
      PARENT="$(osascript -e 'POSIX path of (choose folder with prompt "จะติดตั้ง IntroPlayer ไว้ที่ไหน")' 2>/dev/null)"
      [ -n "$PARENT" ] || cancelled
      TARGET="${PARENT%/}/IntroPlayer"
      if [ -e "$TARGET" ] && ! valid_target "$TARGET"; then
        die "มี $TARGET อยู่แล้วและไม่ใช่ที่ติดตั้ง IntroPlayer — เลือกที่อื่น หรือเปลี่ยนชื่อโฟลเดอร์นั้นก่อน"
      fi
      [ "$(say "จะติดตั้งใหม่ที่:\n$TARGET\n\nเวอร์ชั่น $NEWVER" "ยกเลิก" "ติดตั้ง")" = "ติดตั้ง" ] || cancelled
      mkdir -p "$TARGET/songs" || die "สร้างโฟลเดอร์ไม่ได้: $TARGET"
      ;;
    *) cancelled ;;
  esac
fi

# `pwd -P` resolves symlinks so the `-ef` test below compares real directories.
TARGET="$(cd "$TARGET" && pwd -P)" || die "เข้าโฟลเดอร์ไม่ได้: $TARGET"
SRCP="$(cd "$SRC" && pwd -P)" || die "เข้าโฟลเดอร์ต้นทางไม่ได้"
# `-ef` compares device+inode, not text. A string compare let the SAME directory through under
# two spellings — a symlinked Desktop/Documents (iCloud Drive), /tmp vs /private/tmp, or a case
# difference on a case-insensitive volume — and the installer then installed over its own source,
# permanently destroying IntroPlayer.app from the release folder while reporting a rollback.
if [ "$TARGET" -ef "$SRCP" ]; then
  die "นี่คือโฟลเดอร์ที่แตก zip ออกมา ไม่ใช่ที่ติดตั้ง\n\nเลือกโฟลเดอร์ที่มี songs/ กับ config.json ของคุณ"
fi
[ -w "$TARGET" ] || die "เขียนโฟลเดอร์นี้ไม่ได้ (สิทธิ์ไม่พอ):\n$TARGET"

# ---------- 3. one at a time ----------
# An operator who sees nothing happen double-clicks again. Two concurrent runs raced each other
# into a state where the second found no old bundle to set aside, which used to disarm rollback.
LOCK="$TARGET/.installing"
if ! mkdir "$LOCK" 2>/dev/null; then
  die "มีการติดตั้งค้างอยู่ในโฟลเดอร์นี้\n\nถ้าแน่ใจว่าไม่มีอะไรกำลังทำงาน ให้ลบโฟลเดอร์ซ่อน .installing ข้างใน\n$TARGET\nแล้วลองใหม่"
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---------- 4. back up before anything moves ----------
BK="$TARGET/backups/$STAMP"
mkdir -p "$BK" || die "สร้างโฟลเดอร์สำรองไม่ได้: $BK"

# The data. Copied, never moved — it is not ours to take away.
for f in "${DATA[@]}"; do
  if [ -f "$TARGET/$f" ]; then
    cp -p "$TARGET/$f" "$BK/$f" || die "สำรอง $f ไม่สำเร็จ — หยุดไว้ก่อน ไม่มีอะไรถูกเปลี่ยน"
  fi
done

# EVERY program file that is about to be replaced, moved aside rather than deleted. Backing up
# only the app bundle meant a failure part-way restored the bundle, announced "คืนแอปตัวเดิมให้
# แล้ว", and left index.html / server.py / the diagnostic DELETED with no copy anywhere — i.e.
# the mid-taping web fallback (§6c) and the tool you would ask them to run next.
for item in "${PROGRAM[@]}"; do
  if [ -e "$TARGET/$item" ]; then
    mv "$TARGET/$item" "$BK/$item" || die "ย้าย $item ไปที่สำรองไม่ได้ — ไม่มีอะไรถูกเปลี่ยน"
  fi
done

# ---------- 5. swap ----------
# ALWAYS dies. The previous version returned 0 when there was nothing to restore, so on a FRESH
# install `cp -R … || rollback` was satisfied by the rollback itself: the loop carried on past a
# failed copy, and the operator was shown "เรียบร้อย" over an app bundle with no executable in it.
rollback() {
  local why="$1" item
  for item in "${PROGRAM[@]}"; do
    [ -e "$BK/$item" ] || continue
    rm -rf "${TARGET:?}/${item:?}" 2>/dev/null
    mv "$BK/$item" "$TARGET/$item" 2>/dev/null
  done
  die "$why\n\nคืนไฟล์ชุดเดิมให้แล้วทั้งหมด\nโจทย์ · log · เพลง ไม่ถูกแตะ\nสำเนาข้อมูลอยู่ที่: $BK"
}

for item in "${PROGRAM[@]}"; do
  [ -e "$SRC/$item" ] || continue
  # `rm -rf`'s exit status was never checked, and when it fails on a DIRECTORY `cp -R src dst`
  # copies *into* dst and returns 0 — so one locked or sync-held file nested the new bundle
  # inside the old one, left the old executable in place, and reported success.
  rm -rf "${TARGET:?}/${item:?}" || rollback "ลบ $item ตัวเดิมไม่ได้"
  [ ! -e "$TARGET/$item" ] || rollback "$item ตัวเดิมยังลบไม่ออก (ไฟล์ถูกล็อก หรือ Drive/iCloud กำลัง sync)"
  cp -R "$SRC/$item" "$TARGET/$item" || rollback "คัดลอก $item ไม่สำเร็จ"
done
# `cp -R` carries the mode over, but a third-party unzipper may have dropped it before we ever
# saw the file — and a .command that is not executable just opens in a text editor.
for f in "$TARGET"/*.command; do [ -f "$f" ] && chmod +x "$f" 2>/dev/null; done

for item in "${SEED[@]}"; do
  [ -e "$SRC/$item" ] || continue
  [ -e "$TARGET/$item" ] || cp -R "$SRC/$item" "$TARGET/$item"
done
mkdir -p "$TARGET/songs"

# ---------- 6. Gatekeeper ----------
# The bundle is unsigned, so anything that arrived through a browser or Drive carries a
# quarantine flag and macOS refuses to open it. Scoped to what we just copied, never the whole
# folder — the operator's own files are not ours to relabel.
#
# Note this cannot help the NEXT release's own ติดตั้ง-อัปเดต.command: that file arrives later, in
# a new download, and Gatekeeper records approval per file. A downloaded zip therefore needs the
# right-click → Open step every time; only a synced-folder release avoids it.
for item in "${PROGRAM[@]}"; do
  [ -e "$TARGET/$item" ] && xattr -dr com.apple.quarantine "$TARGET/$item" 2>/dev/null
done

# ---------- 7. prove it actually runs ----------
# Never report success on an app nobody has asked a question of. `release.sh` makes this same
# check against the zip; the thing the operator ends up with deserves it more.
GOT="$("$TARGET/$APPEXE" --version 2>/dev/null | head -1 | cut -d' ' -f1)"
if [ "$GOT" != "$NEWVER" ]; then
  rollback "แอปที่ติดตั้งไปรันไม่ได้ (ตอบเวอร์ชั่น '${GOT:-ไม่ตอบ}' ไม่ใช่ '$NEWVER')"
fi

# ---------- 8. done ----------
# `mkdir -p` because on a FRESH install this directory does not exist yet — the app creates it on
# first launch, and the case where the breadcrumb matters is the case where the app won't open.
mkdir -p "$(dirname "$BREADCRUMB")" 2>/dev/null
printf '%s\n' "$TARGET" > "$BREADCRUMB" 2>/dev/null || true

# ~6 MB of app bundle per update, forever, inside a folder that may be in a sync root.
# A glob, not `head -n -N`: the negative line count is a GNU extension and BSD head — i.e. the
# only head this ever runs on — rejects it, so nothing was pruned at all. Glob expansion is
# sorted and the names are timestamps, so this is oldest-first.
shopt -s nullglob
BKS=("$TARGET/backups"/*/)
shopt -u nullglob
if [ "${#BKS[@]}" -gt "$KEEP_BACKUPS" ]; then
  for ((i = 0; i < ${#BKS[@]} - KEEP_BACKUPS; i++)); do
    rm -rf "${BKS[$i]:?}"
  done
fi

ans="$(say "อัปเดตเป็น $NEWVER เรียบร้อย\n\nโฟลเดอร์: $TARGET\nโจทย์ · log · เพลง: ไม่ถูกแตะ\nไฟล์ชุดเดิม + สำเนาข้อมูล: backups/$STAMP\n\nลบโฟลเดอร์ที่แตก zip ทิ้งได้เลย" "ปิด" "เปิดโฟลเดอร์" "เปิดแอป")"
case "$ans" in
  "เปิดแอป") open "$TARGET/IntroPlayerNative.app" ;;
  "เปิดโฟลเดอร์") open "$TARGET" ;;
esac
exit 0
