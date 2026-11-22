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
# The bundle carries a SPACE, so every list below is declared ONE ENTRY PER LINE and parsed that
# way by release.sh. The old form was space-separated and read with `read -r -a`, which would have
# split "RGF Intro Player.app" into three filenames — and the cross-check that proves release.sh
# and this script agree would then have compared nonsense and passed.
APPBUNDLE="RGF Intro Player.app"
APPEXE="$APPBUNDLE/Contents/MacOS/IntroPlayerNative"
# The executable inside is still `IntroPlayerNative`: it is what `pgrep -f` matches on, what every
# documented diagnostic invokes, and renaming it buys nothing the bundle name has not already got.
# What the installer owns. Everything NOT in this list is the operator's and is left alone.
# Must match SHIP[] in release.sh — release.sh asserts it, because a file in one list and not
# the other goes stale in place.
PROGRAM=(
"RGF Intro Player.app"
IntroPlayer.app
server.py
index.html
วิธีใช้งาน-SETUP.md
ตรวจสอบเครื่อง.command
start.command
VERSION
)
# Bundles an EARLIER release installed under a different name. Moved aside into backups/ like any
# replaced program file, and restored by `rollback` — but never re-installed, because the release
# no longer ships them.
#
# This is not housekeeping. A leftover `IntroPlayerNative.app` still launches, and it reads the
# SAME config.json and log.json as the new bundle (§15), so an operator who opens the familiar
# icon is running the old build with no sign that anything is wrong — which is precisely what
# "I installed the new one but nothing changed" looks like.
LEGACY=(
IntroPlayerNative.app
)
# Seeded on a fresh install, never overwritten — an operator may have swapped in their own stings.
SEED=(
se
brand
)
# Copied aside before the swap but never replaced. The questions and the taping record.
DATA=(config.json log.json)
# Files that exist only in an unzipped RELEASE. Their presence means "this is the source, not an
# install" — see valid_target.
RELEASE_MARKERS=(ติดตั้ง-อัปเดต.command อ่านก่อน.txt)
KEEP_BACKUPS=3

# ---------- unattended mode (driven by the app itself, §15) ----------
# The app cannot replace its own running bundle, so "อัปเดตเลย" in the UI stages the release,
# launches THIS script with --unattended, and quits. Everything below the target-resolution
# branch is shared with the double-click path, so the backups, the checked rm, the full rollback
# and the "ask the installed binary its version" check are the same code under test.
UNATTENDED=0
ARG_TARGET=""
WAIT_PID=""
RELAUNCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --unattended) UNATTENDED=1 ;;
    --target)   shift; ARG_TARGET="${1:-}" ;;
    --wait-pid) shift; WAIT_PID="${1:-}" ;;
    --relaunch) RELAUNCH=1 ;;
    *) ;;   # ignore anything else: Finder may pass its own arguments on a double-click
  esac
  shift
done
LOGF="$HOME/Library/Logs/IntroPlayer-update.log"
mkdir -p "$(dirname "$LOGF")" 2>/dev/null
# Trimmed, not unbounded — this file is only ever read when something went wrong.
if [ -f "$LOGF" ] && [ "$(wc -l < "$LOGF" 2>/dev/null || echo 0)" -gt 400 ]; then
  tail -200 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv "$LOGF.tmp" "$LOGF" 2>/dev/null
