#!/bin/bash
# ดับเบิลคลิกไฟล์นี้ที่เครื่องที่มีปัญหา แล้วถ่ายรูปหน้าจอส่งมา
cd "$(dirname "$0")"
HERE="$(pwd)"
echo ""
echo "==================================================="
echo "  RGF Intro Player — ตรวจสอบเครื่อง"
echo "==================================================="
echo ""
echo "โฟลเดอร์ที่ติดตั้ง:"
echo "  $HERE"
echo ""

# [0] เวอร์ชั่น — คำถามข้อแรกของทุกเคสที่แจ้งมา
echo "[0] เวอร์ชั่น"
VTXT="$( { tr -d ' \n\r' < VERSION; } 2>/dev/null || echo "" )"
[ -n "$VTXT" ] && echo "     VERSION         = $VTXT" || echo "     VERSION         = (ไม่มีไฟล์ VERSION — เป็นชุดก่อนมีระบบอัปเดต)"
# The bundle was renamed in 1.3.0. A crew machine may still be on the old one, and this script
# is the thing we ask them to run BEFORE the update — so it has to find either.
APPBUNDLE=""
for b in "RGF Intro Player.app" "IntroPlayerNative.app"; do
  [ -d "$b" ] && { APPBUNDLE="$b"; break; }
done
APPEXE="$APPBUNDLE/Contents/MacOS/IntroPlayerNative"
PLIST="$APPBUNDLE/Contents/Info.plist"
if [ -f "$PLIST" ]; then
  PV="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "?")"
  PC="$(/usr/libexec/PlistBuddy -c 'Print :RGFGitCommit' "$PLIST" 2>/dev/null || echo "")"
  PD="$(/usr/libexec/PlistBuddy -c 'Print :RGFBuildDate' "$PLIST" 2>/dev/null || echo "")"
  echo "     แอป (native)    = $PV${PC:+ ($PC)}${PD:+ บิลด์ $PD}"
  # A mismatch means the folder was updated by hand and half of it is stale — invisible
  # otherwise, and it explains "I installed the new one but nothing changed".
  if [ -n "$VTXT" ] && [ "$PV" != "$VTXT" ] && [ "$PV" != "?" ]; then
    echo "     ⚠ เลขไม่ตรงกัน — โฟลเดอร์นี้อัปเดตไม่ครบ ให้รัน ติดตั้ง-อัปเดต.command อีกครั้ง"
  fi
else
  echo "     แอป (native)    = ไม่พบ RGF Intro Player.app"
fi
if [ "$APPBUNDLE" = "IntroPlayerNative.app" ]; then
  echo "     หมายเหตุ: ชื่อแอปเก่า — รัน ติดตั้ง-อัปเดต.command แล้วจะเปลี่ยนเป็น RGF Intro Player"
fi
# What wrote config.json last. Two people on two builds sharing a folder shows up here.
# `-I` because the cwd is the install folder, which holds files we did not write — a planted
# json.py there would otherwise be imported.
if command -v python3 >/dev/null 2>&1 && [ -f config.json ]; then
  python3 -I -c 'import json,sys
try:
    s=json.load(open("config.json",encoding="utf-8")).get("_settings",{})
    print("     config.json     = schema %s, เขียนล่าสุดโดย v%s" % (s.get("schema","-"), s.get("writtenBy","-")))
except Exception as e:
    print("     config.json     = อ่านไม่ได้ (%s)" % e)' 2>/dev/null
fi
echo ""

# 1) Python
echo "[1] Python"
if command -v python3 >/dev/null 2>&1; then
  PY=python3; echo "     OK — $(python3 --version 2>&1)"
elif command -v python >/dev/null 2>&1; then
  PY=python; echo "     OK — $(python --version 2>&1)"
else
  PY=""
  echo "     ✗ ไม่มี Python"
  echo "       แก้: เปิด Terminal พิมพ์  xcode-select --install"
fi
echo ""

