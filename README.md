# RGF Intro Player

เครื่องมือสำหรับ **Game Master** ในรายการเกมโชว์ทายเพลงจากท่อนอินโทร — เปิดอินโทรสั้นๆ ให้ผู้เข้าแข่งขันกดตอบ
หยุดเพลงตอนมีคนกด เล่นเสียงเอฟเฟกต์ แล้วเฉลยด้วยการกระโดดไปท่อนฮุค

ทำงาน **ออฟไลน์ 100%** บน macOS ไม่ต้องต่อเน็ตตอนถ่าย ไม่มี dependency ภายนอก

> A Game Master console for a song-intro quiz show. Runs entirely offline on macOS 13+.
> All UI text is Thai. No third-party runtime dependencies: the native app is SwiftUI + AVAudioEngine,
> and the fallback web version is Python standard library only.

---

## ติดตั้ง

ดาวน์โหลด `IntroPlayer-x.y.z.zip` จาก [Releases](../../releases) → แตกไฟล์ → ดับเบิลคลิก
**`ติดตั้ง-อัปเดต.command`**

ครั้งแรกของแต่ละเครื่อง macOS จะเตือนว่าไม่รู้จักผู้พัฒนา (แอปยังไม่ได้ sign) →
**คลิกขวาที่ไฟล์ → Open → Open** หรือ **System Settings → Privacy & Security → "Open Anyway"**

**อัปเดตครั้งต่อไปกดในแอปได้เลย** — ตั้งช่องเช็กเวอร์ชั่นในหน้า *เกี่ยวกับแอป* เป็น `owner/repo`
ของ repo นี้ครั้งเดียว หลังจากนั้นแอปจะบอกเองเมื่อมีเวอร์ชั่นใหม่ และกดปุ่มเดียวจบ
(ทางนี้ไม่ติด Gatekeeper เลย เพราะ zip ที่แอปโหลดเองไม่ติดธง quarantine)

### ต้องเตรียมเองสองอย่าง

| | |
|---|---|
| `songs/` | ไฟล์เพลงของคุณ (`.mp3` `.m4a` `.wav` `.ogg` `.flac` `.aac`) — แยกโฟลเดอร์ย่อย = 1 รอบถ่าย |
| `se/` | เสียงเอฟเฟกต์ `correct.mp3` และ `wrong.mp3` — **ไม่ได้แจกมาในชุด** (ดู `se/README.txt`) |

เพลงและเสียงเอฟเฟกต์ไม่ได้อยู่ใน repo นี้ และไม่ได้อยู่ในไฟล์ที่แจก — แล้วแต่คนเอาไปใช้จัดหาเอง

---

## เอกสาร

| ไฟล์ | สำหรับ |
|---|---|
| [`วิธีใช้งาน-SETUP.md`](วิธีใช้งาน-SETUP.md) | **คนใช้งาน** — ติดตั้ง คุมเกม ตั้งจุดอินโทร/ฮุค log การถ่าย ส่งต่องาน อัปเดต |
| [`CLAUDE.md`](CLAUDE.md) | **คนเขียนโค้ด** — สถาปัตยกรรม, schema, audio pipeline, state machine, ข้อที่เคยพังและห้ามทำซ้ำ |

`CLAUDE.md` คือ single source of truth ของโปรเจกต์นี้ ไม่ใช่เอกสารสรุป — มันบันทึกเหตุผลเบื้องหลัง
การตัดสินใจทุกอย่างที่วัดมาแล้ว รวมถึงบั๊กที่เคยทำให้เพลงทั้งเพลงออกกล้อง

---

## โครงสร้าง

```
native/          แอปหลัก — SwiftUI + AVAudioEngine (macOS 13+, SwiftPM, ไม่มี .xcodeproj)
  build.sh         build + ประกอบ "RGF Intro Player.app"
  change-icon.sh   เปลี่ยนไอคอนจาก PNG 1024×1024
  release.sh       build + แพ็ก zip + ปล่อย GitHub Release
  installer.command  ตัวติดตั้ง/อัปเดต ที่ไม่แตะข้อมูลของผู้ใช้
  installer-test.sh  110 ข้อ ตรวจตัวติดตั้งด้วยสคริปต์ตัวจริง
server.py        เวอร์ชันเว็บ (ทางสำรอง) — Python stdlib เท่านั้น
index.html       เวอร์ชันเว็บ ทั้งแอปในไฟล์เดียว
```

## Build

```bash
./native/build.sh              # release, universal (arm64 + x86_64)
./native/build.sh debug        # เร็วกว่า สำหรับแก้โค้ด
./native/release.sh --github   # build + แพ็ก + ปล่อย release
```

มี headless diagnostic หลายตัวสำหรับตรวจ logic ที่สำคัญ — ทุกตัวต้องมี `INTROPLAYER_DIAG=1`
นำหน้า เช่น `--playtest` ยืนยันว่าเสียงหยุดตรง Intro End เป๊ะ, `--remodetest` ยืนยันว่าการแก้
marker ตอนเพลงเล่นไม่ทำให้เล่นเลยขอบ, `--loudtest` วัดความดังตามมาตรฐาน BS.1770-4,
`--palettetest` วัด contrast และ ΔE ของสีทั้งสองธีม — ดู `CLAUDE.md` §6c และ §14

เอกสารทุกไฟล์เป็นภาษาไทย เพราะคนใช้งานจริงเป็นทีมงานไทย

## ข้อมูลของผู้ใช้ ไม่เคยอยู่ใน repo นี้

`config.json` (โจทย์ที่ตั้งไว้) · `log.json` (log การถ่าย) · `songs/` (รวม `.covers/`) · `se/*.mp3` — ทั้งหมด
gitignore ไว้ และตัวติดตั้งไม่แตะไฟล์เหล่านี้เลยตอนอัปเดต เหตุผลอยู่ใน `CLAUDE.md` §5b และ §15

---

© สงวนลิขสิทธิ์ — เผยแพร่โค้ดไว้เพื่อให้ทีมงานติดตั้งและอัปเดตได้ ยังไม่ได้ให้สิทธิ์ใช้งานซ้ำ
(All rights reserved. Published so the production team can install and update; no licence granted.)
