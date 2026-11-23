#!/bin/bash
# Exercises native/swap-app.sh against real directories, with fake .app bundles whose "binary" is
# a shell script that prints a version. Production code runs UNMODIFIED.
#
# Everything happens under one temp directory. It never touches /Applications, the project folder,
# or the operator's data — which the swap helper cannot reach anyway, and that is the point of it.
#
#   ./native/swap-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWAP="$HERE/swap-app.sh"
[ -x "$SWAP" ] || chmod +x "$SWAP" 2>/dev/null
[ -f "$SWAP" ] || { echo "ไม่มี $SWAP"; exit 1; }

BOX="$(mktemp -d "${TMPDIR:-/tmp}/rgf-swaptest-XXXXXX")"
# Keep the helper's log out of the operator's real one.
export HOME="$BOX/home"
mkdir -p "$HOME"
cleanup() { rm -rf "$BOX"; }
trap cleanup EXIT

pass=0; fail=0
check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then pass=$((pass+1)); printf '   ok   %s' "$label"
  else fail=$((fail+1)); printf '   ✗    %s' "$label"; fi
  [ -z "$detail" ] && echo || echo "  — $detail"
}

# A .app whose executable reports $2 as its version.
mkapp() {
  local path="$1" ver="$2"
  mkdir -p "$path/Contents/MacOS" "$path/Contents/Resources"
  cat > "$path/Contents/MacOS/IntroPlayerNative" <<EOF
#!/bin/bash
[ "\${1:-}" = "--version" ] && echo "$ver (test, 2026-01-01)"
exit 0
EOF
  chmod +x "$path/Contents/MacOS/IntroPlayerNative"
  echo "marker-$ver" > "$path/Contents/Resources/which.txt"
}
whichver() { cat "$1/Contents/Resources/which.txt" 2>/dev/null || echo "—"; }

run() { "$SWAP" "$@" >"$BOX/out.txt" 2>&1; echo $?; }
# An exit of 1 proves only that SOMETHING refused. Several of these cases would also exit 1 for a
# completely different reason — a typo in a path, a missing fixture — and the suite would still
# read green. §12 records this shape twice (a `ps | grep` that matched its own grep; a staged-file
# loop that could only ever report failure), so the refusals that matter assert the REASON.
why() { grep -qF "$1" "$BOX/out.txt" && echo 1; }

echo "swap-app.sh — $(basename "$BOX")"
echo
echo "1) ปฏิเสธก่อนแตะอะไร"

mkapp "$BOX/apps/RGF Intro Player.app" "1.0.0"
mkapp "$BOX/stage/RGF Intro Player.app" "2.0.0"
T="$BOX/apps/RGF Intro Player.app"
S="$BOX/stage/RGF Intro Player.app"

rc=$(run --source "$S"); check "ไม่มี --target → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
rc=$(run --target "$T"); check "ไม่มี --source → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
rc=$(run --target "$BOX/apps" --source "$S")
check "--target ไม่ใช่ .app → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
rc=$(run --target "$T" --source "$BOX/nope.app")
check "--source ไม่มีอยู่ → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
rc=$(run --target "$T" --source "$T")
check "target = source → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
# §15: a string compare let the same directory through under two spellings and the installer
# installed over its own source. `-ef` compares inode+device instead.
ln -s "$BOX/apps" "$BOX/applink"
rc=$(run --target "$BOX/applink/RGF Intro Player.app" --source "$T")
check "target = source ผ่าน symlink → ปฏิเสธ (-ef ไม่ใช่เทียบสตริง)" \
      "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
rc=$(run --target "$T" --source "$S" --expect "9.9.9")
check "--expect ไม่ตรงกับเวอร์ชั่นต้นทาง → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
check "   …ด้วยเหตุผลเรื่องเวอร์ชั่นจริง ๆ" "$(why "ที่สั่งมาคือ 9.9.9")"
check "ปฏิเสธแล้วแอปเดิมยังอยู่ครบ" \
      "$([ "$(whichver "$T")" = "marker-1.0.0" ] && echo 1)" "$(whichver "$T")"
check "ปฏิเสธแล้วไม่มี .old- ค้าง" \
      "$([ -z "$(find "$BOX/apps" -maxdepth 1 -name '*.old-*' -print -quit)" ] && echo 1)"

echo
echo "2) ยังมีแอปรันอยู่จากปลายทาง → ปฏิเสธ"
# argv[0] set to the target's executable path, which is what `ps` shows and what the helper
# matches with `grep -F`. A real running app looks exactly like this to it.
bash -c 'exec -a "$1" sleep 8' _ "$T/Contents/MacOS/IntroPlayerNative" &
BUSY=$!
sleep 0.4
rc=$(run --target "$T" --source "$S")
check "เจอ process จากปลายทาง → ไม่สลับ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
check "   …ด้วยเหตุผลว่ายังมีแอปรันอยู่ จริง ๆ" "$(why "ยังมีแอปรันอยู่จาก")"
check "ยังเป็นตัวเดิม" "$([ "$(whichver "$T")" = "marker-1.0.0" ] && echo 1)" "$(whichver "$T")"
kill "$BUSY" 2>/dev/null; wait "$BUSY" 2>/dev/null