fi
log() { printf '%s  %b\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOGF" 2>/dev/null; }

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
  # Unattended there is nobody to answer, and a modal would hang a process the user cannot see.
  # Nothing in the shared path below calls `say` with buttons, so logging and returning the
  # affirmative is only ever reached by the final "done" message.
  if [ "$UNATTENDED" = "1" ]; then
    log "$txt"
    # The LAST argument: `say` makes the last button the default, so this is what Return would
    # have done. Returning the first would have answered every dialog with the cancel slot —
    # which is exactly how the unattended run used to cancel itself.
    [ $# -gt 0 ] && printf '%s' "${!#}"
    return 0
  fi
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
  log "✗ ล้มเหลว: $1"
  # Unattended, the app is already gone — a critical alert from a process with no windows is a
  # bouncing Dock icon nobody connects to the update. The log plus the unchanged version number
  # is the report; the app shows the log on the next launch.
  if [ "$UNATTENDED" != "1" ]; then
    osascript -e "display alert \"ติดตั้งไม่สำเร็จ\" message \"$(esc "$1")\" as critical" >/dev/null 2>&1
  fi
  exit 1
}
cancelled() { printf '\nยกเลิก — ไม่มีอะไรถูกเปลี่ยน\n\n' >&2; exit 0; }

[ -d "$SRC/$APPBUNDLE" ] || die "ไม่พบ $APPBUNDLE ข้างไฟล์นี้ — แตก zip ให้ครบก่อน แล้วรันไฟล์นี้จากในโฟลเดอร์ที่แตกออกมา"
[ -x "$SRC/$APPEXE" ] || die "ไฟล์แอปในชุดนี้ไม่ครบ (ขาดตัวโปรแกรมข้างใน) — แตก zip ใหม่ หรือขอไฟล์ใหม่"

# ---------- 1. the app must not be running ----------
# Matched on the executable path, not the word "IntroPlayer", so this script's own argv (which
# contains the app name in its folder) cannot look like a running app.
# Matched on the executable path, not the word "IntroPlayer", so this script's own argv (which
# contains the app name in its folder) cannot look like a running app.
#
# Two scopes, on purpose. `running_anywhere` is a courtesy refusal before the attended flow asks
# the operator anything — on a real machine there is one install, so it is the same answer.
# `running_in_target` is the load-bearing one: the only app that matters is the one whose files
# are about to be replaced, and a different install elsewhere on the disk is none of our
# business. Using the broad check for the swap made the unattended path refuse whenever any
# other copy was open.
# Both the current bundle and any LEGACY one: a leftover old bundle running in the target holds
# the same config.json open, so swapping under it is §12's clobber with extra steps.
_exe_paths() {
  printf '%s\n' "$APPEXE"
  local l
  for l in ${LEGACY[@]+"${LEGACY[@]}"}; do
    printf '%s\n' "$l/Contents/MacOS/IntroPlayerNative"
  done
}
# `grep -F` on `ps` output, NOT `pgrep -f`. `pgrep -f` takes an extended regex, and these
# patterns are built from a path the operator chose: a folder called `IntroPlayer (สำรอง)` or
# `IntroPlayer [2]` produces an uncompilable pattern, whereupon pgrep exits non-zero with no
# output and the check fails OPEN — swapping files under a running app, which is §12's clobber
# of config.json. The space in the bundle name is harmless either way; the brackets are not.
_pid_matching() {
  ps -Ao pid=,command= 2>/dev/null \
    | grep -F -- "$1" \
    | awk '{print $1}' \
    | grep -vx -e "$$" -e "$PPID" \
    | head -1
}
running_anywhere() {
  local e pid
  while IFS= read -r e; do
    pid="$(_pid_matching "$e")"
    [ -n "$pid" ] && { printf '%s' "$pid"; return; }
  done < <(_exe_paths)
}
running_in_target() {
  local e pid
  while IFS= read -r e; do
    pid="$(_pid_matching "$1/$e")"
    [ -n "$pid" ] && { printf '%s' "$pid"; return; }
  done < <(_exe_paths)
}
# Unattended, the app that launched us is still finishing its quit, so waiting is the whole
# point — refusing would make the feature impossible. It still refuses if something is STILL
# running after the wait, which covers a second window or a quit the user cancelled.
if [ "$UNATTENDED" = "1" ]; then
  log "— เริ่มอัปเดตเป็น $NEWVER (unattended) จาก $SRC"
  if [ -n "$WAIT_PID" ]; then
    i=0
    while kill -0 "$WAIT_PID" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 150 ]; then   # 30 s at 0.2 s
        die "แอปยังไม่ปิดภายใน 30 วินาที — ไม่ได้แตะอะไรเลย ลองปิดแอปแล้วดับเบิลคลิก ติดตั้ง-อัปเดต.command"
      fi
      sleep 0.2
    done
    # The store flush happens on willTerminate; give the write a moment to land before we move
    # the folder's files around.
    sleep 0.5
    log "แอป (pid $WAIT_PID) ปิดแล้ว"
  fi
