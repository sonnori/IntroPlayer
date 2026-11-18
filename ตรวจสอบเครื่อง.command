#!/bin/bash
# ดับเบิลคลิกไฟล์นี้ที่เครื่องที่มีปัญหา แล้วถ่ายรูปหน้าจอส่งมา
cd "$(dirname "$0")"
HERE="$(pwd)"
echo ""
echo "==================================================="
echo "  IntroPlayer — ตรวจสอบเครื่อง"
echo "==================================================="
echo ""
echo "โฟลเดอร์ที่ติดตั้ง:"
echo "  $HERE"
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
  "$PY" - <<'PYEOF'
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
for name in ("config.json", "log.json"):
    try:
        with open(name, "a", encoding="utf-8"):
            pass
        print("     OK — เขียน %s ได้" % name)
    except Exception as e:
        print("     ✗ เขียน %s ไม่ได้ [%s] -> %s" % (name, classify(e), e))
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
for f in server.py index.html se/correct.mp3 se/wrong.mp3; do
  [ -e "$f" ] && echo "     OK — $f" || echo "     ✗ ขาด $f"
done
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
if xattr -p com.apple.quarantine IntroPlayer.app >/dev/null 2>&1; then
  echo "     ⚠ IntroPlayer.app ติดธง quarantine"
  echo "       แก้: คลิกขวาที่ IntroPlayer > Open > กด Open อีกครั้ง (ทำครั้งเดียว)"
  echo "       หรือรันคำสั่ง:  xattr -dr com.apple.quarantine \"$HERE\""
else
  echo "     OK — ไม่ติด quarantine"
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