echo
echo "3) --wait-pid"
SLEEPER=$(bash -c 'sleep 1 & echo $!')
rc=$(run --target "$T" --source "$S" --wait-pid "$SLEEPER" --expect "2.0.0")
check "รอ pid จนปิดแล้วค่อยสลับ" "$([ "$rc" = 0 ] && echo 1)" "exit $rc"
check "ได้ตัวใหม่" "$([ "$(whichver "$T")" = "marker-2.0.0" ] && echo 1)" "$(whichver "$T")"
check "ลบตัวเดิมที่ย้ายออกแล้ว" \
      "$([ -z "$(find "$BOX/apps" -maxdepth 1 -name '*.old-*' -print -quit)" ] && echo 1)"
grep -q "ติดตั้งเวอร์ชั่น 2.0.0" "$HOME/Library/Logs/IntroPlayer-update.log" 2>/dev/null
check "เขียน log ไว้ให้ตามเรื่องได้" "$([ $? = 0 ] && echo 1)"

rc=$(run --target "$T" --source "$S" --wait-pid 999999)
check "--wait-pid ที่ตายไปแล้ว ไม่ค้าง" "$([ "$rc" = 0 ] && echo 1)" "exit $rc"

echo
echo "4) คัดลอกพัง → ต้องคืนตัวเดิม"
mkapp "$BOX/apps/RGF Intro Player.app" "3.0.0"
mkapp "$BOX/bad/RGF Intro Player.app" "4.0.0"
# A file cp cannot read makes `cp -R` fail partway, after the old bundle has been moved aside.
# That is the branch §15 records as having been broken for a FIRST upgrade: rollback skipped the
# one thing the run had actually installed, and the dialog still said the original was restored.
chmod 000 "$BOX/bad/RGF Intro Player.app/Contents/Resources/which.txt"
rc=$(run --target "$T" --source "$BOX/bad/RGF Intro Player.app")
chmod 644 "$BOX/bad/RGF Intro Player.app/Contents/Resources/which.txt" 2>/dev/null
check "คัดลอกไม่สำเร็จ → exit ไม่ใช่ 0" "$([ "$rc" != 0 ] && echo 1)" "exit $rc"
check "   …ด้วยเหตุผลว่าคัดลอกพัง และบอกว่าคืนค่าแล้ว" \
      "$([ -n "$(why "คัดลอกแอปใหม่ไม่สำเร็จ")" ] && [ -n "$(why "คืนแอปตัวเดิมเรียบร้อย")" ] && echo 1)"
check "แอปตัวเดิมกลับมาอยู่ที่เดิม" "$([ -x "$T/Contents/MacOS/IntroPlayerNative" ] && echo 1)"
check "และเป็นตัวเดิมจริง ไม่ใช่ซากของใหม่" \
      "$([ "$(whichver "$T")" = "marker-3.0.0" ] && echo 1)" "$(whichver "$T")"
check "ไม่มี .old- ค้างหลังคืนค่า" \
      "$([ -z "$(find "$BOX/apps" -maxdepth 1 -name '*.old-*' -print -quit)" ] && echo 1)"

echo
echo "5) ต้นทางตอบเวอร์ชั่นไม่ได้ → ปฏิเสธตั้งแต่ยังไม่ขยับ"
mkdir -p "$BOX/mute/RGF Intro Player.app/Contents/MacOS"
printf '#!/bin/bash\nexit 1\n' > "$BOX/mute/RGF Intro Player.app/Contents/MacOS/IntroPlayerNative"
chmod +x "$BOX/mute/RGF Intro Player.app/Contents/MacOS/IntroPlayerNative"
rc=$(run --target "$T" --source "$BOX/mute/RGF Intro Player.app")
check "ต้นทาง --version เงียบ → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
check "   …ด้วยเหตุผลว่าตอบเวอร์ชั่นไม่ได้ จริง ๆ" "$(why "ตอบ --version ไม่ได้")"
check "ยังเป็นตัวเดิม" "$([ "$(whichver "$T")" = "marker-3.0.0" ] && echo 1)" "$(whichver "$T")"

echo
echo "6) โฟลเดอร์ปลายทางเขียนไม่ได้ → ปฏิเสธ (ผู้ใช้ที่ไม่ใช่ admin)"
mkdir -p "$BOX/ro"
mkapp "$BOX/ro/RGF Intro Player.app" "5.0.0"
chmod 555 "$BOX/ro"
rc=$(run --target "$BOX/ro/RGF Intro Player.app" --source "$S")
chmod 755 "$BOX/ro"
check "เขียนในโฟลเดอร์ปลายทางไม่ได้ → ปฏิเสธ" "$([ "$rc" = 1 ] && echo 1)" "exit $rc"
check "   …ด้วยเหตุผลเรื่องสิทธิ์เขียน จริง ๆ" "$(why "ต้องเป็นผู้ใช้ที่เป็น admin")"
check "ยังเป็นตัวเดิม" "$([ "$(whichver "$BOX/ro/RGF Intro Player.app")" = "marker-5.0.0" ] && echo 1)"

echo
echo "ผ่าน $pass  ตก $fail"
[ "$fail" = "0" ] && { echo "✓ ผ่าน"; exit 0; } || { echo "✗ ไม่ผ่าน"; cat "$BOX/out.txt"; exit 1; }