# 2) ตำแหน่งโฟลเดอร์ — macOS หวงพวก Desktop / Documents / Downloads / iCloud
echo "[2] ตำแหน่งโฟลเดอร์"
case "$HERE" in
  "$HOME/Desktop"/*|"$HOME/Documents"/*|"$HOME/Downloads"/*|*"Mobile Documents"*|*"CloudStorage"*)
    echo "     ⚠ อยู่ในโฟลเดอร์ที่ macOS ป้องกันไว้"
    echo "       นี่คือสาเหตุที่พบบ่อยที่สุด — โปรแกรมจะอ่านเพลง/เขียนค่าไม่ได้"
    echo "       แก้: ย้ายทั้งโฟลเดอร์ไปไว้ที่  $HOME/IntroPlayer  แล้วเปิดใหม่"
    ;;
  *) echo "     OK — ไม่ได้อยู่ในโฟลเดอร์ที่ถูกป้องกัน" ;;
esac
echo ""

# 3) อ่าน/เขียนได้จริงไหม (จุดที่พังจริงถ้าสิทธิ์ไม่ผ่าน)
echo "[3] สิทธิ์อ่าน/เขียนไฟล์"
if [ -n "$PY" ]; then
  # -I for the same reason as [0]: the cwd is the install folder, which holds files we did not
  # write, and a planted json.py or os.py there would otherwise be imported.
  "$PY" -I - <<'PYEOF'
import os, errno
denied = False          # สิทธิ์ไม่พอ — คนละเรื่องกับไฟล์หาย
missing = False
def classify(e):
    global denied, missing
    if getattr(e, "errno", None) in (errno.EPERM, errno.EACCES):
        denied = True; return "สิทธิ์ไม่พอ"
    if getattr(e, "errno", None) == errno.ENOENT:
        missing = True; return "ไม่พบไฟล์/โฟลเดอร์"
    return "ผิดพลาด"
try:
    n = len([f for f in os.listdir("songs") if not f.startswith(".")])
    print("     OK — อ่านโฟลเดอร์ songs/ ได้ (%d รายการ)" % n)
except Exception as e:
    print("     ✗ อ่าน songs/ ไม่ได้ [%s] -> %s" % (classify(e), e))
# Probe WITHOUT creating anything. `open(name, "a")` creates the file, which left a zero-byte
# config.json/log.json in whatever folder this was run from — and the folder this is most often
# run from is the unzipped release, which the installer then mistook for an install.
for name in ("config.json", "log.json"):
    try:
        if os.path.exists(name):
            if os.access(name, os.W_OK):
                print("     OK — เขียน %s ได้" % name)
            else:
                denied = True
                print("     ✗ เขียน %s ไม่ได้ [สิทธิ์ไม่พอ]" % name)
        else:
            # Not an error: a fresh install has neither until the app saves once.
            print("     — ยังไม่มีไฟล์ %s (ปกติถ้าเพิ่งติดตั้ง)" % name)
    except Exception as e:
        print("     ✗ ตรวจ %s ไม่ได้ [%s] -> %s" % (name, classify(e), e))
# Prove the FOLDER is writable without leaving anything behind.
try:
    probe = ".introplayer-write-probe"
    with open(probe, "w", encoding="utf-8"):
        pass
    os.remove(probe)
    print("     OK — เขียนไฟล์ใหม่ในโฟลเดอร์นี้ได้")
except Exception as e:
    print("     ✗ เขียนโฟลเดอร์นี้ไม่ได้ [%s] -> %s" % (classify(e), e))
if denied:
    print("")
    print("       ==> นี่คือปัญหาสิทธิ์ไฟล์ (สาเหตุที่พบบ่อยที่สุดตอนย้ายเครื่อง)")
    print("           วิธีแก้ที่ง่ายที่สุด: ย้ายทั้งโฟลเดอร์ไปไว้ที่  ~/IntroPlayer")
    print("           หรือให้ Full Disk Access กับ Terminal ใน")
    print("           System Settings > Privacy & Security > Full Disk Access")
elif missing:
    print("")
    print("       ==> ไฟล์ไม่ครบ ไม่ใช่ปัญหาสิทธิ์ — ตอนก๊อปข้ามเครื่องน่าจะตกหล่น")
    print("           ให้ก๊อปทั้งโฟลเดอร์ IntroPlayer ไปใหม่ทั้งอัน")
PYEOF
else
  echo "     ข้าม (ไม่มี Python)"
fi
echo ""

# 4) ไฟล์ที่ต้องมี
echo "[4] ไฟล์ที่ต้องมีครบ"
# The EXECUTABLE, not the bundle folder: a partial copy leaves Info.plist and the icon in place,
# so testing the directory reported OK for an app macOS calls damaged.
for f in "$APPEXE" \
         server.py index.html se/correct.mp3 se/wrong.mp3; do
  [ -e "$f" ] && echo "     OK — $f" || echo "     ✗ ขาด $f"
done
# And ask it what it is. This is the check that catches an app that copied but cannot run.
if [ -n "$APPBUNDLE" ] && [ -x "$APPEXE" ]; then
  RV="$("$APPEXE" --version 2>&1 | head -1)"
  if [ -n "$RV" ]; then echo "     OK — แอปรันได้ ตอบว่า: $RV"
  else echo "     ✗ แอปรันไม่ได้ (ไม่ตอบอะไรเลย) — ให้รัน ติดตั้ง-อัปเดต.command ใหม่"; fi
fi
if [ -d songs ]; then
  NSONG=$(find songs -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \
          -o -iname '*.ogg' -o -iname '*.flac' -o -iname '*.aac' \) 2>/dev/null | wc -l | tr -d ' ')
  echo "     OK — songs/ มีไฟล์เพลง $NSONG เพลง"
  [ "$NSONG" = "0" ] && echo "       ⚠ ไม่มีเพลงเลย — โปรแกรมจะเปิดได้แต่ไม่มีอะไรให้เล่น"
else
  echo "     ✗ ขาดโฟลเดอร์ songs/"
fi
echo ""

# 5) quarantine — ของที่โหลด/ก๊อปข้ามเครื่องมักติดธงนี้
echo "[5] Gatekeeper / quarantine"
QFLAG=0
for b in "RGF Intro Player.app" IntroPlayerNative.app IntroPlayer.app; do
  [ -e "$b" ] || continue
  # -lr: recursive. Checking only the bundle directory reported "not quarantined" when the flag
  # was on Contents/MacOS/<exe> — a false OK on the one condition this section exists to find.
  if xattr -lr "$b" 2>/dev/null | grep -q com.apple.quarantine; then
    echo "     ⚠ $b ติดธง quarantine"
    QFLAG=1
  else
    echo "     OK — $b ไม่ติด quarantine"
  fi
done
if [ "$QFLAG" = "1" ]; then
  echo "       แก้: คลิกขวาที่แอป > Open > กด Open อีกครั้ง (ทำครั้งเดียว)"
  echo "       หรือรันคำสั่ง:  xattr -dr com.apple.quarantine \"$HERE\""
fi
echo ""

# 6) พอร์ต
echo "[6] พอร์ต 8000"
if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "     ⚠ มีโปรแกรมอื่นใช้พอร์ต 8000 อยู่:"
  lsof -nP -iTCP:8000 -sTCP:LISTEN | tail -n +2 | awk '{print "       " $1, "(pid " $2 ")"}'
else
  echo "     OK — ว่าง"
fi
echo ""

# 7) log ล่าสุดของตัวโปรแกรมเอง
echo "[7] ข้อความ error ล่าสุดจากตัวโปรแกรม"
# The native app is the primary one (§6c) and its crashes land in DiagnosticReports, not in the
# web launcher's log — so for a native-only crew this section used to print "no log" every time.
DR="$HOME/Library/Logs/DiagnosticReports"
NCRASH="$(ls -t "$DR"/IntroPlayerNative* 2>/dev/null | head -3)"
if [ -n "$NCRASH" ]; then
  echo "     ⚠ พบรายงานแอป native ปิดตัวเอง (ล่าสุด 3 รายการ):"
  printf '%s\n' "$NCRASH" | while read -r c; do
    echo "       $(basename "$c")"
  done
  echo "       ส่งไฟล์เหล่านี้มาด้วยได้ อยู่ที่ $DR"
else
  echo "     OK — ไม่มีรายงานแอป native ปิดตัวเอง"
fi
LOG="$HOME/Library/Logs/IntroPlayer.log"
if [ -f "$LOG" ]; then
  # BrokenPipe เกิดทุกครั้งที่ seek เพลง (เบราว์เซอร์ตัดสายกลางคัน) — ไม่ใช่ปัญหา ตัดออก
  HITS=$(grep -iE "error|permission|refused|denied" "$LOG" \
         | grep -viE "brokenpipe|Broken pipe|ConnectionReset|^Traceback" | tail -8)
  if [ -n "$HITS" ]; then echo "$HITS" | sed 's/^/     /'
  else echo "     OK — ไม่พบ error ที่น่ากังวล"; fi
else
  echo "     (ยังไม่มีไฟล์ log — แปลว่าอาจยังไม่เคยเปิดผ่าน IntroPlayer.app)"
fi

echo ""
echo "==================================================="
echo "ถ่ายรูปหน้าจอนี้ส่งมาได้เลย"
echo "==================================================="
echo ""
read -n 1 -s -r -p "กดปุ่มอะไรก็ได้เพื่อปิด..."
echo ""
