#!/bin/bash
# Replace an installed "RGF Intro Player.app" with a staged one, then relaunch.
#
# This is what `ติดตั้ง-อัปเดต.command` turned into once the questions stopped living next to the
# program (CLAUDE.md §5d). The old installer was ~600 lines and 123 assertions because the thing it
# replaced sat in the same folder as `config.json`, `log.json` and `songs/` — so it needed backups,
# a rollback, a lock, a legacy-bundle list, a seeding pass and a "is this really an install"
# check, and every one of those existed to keep a program swap from reaching the operator's
# questions. With the app in /Applications it cannot reach them at all. What is left is this.
#
#   swap-app.sh --target <installed.app> --source <staged.app> [--expect <version>]
#               [--wait-pid <pid>] [--relaunch]
#
# Exit 0 only when the installed app reports the version it was supposed to. Anything else rolls
# back and exits non-zero, having left the previous app in place.
set -euo pipefail

TARGET=""
SOURCE=""
EXPECT=""
WAITPID=""
RELAUNCH=0
EXE="Contents/MacOS/IntroPlayerNative"
LOG="$HOME/Library/Logs/IntroPlayer-update.log"

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
  echo "$*"
}
die() { log "✗ $*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target)   shift; TARGET="${1:-}" ;;
    --source)   shift; SOURCE="${1:-}" ;;
    --expect)   shift; EXPECT="${1:-}" ;;
    --wait-pid) shift; WAITPID="${1:-}" ;;
    --relaunch) RELAUNCH=1 ;;
    *) die "ไม่รู้จักอาร์กิวเมนต์: $1" ;;
  esac
  shift || true
done

log "---- swap-app $(date '+%F %T') ----"
log "target=$TARGET"
log "source=$SOURCE expect=${EXPECT:-—} waitpid=${WAITPID:-—} relaunch=$RELAUNCH"

[ -n "$TARGET" ] || die "ต้องมี --target"
[ -n "$SOURCE" ] || die "ต้องมี --source"

# ---- validate both ends BEFORE anything moves -------------------------------------------------
# Everything that can refuse runs first, for the reason §15 records about `release.sh --github`:
# a check placed after the destructive step turns a refusal into damage.
case "$TARGET" in *.app) ;; *) die "--target ต้องเป็น .app : $TARGET" ;; esac
case "$SOURCE" in *.app) ;; *) die "--source ต้องเป็น .app : $SOURCE" ;; esac
[ -d "$TARGET" ] || die "ไม่มีแอปที่ปลายทาง: $TARGET"
[ -d "$SOURCE" ] || die "ไม่มีแอปต้นทาง: $SOURCE"
[ -x "$SOURCE/$EXE" ] || die "ต้นทางไม่มีตัวโปรแกรมข้างใน: $SOURCE/$EXE"
[ -x "$TARGET/$EXE" ] || die "ปลายทางไม่ใช่แอปตัวนี้: $TARGET/$EXE"
[ "$TARGET" != "$SOURCE" ] || die "--target กับ --source เป็นที่เดียวกัน"
# `-ef` compares inode+device, so a symlinked path or /tmp vs /private/tmp cannot sneak the same
# directory through under two spellings. §15 records the installer installing over its own source.
if [ "$TARGET" -ef "$SOURCE" ]; then die "--target กับ --source ชี้ที่เดียวกัน"; fi

PARENT="$(cd "$(dirname "$TARGET")" && pwd)"
[ -w "$PARENT" ] || die "เขียนในโฟลเดอร์ $PARENT ไม่ได้ — ต้องเป็นผู้ใช้ที่เป็น admin ของเครื่อง"