fi
if [ "$UNATTENDED" != "1" ] && [ -n "$(running_anywhere)" ]; then
  die "RGF Intro Player ยังเปิดอยู่\n\nปิดแอปก่อน (Cmd+Q) แล้วดับเบิลคลิกไฟล์นี้อีกครั้ง\n\nถ้ากำลังถ่ายอยู่ — อย่าอัปเดตตอนนี้ รอให้เสร็จรอบก่อน"
fi
if [ "$UNATTENDED" != "1" ] && pgrep -f "[s]erver\.py" >/dev/null 2>&1; then
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
# A directory under backups/ is the THIRD shape that is not an install, after a release folder
# and a folder that merely contains songs/. It looks like one to every other test: this script
# puts a copy of config.json in there itself, and it holds no release marker.
#
# The way in is real. The old bundle is `mv`'d into backups/<stamp>/, and macOS Dock entries
# follow a same-volume move — so the operator's existing Dock icon now opens the old app with
# `AppPaths.root` = the backup folder. It has a config.json but no songs/, i.e. §8c's "the app
# can't find my songs", and every marker and log event from then on is written into a directory
# that KEEP_BACKUPS pruning deletes three updates later.
is_in_backups() {
  case "/$1/" in */backups/*) return 0 ;; esac
  return 1
}
valid_target() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  is_release_folder "$1" && return 1
  is_in_backups "$1" && return 1
  [ -f "$1/config.json" ] || [ -d "$1/songs" ]
}

confirm_target() {  # confirm_target <path> -> 0 to proceed
  local t="$1" old
  old="$(( tr -d ' \n\r' < "$t/VERSION" ) 2>/dev/null || echo "เดิม (ไม่มีเลขเวอร์ชั่น)")"
  [ "$(say "จะอัปเดตโฟลเดอร์นี้:\n$t\n\nจาก  $old\nเป็น  $NEWVER\n\nโจทย์ · log · เพลง ไม่ถูกแตะ" "ยกเลิก" "อัปเดต")" = "อัปเดต" ]
}

TARGET=""
if [ "$UNATTENDED" = "1" ]; then
  # Given, not discovered — but validated exactly as a picked folder is, so an argument cannot
  # aim the swap somewhere the dialog flow would have refused.
  [ -n "$ARG_TARGET" ] || die "--unattended ต้องมี --target"
  valid_target "$ARG_TARGET" \
    || die "--target ไม่ใช่โฟลเดอร์ที่ติดตั้ง IntroPlayer: $ARG_TARGET"
  TARGET="$ARG_TARGET"
  log "เป้าหมาย: $TARGET"
elif [ -f "$BREADCRUMB" ]; then
  CAND="$(head -1 "$BREADCRUMB" | tr -d '\r')"
  if valid_target "$CAND"; then TARGET="$CAND"; fi
fi

# Attended only: unattended already validated the target it was handed, and there is nobody to
# answer a dialog. Without this guard the unattended run fell into the confirm and cancelled
# itself.
if [ "$UNATTENDED" != "1" ] && [ -n "$TARGET" ]; then
  if ! confirm_target "$TARGET"; then
    ans="$(say "ไม่อัปเดตโฟลเดอร์นั้น จะทำอะไรต่อ" "ยกเลิก" "เลือกโฟลเดอร์อื่น")"
    [ "$ans" = "เลือกโฟลเดอร์อื่น" ] || cancelled
    TARGET=""
  fi
fi

if [ "$UNATTENDED" != "1" ] && [ -z "$TARGET" ]; then
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

# The check that actually guards the swap. Scoped to the target, and after it is resolved.
if [ -n "$(running_in_target "$TARGET")" ]; then
  die "ยังมีแอปเปิดอยู่จากโฟลเดอร์นี้\n$TARGET\n\nปิดแอปก่อนแล้วลองใหม่"
fi

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
# LEGACY is in here too, so a bundle from an earlier release under a different name is set aside
# with everything else — and is therefore restorable by `rollback`, which matters: on a failed
# update the old bundle may be the ONLY working app on the machine.
#
# `${LEGACY[@]+...}` because bash 3.2 (what macOS ships) treats `"${EMPTY[@]}"` under `set -u`
# as an unbound variable. That matters for the day someone writes "everyone has migrated, drop
# the legacy list": `_exe_paths` runs inside process substitution, so the subshell would die,
# `running_anywhere` would return EMPTY — failing OPEN on the very check that stops a swap
# under a live app — and then this line would kill the script outright, after the backup
# directory and the data copy, with `die` never reached and so no dialog at all.
RESTORE=("${PROGRAM[@]}" ${LEGACY[@]+"${LEGACY[@]}"})

# ---------- 5. rollback, defined BEFORE anything moves ----------
# ALWAYS dies. An earlier version returned 0 when there was nothing to restore, so on a FRESH
# install `cp -R … || rollback` was satisfied by the rollback itself: the loop carried on past a
# failed copy, and the operator was shown "เรียบร้อย" over an app bundle with no executable in it.
#
# Defined HERE, above the loop that moves things, because that loop used to `die` instead — and
# `die` does not put back what the loop had already moved. On a machine past 1.3.0 `PROGRAM[0]`
# is the native bundle and it moves first, so a failure on the next item left the target with
# no native app AND no web launcher, while announcing "ไม่มีอะไรถูกเปลี่ยน".
rollback() {
  local why="$1" item
  for item in "${RESTORE[@]}"; do
    if [ -e "$BK/$item" ]; then
      rm -rf "${TARGET:?}/${item:?}" 2>/dev/null
      mv "$BK/$item" "$TARGET/$item" 2>/dev/null
    else
      # Nothing was backed up under this name, so whatever sits there now is something THIS run
      # installed. Leaving it was how a failed FIRST upgrade ended with the old bundle restored
      # AND the new one in place: two app icons, possibly a half-copied bundle macOS calls
      # "damaged", under a dialog claiming the original set had been restored.
      [ -e "$TARGET/$item" ] && rm -rf "${TARGET:?}/${item:?}" 2>/dev/null
    fi
  done
  die "$why\n\nคืนไฟล์ชุดเดิมให้แล้วทั้งหมด\nโจทย์ · log · เพลง ไม่ถูกแตะ\nสำเนาข้อมูลอยู่ที่: $BK"
}

# ---------- 6. move the old program files aside ----------
for item in "${RESTORE[@]}"; do
  if [ -e "$TARGET/$item" ]; then
    mv "$TARGET/$item" "$BK/$item" || rollback "ย้าย $item ไปที่สำรองไม่ได้"
  fi
done

# ---------- 7. swap ----------
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

if [ "$UNATTENDED" = "1" ]; then
  log "✓ อัปเดตเป็น $NEWVER เรียบร้อย — สำรองไว้ที่ backups/$STAMP"
  if [ "$RELAUNCH" = "1" ]; then
    log "เปิดแอปใหม่"
    open "$TARGET/$APPBUNDLE" 2>/dev/null
  fi
  # The staged copy lives under the system temp dir and is the parent of this script, so clean it
  # up on the way out — but only when it IS a temp path, never a folder the operator unzipped.
  case "$SRC" in
    /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*)
      ( sleep 2; rm -rf "${SRC:?}" ) >/dev/null 2>&1 &
      ;;
  esac
  exit 0
fi

ans="$(say "อัปเดตเป็น $NEWVER เรียบร้อย\n\nโฟลเดอร์: $TARGET\nโจทย์ · log · เพลง: ไม่ถูกแตะ\nไฟล์ชุดเดิม + สำเนาข้อมูล: backups/$STAMP\n\nลบโฟลเดอร์ที่แตก zip ทิ้งได้เลย" "ปิด" "เปิดโฟลเดอร์" "เปิดแอป")"
case "$ans" in
  "เปิดแอป") open "$TARGET/$APPBUNDLE" ;;
  "เปิดโฟลเดอร์") open "$TARGET" ;;
esac
exit 0