# The staged app must say who it is. `Updater` checks this too before it ever launches us; it is
# repeated here because this is the process that actually acts, and §15's one-click update is only
# defensible because the thing being installed was asked its version first.
GOT="$("$SOURCE/$EXE" --version 2>/dev/null | head -1 | awk '{print $1}' || echo "")"
[ -n "$GOT" ] || die "ต้นทางตอบ --version ไม่ได้ — ไฟล์อาจเสีย"
if [ -n "$EXPECT" ] && [ "$GOT" != "$EXPECT" ]; then
  die "ต้นทางเป็นเวอร์ชั่น $GOT แต่ที่สั่งมาคือ $EXPECT — ไม่สลับ"
fi
log "ต้นทางเวอร์ชั่น $GOT"

# ---- wait for the running app to quit ---------------------------------------------------------
if [ -n "$WAITPID" ]; then
  n=0
  while kill -0 "$WAITPID" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 300 ] || die "แอปยังไม่ปิดหลังรอ 30 วินาที — ไม่สลับ"
    sleep 0.1
  done
  # The debounced save flushes on willTerminate; give that write somewhere to land.
  sleep 0.5
  log "แอปปิดแล้ว (รอ $((n / 10)) วินาที)"
fi

# Still running from the target? `grep -F` on `ps` output, never `pgrep -f`: §12 records a folder
# named `IntroPlayer (ใหม่)` making pgrep's pattern uncompilable, which failed OPEN. The `grep -v`
# drops our own pipeline, because `ps` lists the process reading it.
if ps -Ao pid=,command= | grep -F "$TARGET/$EXE" | grep -vF "grep -F" | grep -q .; then
  die "ยังมีแอปรันอยู่จาก $TARGET — ปิดก่อน"
fi

# ---- the swap ---------------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
ASIDE="$TARGET.old-$STAMP"
rollback() {
  log "กำลังคืนแอปตัวเดิม…"
  rm -rf "${TARGET:?}" 2>/dev/null || true
  if [ -d "$ASIDE" ]; then
    if mv "$ASIDE" "$TARGET"; then log "คืนแอปตัวเดิมเรียบร้อย"
    else log "✗ คืนไม่สำเร็จ — แอปตัวเดิมอยู่ที่ $ASIDE"; fi
  fi
}

# Moved aside as a SIBLING, not into a temp dir: same filesystem by construction, so the move is a
# rename and cannot half-copy. The old installer's `backups/` lived in the operator's own folder,
# which is exactly what no longer has to happen.
mv "$TARGET" "$ASIDE" || die "ย้ายแอปตัวเดิมออกไม่ได้ (ไฟล์ถูกล็อกอยู่?)"
log "ย้ายตัวเดิมไป $ASIDE"

# `cp -R src dst` when dst still exists copies INTO it — §15 records one locked file nesting the
# new bundle inside the old one and reporting success. The mv above means dst is gone; assert it.
[ ! -e "$TARGET" ] || { rollback; die "ปลายทางยังอยู่หลังย้ายออก"; }
if ! cp -R "$SOURCE" "$TARGET"; then rollback; die "คัดลอกแอปใหม่ไม่สำเร็จ"; fi

# Quarantine: a zip this app downloaded through its own URLSession carries none, but a source
# copied off a mounted .dmg can. Only what we just installed, never the folder around it.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# ---- prove it runs before saying it worked ----------------------------------------------------
NEW="$("$TARGET/$EXE" --version 2>/dev/null | head -1 | awk '{print $1}' || echo "")"
if [ "$NEW" != "$GOT" ]; then
  rollback
  die "แอปที่ติดตั้งแล้วตอบเวอร์ชั่น '${NEW:-—}' ไม่ใช่ $GOT — คืนตัวเดิมให้แล้ว"
fi
log "✓ ติดตั้งเวอร์ชั่น $NEW แล้ว"
rm -rf "$ASIDE" 2>/dev/null || true

if [ "$RELAUNCH" = "1" ]; then
  log "เปิดแอปใหม่"
  open -n "$TARGET" || log "เปิดแอปอัตโนมัติไม่สำเร็จ — เปิดเองได้จาก $TARGET"
fi
exit 0
