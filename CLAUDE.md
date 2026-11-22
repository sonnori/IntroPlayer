# RGF Intro Player — Developer Handoff

Handoff doc for continuing development (e.g. in Claude Code). Covers architecture, code map, data
schema, the audio pipeline, the playback state machine, known edge cases, and suggested next steps.

> This is the single source of truth. `DEV.md` is just a pointer here — don't fork it again.

---

## 1. What this is

A local, offline web app for a **song-intro quiz game show**. The Game Master (GM) plays a short
intro of a song; contestants buzz to answer; the GM pauses, plays sound effects, and can reveal the
song by jumping to its hook/chorus.

**Status:** working prototype, used in real tapings.

**Two people, one at a time.** A *setter* (คนเซ็ตโจทย์) prepares a round — finds songs, places
markers, sets per-song trim — and a different *operator* (คนรันถ่าย) runs the taping. Still a
single-process, single-machine tool: they do not run at the same time, they hand a folder over.
See §8e.

> **The operator keeps full editing ability — do NOT add a read-only or locked "show mode".**
> This was considered and rejected: things go wrong on set and the operator is the only person
> there. The problem was never *who may edit*, it is *was the edit intended, is it visible, can it
> be undone, can it be sent back*. That is what §8e and the two-press confirm (§11) solve.

### Core requirements (original spec)
- Runs 100% locally, **no internet** needed.
- Reads audio files from `./songs/` and lists them alphabetically.
- GM controls: **Start** (play intro), **Pause** (on buzz), **Reveal** (jump to hook and play on).
- Intro is a **range** `[introStart, introEnd]`; playback must **not** continue past `introEnd`
  into the song, *except* when revealing.
- Progress/waveform view.
- Two SE buttons: `/se/correct.mp3`, `/se/wrong.mp3` (fire-and-forget, no scoring).

---

## 2. Design principles / constraints

- **No third-party runtime deps.** Server is Python **standard library only** (works with the
  system `python3` that ships via Xcode Command Line Tools on macOS). Client is a single vanilla
  HTML file, no build step, no npm, no CDN.
- **Offline.** Everything is served from localhost. Waveform + loudness analysis use the browser's
  built-in Web Audio API. Nothing is fetched from the network.
- **Original audio files are never modified.** The server streams raw bytes. All audio shaping
  happens on the *output* in the browser (see §7).
- **Config is a single JSON file** keyed by filename, so moving the whole folder to another machine
  carries all settings.

---

## 3. Tech stack

**Native (primary — §6c)**

| Layer  | Tech |
|--------|------|
| App    | SwiftUI + AppKit, SwiftPM executable (`native/`), macOS 13 target, no `.xcodeproj` |
| Audio  | AVAudioEngine → AVAudioUnitEQ (level) → PeakLimiter, `scheduleSegment` for seeking |
| Loudness | BS.1770-4 K-weighted gated LUFS (`Loudness.swift`) — §7a3 |
| Detection | vDSP FFT → chromagram → repetition, for Intro End and Hook (`AutoDetect.swift`) — §7a4 |
| Data   | the same `config.json` / `log.json` as the web version — §9, §8d |
| Launch | **`RGF Intro Player.app`**, assembled by `./native/build.sh` |

> **Accelerate and AVFoundation are Apple system frameworks**, so §2's "no third-party runtime
> deps" is intact. The rule is about things that have to be installed, not about the OS.

**Web (fallback — §6, §8)**

| Layer  | Tech |
|--------|------|
| Server | Python 3 stdlib (`http.server`, `socketserver`), ~300 lines, `server.py` |
| Client | Single-file vanilla HTML/CSS/JS, `index.html`, ~1400 lines |
| Audio  | HTML5 `<audio>` + Web Audio API (GainNode + DynamicsCompressor), Canvas waveform |
| Launch | `IntroPlayer.app` (bash-script bundle, no compiled code); `start.command` as fallback |

No framework, no bundler, no tests harness yet.

---

## 4. Run it (dev)

```bash
cd IntroPlayer
python3 server.py           # serves http://localhost:8000
# then open http://localhost:8000
```

Port is hard-coded to `8000` in `server.py` (`PORT`). If it is already taken, the server prints a
short "port in use" message and exits with status 2 instead of dumping a traceback.

**For the show operator** there is `IntroPlayer.app` — see §6b. `start.command` still works and is
kept as the fallback path (it is the only route that shows server output live in a Terminal).

---

## 5. Directory layout

```
IntroPlayer/
├── .gitignore           # see §5b — config.json/log.json/songs/ are deliberately NOT tracked
├── VERSION              # single source of the version number — §15
├── server.py            # local HTTP server (stdlib only)       — web version
├── index.html           # entire GM app (HTML+CSS+JS in one file) — web version
├── native/              # SwiftUI rewrite, the primary app now — see §6c
├── RGF Intro Player.app/ # built by native/build.sh (not hand-edited). The name carries a
│                        # SPACE — see §15 for what that touches. The executable inside is
│                        # still `IntroPlayerNative`.
├── IntroPlayer.app/     # launcher bundle for the WEB version — no compiled code, see §6b
├── start.command        # macOS launcher (fallback / dev)
├── ตรวจสอบเครื่อง.command # on-site diagnostic: version, perms, quarantine, port — §15
├── dist/                # release zips + manifest.json, built by native/release.sh (§15)
├── backups/             # written by the installer before a swap: config/log/the old app (§15)
│   └── snapshots/       # a copy of the questions taken at every launch — §5c
├── config.json          # saved settings, keyed by path under songs/ (auto-written)
├── log.json             # taping log: correct/wrong events, chronological (§8d, auto-written)
├── songs/               # audio files (.mp3/.m4a/.wav/.ogg/.flac/.aac)
│   └── <รอบถ่าย>/        # optional subfolder = one playlist/taping (§8c); loose files still fine
│       ├── round.json   # written by "ส่งต่อ" — the handover unit is this folder (§8e)
│       └── .covers/     # downloaded cover art, INSIDE the round so it travels (§8f). Hidden,
│                        # so Library.scan's .skipsHiddenFiles keeps it out of the song list.
├── se/                  # correct.mp3, wrong.mp3
├── วิธีใช้งาน-SETUP.md   # end-user guide (Thai)
├── CLAUDE.md            # this file
└── DEV.md               # pointer to CLAUDE.md
```

---

## 5b. Version control

`git init` on 2026-11-18, branch `master`, no remote. **What is tracked is code and docs only.**

| not tracked | why |
|---|---|
| `config.json`, `log.json` | Written continuously by the running app. Keeping them out means a code-side `git checkout .` or `git stash` can never wipe a setter's markers or a taping's log — the one thing in this project with no other copy. |

> ⚠ **`git clean -xdf` deletes all of it.** `-x` means "also remove ignored files", so the one
> command people type to tidy a repo removes `config.json`, `log.json` AND `songs/` — verified
> with `--dry-run`. Being untracked protects the data from `checkout` and `stash`; it is exactly
> what exposes it to `clean -x`. Use plain `git clean -df` (no `-x`) in this repo, or name paths.
>
> Same trap in human form: "delete the folder and install fresh" is the instinct this layout
> punishes, because the questions are **siblings of the app bundle, not contents of it** (§5). An
> update in place is already a clean program swap — every program file is moved to `backups/` and
> replaced, nothing is merged — so deleting first buys nothing and risks everything. §15's
> installer exists so that the safe path is also the easy one.
>
> This folder is also a **dev** folder: `native/` alone is ~950 MB of build output, and
> `CLAUDE.md` is for whoever edits the code. None of it belongs on a crew machine. The thing to
> hand over is the release zip (§15), into a folder of its own.
| `songs/` | ~29 MB of commercial music, and nothing in it is needed to build. |
| `songs/*/round.json` | An export artifact (§8e), regenerated by "ส่งต่อ". |
| `native/.build/` | ~900 MB of SwiftPM output. |
| `dist/` | Release zips — a bundle inside a zip, regenerated by `native/release.sh` (§15). |
| `backups/` | The installer's pre-swap copies of the operator's own data (§15). |
| `RGF Intro Player.app/` | Built by `native/build.sh`. **`IntroPlayer.app/` IS tracked** — it holds no compiled code, only a bash script and an icns (§6b). |

> So git protects the program, **not the questions**. The backup path for the data is still copying
> the round folder (§8e) — that is the unit the whole handover design is built on.

## 5c. The launch snapshot (`Snapshot.swift`)

§13 named this the one real data gap left, and this is the half of it that is now closed.

`config.json` and `log.json` are deliberately untracked (§5b), which is what stops a code-side
`git checkout .` from wiping a setter's markers — and the installer's `backups/` only fires
during an update, which makes it an **undo for the update, not a backup**. Between updates the
questions lived in exactly one place.

On every launch, `AppModel.init` copies both files into `backups/snapshots/<stamp>/` with a
plain-text `อ่านก่อน.txt` saying which build wrote it and how to restore. Twenty are kept; the
oldest are pruned.

| | |
|---|---|
| **covers** | `git clean -xdf` (which §5b measures as deleting `config.json`, `log.json` **and** `songs/`), a bad hand-edit, a bug in this app, `🗑 ล้าง log` or `↺ รีเซ็ตเล่นแล้ว` pressed by mistake, an import of the wrong round |
| **does NOT cover** | losing the folder or the disk — the snapshots sit *inside* the folder whose loss is the risk |

That second row is why `_settings.backupDir` exists: set it to a path in a synced folder and
every snapshot is copied there too, which is the half that actually survives. It is empty by
default because where an operator's questions are allowed to travel is their decision.

> §13 warns that anything claiming "it always backs up for you" must be bounded or it makes the
> gap *feel* closed. `--snapshot` prints both rows of that table every run, for that reason.

Three properties that are load-bearing rather than tidy:

- **The bytes are read synchronously in `init`, before anything else there can save; only the
  writing is detached.** The point of a launch snapshot is the state *before* this run touched
  anything, and an async read would race `store`'s own first write — preserving the result
  instead of the input. Verified on the real app: launching it rewrote `writtenBy`,
  `lastRanVersion` and `theme`, and the snapshot taken that launch holds the values from before.
- **A snapshot identical to the newest one is skipped.** Without it, twenty quiet launches would
  push the twenty real ones out of the ring. Measured: a dozen diagnostic launches produced two
  snapshots, 24 KB in total.
- **It never alarms.** A failure appears in About and in `--snapshot`, nowhere else — §8f's rule
  that on a show day a missing backup must not produce a dialog, a toast or a retry. A snapshot
  that *did* write is not news worth a banner either.

## 6. Server (`server.py`)

A single threaded `http.server` handler. Key points:

**Endpoints**
- `GET /` and `/index.html` → serves `index.html`.
- `GET /api/songs` → `{"songs": [...]}`, **paths relative to `songs/`** (POSIX separators), found by
  walking `songs/` recursively, sorted case-insensitively. Hidden files/dirs skipped. A file sitting
  loose in `songs/` yields a bare filename, exactly as the old flat listing did.
- `GET /api/config` → contents of `config.json` (`{}` if missing/invalid).
- `POST /api/config` → overwrites `config.json` with the posted JSON body (pretty-printed, UTF-8).
- `POST /api/hello` → `{id}` heartbeat; returns `{"clients": n}` live windows. See §12.
- `GET /api/log` → `{"events": [...]}` from `log.json` (empty list if missing/invalid).
- `POST /api/log` → `{op}` of `append` (with `event`), `undo`, or `clear`. Returns the full updated
  list. **Append-only, server-side clock** — see §8d for why this differs from `/api/config`.
- `GET /songs/<file>` and `GET /se/<file>` → static audio with **HTTP Range support** (206 Partial
  Content). Range is required so the browser can seek/scrub and so Reveal can jump instantly.

**Notable details**
- `_serve_file()` implements Range parsing manually (stdlib `SimpleHTTPRequestHandler` doesn't do
  206). Streams in 64 KB chunks.
- `_safe_join()` normalizes the path and blocks traversal outside `songs/`/`se/` (returns 403).
- `ThreadingMixIn` + `allow_reuse_address` so multiple audio range requests don't block each other.
- Logging is silenced (`log_message` overridden).

Server is essentially "done" — most future work is client-side.

---

## 6b. `IntroPlayer.app` (launcher bundle)

The GM-facing entry point. **It contains no compiled code** — the "executable" is a bash script, so
there is still no build step and no Xcode dependency. Structure:

```
IntroPlayer.app/Contents/
├── Info.plist              # CFBundleExecutable=IntroPlayer, CFBundleIconFile=AppIcon
├── PkgInfo                 # "APPL????"
├── MacOS/IntroPlayer       # bash launcher (chmod +x)
└── Resources/AppIcon.icns  # generated, see below
```

What the launcher does, in order:
1. Resolves `APP_ROOT` as `$0/../../..` — i.e. **the bundle must stay in the same folder as
   `server.py`**. If it can't find `server.py`, it shows an `osascript` alert (there is no Terminal
   to print to) and exits.
2. Picks `python3`/`python`; missing Python produces an alert naming `xcode-select --install`.
3. **Refuses to open a second window.** If `pgrep -f -- "--user-data-dir=$PROFILE"` finds a live UI,
   it shows an alert and exits — see §12 for why two windows are destructive. The test is on the
   *profile*, not the port: the server may legitimately be up with no window (started by hand).
4. If port 8000 already answers, reuses that instance and does **not** kill it on exit. Otherwise
   starts `server.py` detached, logging to `~/Library/Logs/IntroPlayer.log`, and waits (up to 6 s)
   for the port to come up.
5. Runs `caffeinate -d -i -w <server pid>` so the Mac and its display stay awake exactly as long as
   the server lives — no stray assertion left behind if the app is force-quit.
6. Opens Chrome (or Edge) with `--app=<url>` and a dedicated `--user-data-dir` under
   `~/Library/Application Support/IntroPlayer/browser`. That gives a window with no tab bar and no
   address bar, and keeps the operator's own tabs, extensions and notifications out of the taping.
7. Blocks on `pgrep -f -- "--user-data-dir=$PROFILE"` rather than on the PID it spawned, because
   Chrome may hand off to an existing process for that profile and return immediately. When the
   window closes, the `trap` kills the server (TERM, then KILL after 1 s).

**No Chromium browser installed** → falls back to `open <url>` in the default browser plus a
blocking `osascript` dialog with a single "หยุด IntroPlayer" button, since in that case there is no
window whose lifetime the script can follow.

**Icon.** `./native/change-icon.sh <square-1024.png>` is the whole procedure — it rebuilds the
`.icns` and installs it into **both** bundles plus the master at `native/AppIcon.icns`, which is
the copy `build.sh` reads first so a rebuild cannot revert it. `index.html` carries a matching
inline-SVG data-URI favicon, which the script does NOT touch.

> Superseded: this used to say the generating script was not kept and the icon had to be
> regenerated by hand. `native/change-icon.sh` and the `MakeIcon` SwiftPM product have existed
> since the rename; the end-user procedure is in `วิธีใช้งาน-SETUP.md`.

The default mode scales the source into a **824/1024 rounded rect** before masking, which is
Apple's own proportion. Artwork that already fills its canvas edge-to-edge — which is what a
designer naturally produces, and what the icon shipped here was — then renders visibly larger
than every neighbour in the Dock. `--full` skips that step and is only right for a PNG already
framed and padded to Apple's proportions; "it already has rounded corners" is not the same thing
and is the easy mistake. Double-rounding is not a risk in the default path: the mask radius at
824 is larger than a source's own corner radius scaled down, so the source's corners are cut
away entirely rather than leaving nicks.

> **Quit the app first.** The script `codesign`s each bundle in place, and doing that to a
> running app invalidates the signature of a live process. The script does not check.

> **Two Dock icons.** The bundle shows its own icon; the Chrome `--app` window shows Chrome's. The
> bundle icon is the one to quit. Not worth solving — a single-icon setup would mean either a real
> Cocoa/WKWebView app (needs Xcode) or Safari's "Add to Dock", which cannot start the server.

> **Gatekeeper.** The bundle is unsigned and un-notarized. First launch needs right-click → Open.
> Copying the folder to another Mac re-triggers the quarantine prompt.

---

## 6c. `RGF Intro Player.app` — the native rewrite (`native/`)

A full SwiftUI/AppKit port of the GM app. **It is now the primary way the tool is run**; the web
version (§6, §8) is kept working as the fallback, and both read and write the *same*
`config.json` / `log.json` in the project root, so the operator can switch mid-taping.

```
native/
├── Package.swift                  # SwiftPM executable, macOS 13 target, no .xcodeproj on purpose
├── build.sh                       # builds + assembles "RGF Intro Player.app"
├── Info.plist
└── Sources/IntroPlayerNative/
    ├── App.swift          @main, headless diagnostic flags
    ├── AppModel.swift     the single ObservableObject the whole UI reads
    ├── Player.swift       AVAudioEngine graph + the playback state machine (§10)
    ├── Analysis.swift     envelope, prefix sums, intro-onset detection, K-weighted
    │                      sub-blocks for gated LUFS (§7a/§7a1/§7a3)
    ├── Loudness.swift     BS.1770-4 K-weighting + gating; the slow reference measurement (§7a3)
    ├── AutoDetect.swift   chromagram, Intro End and Hook detection (§7a4)
    ├── Artwork.swift      cover art: embedded first, network only as a guarded fallback (§8f)
    ├── PaletteCheck.swift contrast / ΔL* / deutan ΔE2000 maths for --palettetest (§6d)
    ├── Store.swift        config.json + log.json, same schema as the web app (§9, §8d)
    ├── Snapshot.swift     a copy of the questions, taken at launch — §5c
    ├── Library.swift      songs/ scan, path helpers, columns, Diagnostics
    ├── Handoff.swift      round.json, pre-flight checks, import plan/diff (§8e)
    ├── HandoverPanel.swift export sheet, diff/accept sheet, receive banner
    ├── Version.swift      the stamped version, and the NUMERIC semver compare (§15)
    ├── Updater.swift      manifest fetch, download/verify/apply, breadcrumb (§15)
    ├── AboutPanel.swift   About sheet, update banner, schema-ahead banner (§15)
    ├── Typography.swift   the Thai font cascade and type scale (§6d). NOTE: `Palette`
    │                      itself lives in WaveformView.swift, not here.
    ├── ContentView.swift  3-pane layout, header, the NSEvent key monitor
    ├── CenterView.swift / SetupPanel.swift / WaveformView.swift / LogPanel.swift
    └── Feedback.swift     PressStyle, pulseTarget, confirmDestructive
```

### Build

> **The bundle name has a space**, so every command below quotes it:
> `BIN="./RGF Intro Player.app/Contents/MacOS/IntroPlayerNative"`.

```bash
./native/build.sh          # release, universal (arm64 + x86_64)
./native/build.sh debug    # this machine's arch only, for iterating
./native/release.sh        # build + package dist/IntroPlayer-<ver>.zip to hand over — §15
./native/installer-test.sh # 123 assertions on the installer; needs dist/ — §15
```

`build.sh` assembles into `RGF Intro Player.app.new` and swaps at the end, so a failure part-way
cannot leave you with no app (the old script `rm -rf`'d the bundle first). It also ad-hoc codesigns
so macOS stops re-prompting after each rebuild, and prints the architectures it produced.

### Headless diagnostics

```bash
BIN="./RGF Intro Player.app/Contents/MacOS/IntroPlayerNative"
INTROPLAYER_DIAG=1 $BIN --analyse      # per-song duration, detected intro start, whole/intro RMS
INTROPLAYER_DIAG=1 $BIN --playtest     # asserts playback stops AT introEnd (overshoot must be 0)
INTROPLAYER_DIAG=1 $BIN --columns      # ASCII waveform at 3 zoom levels
INTROPLAYER_DIAG=1 $BIN --resetflow    # drives resetPlayed() end to end
INTROPLAYER_DIAG=1 $BIN --rescantest   # folder added while running → must appear after rescan
INTROPLAYER_DIAG=1 $BIN --resettest    # ISO date parsing / session boundary
INTROPLAYER_DIAG=1 $BIN --preflight    # the handover checklist, per round (read-only)
INTROPLAYER_DIAG=1 $BIN --titles       # raw filename vs cleaned display title (read-only)
INTROPLAYER_DIAG=1 $BIN --handoff      # export → on-site edit → plan → accept AND reject
INTROPLAYER_DIAG=1 $BIN --revealtest   # Reveal plays on; the intro guard RE-ARMS afterwards (§10)
INTROPLAYER_DIAG=1 $BIN --grabtest     # the two-stage marker rule, incl. the stacked-marker case
INTROPLAYER_DIAG=1 $BIN --palettetest  # contrast, ΔL* ladder and deutan ΔE for BOTH themes (§6d)
INTROPLAYER_DIAG=1 $BIN --loudtest     # BS.1770 coefficients, on-air spread, limiter headroom
INTROPLAYER_DIAG=1 $BIN --autodetect   # guessed Intro End / Hook vs configured, with evidence
INTROPLAYER_DIAG=1 $BIN --guesstest    # can the guess feature damage anything? (read-only)
INTROPLAYER_DIAG=1 $BIN --snapshot     # the launch backup: writes one, prunes, proves the dedup
INTROPLAYER_DIAG=1 $BIN --guessflow    # the admission rule, with a REAL playing player (§7a4)
INTROPLAYER_DIAG=1 $BIN --artwork      # where each cover comes from; never makes a request
INTROPLAYER_DIAG=1 $BIN --remodetest   # marker edits DURING playback must never outlive Intro End
INTROPLAYER_DIAG=1 $BIN --takes        # take model self-check, then the real log's running order
INTROPLAYER_DIAG=1 $BIN --timefmt      # typed-field parser: round-trip, accepts, rejects (read-only)
INTROPLAYER_DIAG=1 $BIN --overview     # overview strip: same data as columnPeaks, caches independent
INTROPLAYER_DIAG=1 $BIN --updatecheck  # semver compare, feed resolution, blocked URL schemes (§15)
INTROPLAYER_DIAG=1 $BIN --updatestage  # download + unpack + verify a real release, then delete (§15)
$BIN --version                         # NOT gated: writes nothing, and is the flag a support
                                       # call asks for
```

`--handoff` is the only end-to-end proof that `base` is stamped by the handover and not by
editing, and that a rejected row keeps the local value while an accepted one takes the sender's.
Run it after any change to `Handoff.swift` or `Store.swift`.

**`INTROPLAYER_DIAG=1` is required.** `--resetflow`, `--rescantest`, `--resettest` and `--handoff`
**write to
the operator's real `config.json` / `log.json`** — back both up before running them and restore
afterwards (`--handoff` also leaves a `songs/<round>/round.json` to delete). Without the env var
the flag is refused with exit 2, so a stray argument can't reset a taping.

> **Do not drive the running app with synthetic keystrokes** (`osascript`, `key code …`). If the
> target app isn't frontmost the keystroke lands in whatever is, which during this work meant
> typing into an unrelated project. Verify through the headless flags instead.

### AppKit/SwiftUI traps this app actually hit

These are not style notes — each one was a user-visible defect.

- **A `Timer.publish` stored in a View is useless here.** `ContentView` is re-initialised on every
  model publish, so the publisher was recreated and resubscribed each time; measured **1 tick in
  2 s** while `Player` published at 50 Hz. `followPlayhead()` was therefore dead exactly during
  playback. The heartbeat is now `Player.onTick`, fired from the guard timer, which runs regardless
  of what the window is doing (same reasoning as the web version's `guardId`, §8b).
- **A `.overlay` is hit-testable.** The toast sat over the bottom-centre of the window — i.e. over
  ✓ Correct — and killed the lower half of the two most important buttons in a taping for 2.4 s
  after any message. Overlays that are decoration need `.allowsHitTesting(false)`; that includes
  `RoundedRectangle().stroke()` borders, which were eating waveform seek clicks along the edge.
- **`.buttonStyle(.plain)` hit-tests the glyphs only** — every button needs
  `.contentShape(Rectangle())` or only the text itself is clickable.
- **Scroll events are routed by hit-testing.** An NSView that overrides `scrollWheel(with:)` must
  claim the cursor, which would swallow the SwiftUI drag/click gestures on the same surface;
  returning `nil` from `hitTest` fixed the clicks and silently killed the zoom. `WheelCatcher` now
  only reports its rect and a **local `NSEvent` monitor** (`.scrollWheel` + `.magnify`) filters on
  it. Note AppKit's `scrollingDeltaY` is the **opposite sign** to the DOM's `deltaY`.
- **`NSEvent.addLocalMonitorForEvents` must be nil'd on removal.** `installKeyMonitor` guards on
  `keyMonitor == nil`, so forgetting that left every shortcut permanently dead after one
  disappear/reappear cycle.
- **The key monitor is global, so it fires over sheets too.** With the log panel open, `1`/`2` were
  appending real log events to the song hidden behind it. The handler now bails on `showLog`.
- **Don't write a `@Published` from inside a layout pass** (`onAppear` / `onChange(of: geo.size)`) —
  `AppModel.setWide` defers it and skips no-op writes.
- **`ForEach(…enumerated(), id: \.offset)` reuses views against the wrong model** after a removal.
  `LogEvent` is `Identifiable` with a `t + path + event + dup` id.
- **`ISO8601DateFormatter.date(from:)` costs ~26 µs** and the badge logic called it thousands of
  times a second. `LogEvent.date` is parsed once at load; `status(of:)` is memoised behind
  `invalidateStatus()`; `resetAt` is parsed once into `resetAtCache`.

---

## 6d. Type and colour (`Typography.swift`; `Palette` is in `WaveformView.swift`)

Two things here were **measured, not chosen by eye**, and both are easy to undo by accident.

### `.font(.system)` does not render this app's Thai in SF

CoreText resolves Thai to **`.ThonburiUI-Regular`** (verify with `CTRunGetAttributes`). ThonburiUI
ships three weights, so `.medium`, `.semibold`, `.bold` and `.heavy` **all collapse onto
`ThonburiUI-Bold`** — the app had two usable Thai weights, not five, and no hierarchy was even
expressible. Its mark zone also overflows the declared ascent at 13 pt, clipping tone marks.

The fix is a **cascade, not a font swap**: SF stays the base descriptor (Latin, metrics, tabular
digits) with `SukhumvitSet` as the Thai fallback. Measured at 13 pt:

| | ascender | descender | line box |
|---|---|---|---|
| SF base (what the app had) | 12.57 | −2.74 | 16.0 |
| **SF + SukhumvitSet cascade** | **12.57** | **−2.74** | **16.0 — identical** |
| `NSFont(name: "SukhumvitSet-Text")` directly | 14.34 | −6.16 | 20.0 (**+25 %**) |

So the cascade costs **zero layout change**. Using the face directly inflates every row by a
quarter — don't "simplify" it to that. `SukhumvitSet.ttc` is in
`/System/Library/Fonts/Supplemental/` on every macOS 13+, so this adds no dependency. (Sarabun is
NOT — it is a downloadable asset, missing on the next Mac.)

### No Thai below 12 pt (`Typo.thaiFloor`)

Rasterised at 1×, the mark stack of `ตั้งค่าแล้ว` is a single ~25 %-coverage row at 10–11 pt: `่`
and `ั` fuse into a grey smear. This machine is a 2560×1080 LG WFHD — **`scale = 1.0`, ~81 PPI** —
so there is no Retina margin to hide it. It matters most for `✗ ไม่มีคนตอบ` vs `✓ ตอบถูก`: a burned
question misread as a usable one defeats the whole point of the log (§8d). `Typo.font` clamps for
you; pass `latinOnly: true` only for Latin micro labels like `Space` or `1xx`.

### One meaning per hue

Before this, **green meant four things** (configured badge, Intro End marker, intro-range fill,
Correct), **amber six** (Wrong, free mode, played, Ignore Intro End, save failure, Hook) and cyan
four. The state that can put a whole song on camera cannot share a colour with "this was played".

| hue | the only meaning |
|---|---|
| `accent` blue | transport, "playing the intro" |
| `cyan` | the Intro bracket — **both** ends, told apart by which edge the flag sits on |
| `green` | a human answered correctly. Nothing else. |
| `red` | wrong / burned question, and destructive controls |
| `amber` | **the intro-end stop is not armed, or something is wrong.** Nothing else. |
| `purple` | Reveal, and the Hook marker it jumps to |
| `onsite` magenta | changed after the handover |

Three measured constraints behind that table:

- **`accent` vs `purple` collide at deutan ΔE 1.2** — literally the same colour to a deutan
  viewer. Blue-vs-purple can therefore *never* be the only carrier of the armed/disarmed bit; the
  guard strip uses amber **plus a word**, and amber is ~24 ΔL\* from both.
- The outcome pair must be **saturated green + saturated red** (deutan ΔE 35.5). Two pastels
  collapse to 9.6, and the palette this replaced sat at **7.3** — that was `✓ Correct` vs
  `✗ Wrong`, the two biggest buttons in the app.
- Grey ladder steps are now 5.5–6.9 ΔL\* (they were 4.2–4.4, which reads as one flat field at 1×),
  and `float` sits 19 L\* above `panel` so a sheet reads as above its pane. `LogPanel` used to be
  `Palette.panel` — the identical value to the panes behind it.

> The ΔE figures above came from whatever tool measured them originally. `--palettetest` uses
> its own model (CIEDE2000 + Viénot 1999 deutan), so its absolute numbers differ — it reports
> green-vs-red as 11.9 in dark, not 35.5. **Compare within one model, never across.** What the
> check enforces is the relationship, not the constant.

### Two themes (`--palettetest`)

`Palette` resolves every value through `NSColor(name:dynamicProvider:)`, so one definition
serves both themes and no view has to observe the setting to repaint. The theme is set by
`NSApp.appearance` **and** `.preferredColorScheme` — set only one and AppKit chrome and SwiftUI
content can land on different themes.

**A light theme is not an inversion**, and trying to make it one fails this palette's own tests.
Dark's deutan separation comes from the **lightness spread** (green L\* 74.6, red 54.6, amber
82.7); a white ground forces every accent down to roughly L\* 46 for contrast, which flattens
that spread and destroys it. Measured on a first attempt: green-vs-red fell from 11.9 to 6.5.

Solving under the real constraints instead gives a light theme that is **better** on the pair
that matters — deutan ΔE **23.9** green-vs-red (dark 11.9) and **27.5** for the badge text
(21.3) — because a white ground actually leaves more usable lightness range below it than a
dark ground leaves above.

One rule had to be restated rather than met. §6d above says amber sits ~24 ΔL\* from `accent`
and `purple`; on a white ground the search for that comes back **empty**. That ΔL\* was a bonus
property, not the mechanism: amber is YELLOW against a BLUE accent, and deutan leaves the
blue-yellow axis intact. The real separation is ΔE 67 in light (74 in dark), and the carrier of
last resort is still the word next to it.

`--palettetest` measures both themes in Swift — 64 assertions over the ladder, text contrast,
fill-vs-surface, `ink`-on-fill, the tinted chips, and the deutan pairs.

> `Palette.audit` is the list it measures, and it must name **every** value. It first shipped
> naming none of the ten tints the theme added, so the suite passed 44/44 while measuring
> nothing the change introduced. Completing it immediately found four places at 3.66:1 —
> accent text on a tint of its own hue, which cannot work: a tint and its accent are close in
> hue by construction, so only lightness can separate them and the tint has already spent it
> staying distinct from the surface behind it. Hence `cyanOnTint` / `amberOnTint` / `redOnTint`. It also **pins the accent/purple collision
as expected** (ΔE < 6), so nobody "fixes" it and quietly re-invites blue-vs-purple to become the
only carrier of the armed bit.

Three things the theme work exposed, each invisible until the colours moved:

- The header bar's save-failure text was `Palette.amber` on `Palette.header`. In light that
  measures **1.2:1** — unreadable, on the one indicator meaning a day of markers is being lost.
  That bar is dark red in BOTH themes, so what sits on it must not flip: `onHeader` /
  `onHeaderWarn` are fixed-light.
- The playhead is a 4 px dark hairline under a 2 px white core, and the hairline was `ink` —
  which inverts. The playhead went **white-on-white**. `Palette.outline` is now separate from
  `ink` for exactly this reason.
- `PressStyle`'s white wash and the pulse ring vanished on light surfaces. §12 is explicit that
  a keypress has to LOOK like a click, or a dead shortcut is indistinguishable from a working
  one. Both now read `@Environment(\.colorScheme)` and reverse.

And one straight §6d violation it made obvious: `Markers.all` still coloured **Intro End green**
while the waveform drew it cyan. Green has one meaning, and §6d names "Intro End marker" among
the four it was supposed to have given up. Bright green vs bright cyan hid it; dark green vs
dark teal did not.

> **Dark is the default and that is not a style preference.** The operator's position is a dim
> corner of a studio; a white 2560×1080 panel at arm's length is a light source pointed at the
> person who has to watch the stage. Light is for the setter at a desk. An unreadable `theme`
> value falls back to **dark**, not to the system, so a garbled settings file cannot put a white
> screen in front of the operator mid-taping.

## 7. Audio pipeline (important)

Two independent uses of Web Audio:

### a) Waveform + loudness analysis (`loadWaveform` → `buildEnvelope`)
On song select, the file is fetched as an ArrayBuffer and `decodeAudioData`'d in a throwaway
`AudioContext` (immediately `close()`d). One pass over the decoded channel produces:
- `env` — peak amplitude per ~1 ms bucket, for the canvas waveform (see §8b).
- `sqPrefix` — a `Float64Array` cumulative **sum of squares**, so `rmsRange(t0,t1)` is O(1).

This does **not** touch playback; it's analysis only. The decoded buffer is dropped afterwards.

### a1) Auto-detected Intro Start (`detectIntroStart`)
A song with no markers yet gets its `introStart` guessed from where the music actually begins, so
the GM never opens a song whose intro is 8 seconds of silence. Applied in `loadWaveform`, and
re-runnable from the 🎯 button next to Intro Start. Moving the start **keeps the intro's length** —
the GM picks a duration, not an end point.

**One threshold cannot do this job**, which the real library proves: song 103 carries 0.0118 of tape
hiss in its first second, while song 107's actual opening notes are only 0.0066 — the noise in one
file is louder than the music in another. So it runs two stages:

1. Find a **confident loud onset**: short-window RMS above `max(songRms*0.08, 0.004)`, sustained for
   `ONSET_HOLD` (60 ms) so a click can't trip it.
2. **Walk backwards** from that onset while anything audible continues (`quietThr`), stopping at the
   first real gap. This recovers a quiet lead-in without being fooled by hiss — the silence in front
   of the music is what stops the walk.

Then subtract `PRE_ROLL` (0.25 s) so the first note isn't clipped. Measured against the first
audible sound across all 9 songs, the result lands within ±0.2 s on 7 of them; the two outliers are
a hiss-prefixed file (correctly skipped) and a slow fade-in (0.85 s in).

> `auto:true` marks the guess. `isConfigured()` must check it **before** the value comparison —
> an auto start moves `introStart`/`introEnd` off their defaults, which would otherwise light up the
> green "set" badge and claim the GM had configured the song. `afterCfgChange()` clears the flag
> (and removes the on-screen note, since it doesn't re-render the setup panel).

### a2) What the auto-gain measures (`measuredRms`)
`loudnessScope` (`config._settings.loudnessScope`, default **`'intro'`**) picks the window:

- **`'intro'`** — RMS of `[introStart, introEnd]`, i.e. *only the audio the audience actually hears*.
- **`'song'`** — RMS of the whole file (the original behaviour).

Why the default changed: the GM only ever plays ~15 s of intro, but the old code averaged the whole
file. Songs with a soft intro and a loud chorus therefore measured "loud" and got **under-boosted on
exactly the part that airs** — and since intros are usually the sparse part of a track, the error
skews one way, quiet.

Measured on the first 8 songs of the library (intro taken as 0–15 s, the default range):

| scope | on-air intro level, spread across the 8 songs |
|-------|-----------------------------------------------|
| whole song (old) | **9.4 dB** — from −8.2 dB to +1.1 dB off target |
| intro range (new) | **0.0 dB** — every song lands on `TARGET_RMS` |

Zero is expected, not suspicious: when the measurement window is the playback window, the gain is
by construction `TARGET_RMS / measured`. It only drifts off target when the ±12 dB clamp bites or
the fallback kicks in.

`measuredRms()` falls back to whole-song when the intro range is shorter than `MIN_SCOPE_SEC`
(0.5 s) or quieter than `MIN_USABLE_RMS` (0.005) — a silent lead-in would otherwise divide into
the maximum +12 dB boost. The reason is surfaced in the UI under the scope buttons (`#scopeNote`).

Because the intro range *is* the measurement window, `afterCfgChange()` calls `applyGain()`: moving
a marker re-levels the song. Gain is deliberately **not** re-applied during a marker drag — writing
`gainNode.gain.value` mid-playback would click.

> **Migration note:** any `trimDb` set before this change was dialled in against whole-song
> measurement, so those songs are now corrected twice. Re-check trim on songs that carry one, or
> flip the scope back to "ทั้งเพลง".

### a3) It measures gated LUFS, not RMS — and what that did NOT fix

`Analysis.targetRms` / `measuredRms` are still there and still drive the **web** version. The
native app targets **BS.1770-4 gated LUFS** (`Loudness.swift`). The whole question was answered
by measuring first; `--loudtest` reproduces it.

**What was already right.** §7a2's choice to measure the intro rather than the whole song is the
big win and it stands. Reading channel 0 alone is also fine — ≤0.98 dB from a phase-insensitive
power mean across the library.

> A first pass reported that error as **4.37 dB**, which would have been a wrong finding acted
> on. It came from folding to a coherent `(L+R)/2` downmix, where a wide stereo mix cancels
> against itself. BS.1770 sums channel **powers** for precisely this reason. If you re-measure
> anything here, check what your "mono" is.

**What was worth changing, modestly.** Un-weighted RMS over-weights bass energy, which is what
a sparse intro is made of. Measured across the real nine songs, RMS left **2.6 LU** of spread
in what the audience hears. Targeting gated LUFS closes it — 8 of 9 land on −15.00 LUFS, spread
**0.00**. `targetLufs` was chosen as the level the RMS path was already delivering, so the set
is re-levelled against itself without moving the show's output level under the operator.

**What was actually broken, and no metric fixes it.** The gain was computed with **no reference
to the audio's peak at all**, so the two quietest intros — the ones this feature exists for —
asked for more than fits under the limiter's −1 dBFS wall and were squashed instead of raised:

| | asks for | limiter takes back |
|---|---|---|
| 102_BOWKYLION | +6.12 dB | 1.4 dB |
| 107_PROXIE | +12.0 dB | **9.5 dB** |

> **`kLimiterParam_PreGain` is not a threshold**, and assuming it was made every one of these
> figures 2 dB too big on first writing. Rendering the real graph offline and sweeping it shows
> the output is exactly `input + gain − 1.0 dB` up to a nominal **+1.0 dBFS**, where limiting
> begins — so the pre-gain is a flat 1 dB attenuation and the knee is at +1, not −1.
>
> The 2 dB mattered: it put song 102 at 3.4 dB against the pre-flight's 2.0 dB threshold, i.e.
> a `squashedIntro` warning on a song the limiter never touches. §12 already records that
> lesson under `previewArmed` — a warning that fires when nothing is wrong is one that gets
> ignored on the day it matters. **If you change the limiter's parameters, re-measure this
> constant by rendering the graph; do not read it off the parameter names.**
>
> Two more in the same place. The headroom peak must come from the **intro range always**, not
> from the measurement scope — following `loudnessScope: song` took the peak from a mastered
> track's ~0 dBFS and reported every song as squashed. And it must cover **every channel**:
> `env` is channel 0 (right for drawing), but the gain is applied to all of them, and a
> hard-panned transient on the right measured 1.4 dB low on song 106.

The level card said +12.0 and the audience heard about +0.5, plus pumping. The gain is
deliberately **not capped** — a brief transient meeting a brick wall is what a limiter is for,
and silently lowering what goes on air is not ours to decide (§15: fail visible, not shut). It
is surfaced instead: an amber line in the level card, and a `squashedIntro` row in the handover
pre-flight, which is where a setter reviews problems before handing a round over.

107 is really a **markers** problem: its intro measures −35.9 LUFS with a −1.5 dBFS peak, and a
38 dB crest factor over 15 seconds is not music — it is near-silence plus one transient.

**Implementation.** `Analysis` builds K-weighted 100 ms sub-blocks during the decode pass it
already does (~21 KB for a four-minute song), so gated LUFS over any range is free and a marker
edit can re-level without re-reading the file. `Loudness.measure` stays as a slow file-reading
reference and `--loudtest` cross-checks the two.

> That cross-check first reported a 0.72 LU disagreement on song 107. Neither was wrong: the two
> used different 100 ms block **phase**, and on near-silence a shifted grid changes which blocks
> clear the gates. The reference is snapped to the same grid now. A cross-check that compares
> two slightly different things is worse than none, because it teaches you to tolerate a delta.

Coefficients are derived per file rate — the library is 44.1 kHz and BS.1770 tabulates 48 kHz
only — and asserted against the published table to 1e-10.

### a4) Guessing Intro End and the Hook (`AutoDetect.swift`)

A round used to open with every song claiming `hook: 60.00`, a number from nowhere that for any
song under a minute sent Reveal past the end of the file. §8e measured the real cost: **8 of 9
songs still sat on the default**, i.e. the hook step was being skipped in practice.

`AutoDetect` builds a 1 Hz chromagram and loudness curve (vDSP FFT at 16384 samples /
`framesPerSecond = 4`, then averaged down to 1 Hz — every index in `introEnd` and `hook` is a
second, so don't read `framesPerSecond` as the feature rate). Chroma is **mean-centred before
L2-normalising**, per second rather than per frame, which is what makes a quiet reprise of the
chorus match the loud one.

> `similarity` returns a mean **correlation**, so its range is **−1…1, not 0…1** — the
> mean-centring is exactly what buys the negative half. Real music lands in 0.82–0.98, which is
> why the walk-back threshold sits in such a narrow band: **0.85 is mid-range, not loose.** A
> comment claiming 0…1 shipped for a while and is the kind that makes the next person "relax"
> a threshold that is already central.

- **Intro End** — the first clear step up in level after the start, which in practice is the
  beat or the vocal arriving. Clamped 8..30 s. There is no musical truth here: the intro is how
  hard the GM wants to make it, and the clamp is a guess-bound, not a claim. The real library
  has one human-set intro of **38 s**.
- **Hook** — the most-repeated loud section, i.e. the chorus.

Three things in the hook detector were found by measuring, not by reasoning, and each looks
fine in code:

1. **Raw chroma cosine is useless here.** Every candidate in every song scored 1.41–1.44,
   because raw chroma is overwhelmingly positive and all of a pop song points the same way — so
   "most repeated section" was really "loudest 8 seconds" wearing a hat. **Mean-centring** turns
   the dot product into a correlation and the scores spread to 0.82–0.98.
2. **The best-scoring window is usually the LAST chorus** — loudest, and with the most earlier
   copies to match against. Reveal wants the first clean one, so it walks back to the earliest
   window that is the same section.
3. **Similarity cannot carry a usability constraint.** At a 0.80 match threshold the walk-back
   landed on the first *verse* (101 and 301 picked a hook 3 s after the intro); at 0.90 nothing
   matched for 106 and it stayed on the final chorus at 175 s of a 190 s track. Fixed with two
   explicit bounds that are about the **verb**, not the music: a hook must be ≥ 8 s past Intro
   End (or Reveal replays what the contestants just heard) and inside the first 75% (or there is
   nothing left to play into).

Finally it snaps to the nearest chroma-novelty peak — Reveal landing mid-phrase sounds like a
mistake even when the section is right.

> **Not validated against ground truth, and `--autodetect` says so.** The library has three
> hooks that differ from 60 at all and all three are within 5 s of it — they look like nudges of
> the default, not annotations. So the diagnostic prints guess, configured value and evidence
> side by side for judging by ear, and asserts only what is objectively checkable: inside the
> song, after the intro, and actually repeating.

Everything written stays `auto`, so the song stays in the `Return`/`Tab` review sweep and in the
pre-flight until a human confirms it. ~0.25 s per song in release.

> **Measure this in release.** The same pass takes ~5 s in a debug build, and `build.sh debug`
> is what sits in the tree while iterating — a figure read off a debug diagnostic is 20× out
> and argues for a design the app does not need.

**There are two halves to this feature and they must obey one rule, not two.**
`applyAutoStart` guesses Intro Start (§7a1); `applyGuess` guesses Intro End and Hook. They
share a trigger, a selection-time callback, a button, and two of the three markers — and they
shipped with four guards on one half and **none on the other**. Every serious defect found in
the safety audit was that asymmetry. `AppModel.guessAllowed` is now the single admission rule
and both halves call it.

> **`isPlaying` is the wrong question, and this was the worst defect the feature has had.**
> Paused-on-a-buzz is `isPlaying == false` — and that is the most dangerous moment in a taping
> to move Intro End, because the next Space goes through `modeForPosition`, and a playhead now
> sitting *past* the new Intro End gives `.free`: no intro bound, the whole song out on camera,
> from a value nobody typed. §10's "arm only, never disarm" cannot catch it, because that
> protects `remode` and a guess never reaches `remode` — it only applies when stopped. So the
> question is whether a *question* is in progress, which makes the playhead's position part of
> it: a song parked at its own Intro Start is at rest, a song stopped anywhere else is one the
> operator is in the middle of.
>
> And the check belongs at the **write**, not at the trigger. A cancel fired when playback
> starts can always be raced by a task already inside its main-actor hop.

**A guess is never a review, whoever asked for it.** Both halves end by forcing
`auto = true, configured = false`. The old code restored the song's previous `configured` flag,
which looked conservative and was the hole: `applyAutoStart` runs *first* in the same button
press and stamped `configured = true`, so by the time `applyGuess` read that flag the song had
been certified on the strength of a machine guess — out of the `Return`/`Tab` sweep **and** out
of *both* pre-flight warnings (`stillAuto`, and `hookDefault` once the hook moved off 60). An
unreviewed round then passed the handover check while the toast on screen read "ตรวจดูอีกที".

Five rules constrain when it may write, and each exists because of a specific way it could
destroy work:

- **Never while that song is playing.** Moving Intro End under live playback is §10's forbidden
  shape. Song 102's guess is 11.0 s against a stored 15.0, so a guess landing mid-question
  would have cut the audio and jumped the playhead *backwards*; landing outward instead leaves
  the node bounded at the old value while the countdown reads the new one.
- **Through `updateConfig`'s clamps, undo and `remode`,** never `store.set`. It was the only
  marker write in the app that skipped all three — which also meant it could persist
  `introEnd <= introStart`, the state §12 calls the worst defect this app has had.
- **Fill blanks only.** `isConfigured` is false whenever `auto` is true, which is right for the
  green badge and wrong as a licence to overwrite: song 102 is `auto` only because
  `Store.decode` repaired its degenerate range, and it carries `hook: 62.03` — a number no
  default produces. An automatic guess may only write a field still exactly at its default.
- **Never on a round with a `base`.** A signed-off handover must not acquire "แก้ที่กอง" badges
  for edits nobody made; the return path would then export them as the operator's decisions and
  the setter's diff sheet accepts every row by default (§8e).
- **One task per path, recorded as done only on success.** Marking before the work, with a
  single shared task slot, meant holding ↓ through a round marked every song guessed while
  cancelling all but the last — the feature silently not happening. `AutoDetect.extract` has
  cooperative cancellation points for the same reason: without them a cancel discards the
  result but not the work.

### b) Playback graph (`ensureGraph`)
Created lazily on the **first play** (Web Audio needs a user gesture). Wiring:

```
<audio> element ─► MediaElementSource ─► GainNode ─► DynamicsCompressor (limiter) ─► destination
```

- **GainNode** = level only. Combined gain = `autoGain * trim` where
  `autoGain = clamp(TARGET_RMS / songLoudness, 0.25, 4.0)` when normalize is on (else 1), and
  `trim = dbToGain(config[song].trimDb)`. See `applyGain()`.
- **DynamicsCompressor** is configured as a brick-wall-ish limiter (threshold −1 dB, ratio 20) to
  stop clipping when a quiet track is boosted.

> **Audio-quality note (asked about during dev):** the source file is untouched, but the *output*
> passes through gain + limiter **at all times once the graph exists** — even when normalize is off,
> the limiter still sits in the path and will act on peaks ≥ −1 dBFS. This is inaudible in practice
> but not bit-perfect on the loudest passages. If bit-perfect output is ever needed (e.g. recording
> a broadcast), add a true bypass: when `normalizeEnabled === false && trimDb === 0`, connect
> `srcNode → destination` directly and skip gain+limiter. Currently NOT implemented (left as-is by
> product decision). SE sounds bypass the graph entirely (plain `new Audio()`), so they're always raw.

### c) Intro-end fade (`startIntroFade`)
When auto-stopping at `introEnd`, we fade the gain to ~0 so there's no hard click. The fade is
**offset to finish exactly at `introEnd`** (starts at `introEnd − FADE_SEC`, default 0.4 s), so audio
never plays past the intro range. Manual stop (Space/Reset) is instant, no fade (`cancelFade`).
After a fade the gain is left low and restored on the next play (avoids a pop while pausing).

---

## 8. Client architecture (`index.html`)

Everything is one file: `<style>`, markup (3-column layout: song list / center player / setup
panel), and one `<script>`.

### Key module-level state
- `songs` — array of filenames from `/api/songs`.
- `config` — the whole config object (see §9). Special key `_settings` holds app-wide settings.
- `current` — currently selected filename (or null).
- `mode` — playback intent: `'idle' | 'intro' | 'reveal' | 'free'` (drives the intro-end auto-stop).
- `env`, `envHz`, `globalPeak` — amplitude envelope for the waveform (see §8b).
- `view` — `{s,e}`, the visible time window in seconds. `colPeaks`/`colKey` cache it per pixel column.
- `songLoudness` — loudness cache, filename → RMS.
- `rafId` (drawing) and `guardId` (intro-end guard) — see §8b for why they are separate.
- `audioCtx`, `srcNode`, `gainNode`, `limiterNode`, `graphReady` — Web Audio graph.
- `normalizeEnabled` — master loudness toggle (persisted in `config._settings.normalize`).
- `fading`, `fadeTimer`, `FADE_SEC` — intro-end fade state.
- `dragKey` — which marker is being dragged on the waveform.

### Function map (grouped)
- **Load/render:** `init`, `renderList`, `selectSong`, `renderSetup`, `syncFields`.
- **Waveform/canvas:** `loadWaveform`, `buildEnvelope`, `measureLoudness`, `sizeCanvas`, `timeToX`,
  `xToTime`, `draw`, `marker`, `rebuildCols`.
- **Zoom/pan:** `viewSpan`, `clampView`, `zoomFit`, `zoomAt`, `zoomBy`, `zoomIntro`, `panBy`,
  `isZoomed`, `updateZoomLabel`, `followPlayhead`.
- **Markers/config:** `cfgFor` (returns/creates per-song settings), `markAt`, `setIgnoreEnd`,
  `setTrim`, `setNormalize`, `setPlayed`, `resetPlayed`, `pruneOrphans`, `afterCfgChange`,
  `saveConfig` (debounced POST to `/api/config`).
- **Transport:** `startLoop`/`stopLoop` (rAF draw loop), `checkIntroEnd`, `startIntroFade`,
  `cancelFade`, `reflectPlaying`, `updateChip`, `setIdle`, `toggleStart`, `testIntro`, `reveal`,
  `resetSong`.
- **Audio graph:** `ensureGraph`, `resumeCtx`, `applyGain`, `dbToGain`, `clamp`.
- **SE:** `playSE`.
- **Keyboard/nav:** global `keydown` handler, `moveSel`.

---

## 8b. Waveform zoom + the two loops

### Envelope, not PCM
`buildEnvelope()` reduces the decoded channel to an **amplitude envelope at `ENV_HZ` (1000)
buckets/sec** — ~1 MB for a 4½-minute song, versus ~45 MB for the raw Float32 PCM. The decoded
`AudioBuffer` is dropped right after, so nothing large stays resident. 1 ms resolution is far finer
than the deepest zoom (`MIN_SPAN` = 0.2 s), so zooming never needs the PCM again.

### Per-column cache
`rebuildCols(W)` collapses the envelope into one peak per canvas pixel column for the current view,
keyed on `W + view.s + view.e`. `draw()` calls it every frame but it early-returns unless the view
or the canvas width changed. This is what keeps the draw loop cheap: recompute cost scales with the
**visible span**, not the song length, so a deep zoom (where the view moves every frame) is the
cheapest case, and full-song view (expensive) is recomputed only on an explicit zoom/resize.

Column peaks are normalised against `globalPeak` (whole-song max), not a per-view max — otherwise a
quiet passage would balloon to full height as soon as you zoomed into it.

### The overview strip (`OverviewStrip`)
`select()` opens on `zoomIntro()`, which is right — but it meant nothing on screen said *where in
the song* that window sat, so a hook at 1:40 and one at 3:10 looked identical and the only way to
orient yourself was to zoom out and lose the detail you came for. A 34 pt whole-song strip under
the waveform shows the intro range, the hook, the playhead, and the visible window.

Two things in it are load-bearing:

- **It gets its own cache** (`Analysis.overviewPeaks`). `columnPeaks` keeps a *single* entry keyed
  on the view window, so having the strip ask for `0..duration` while the waveform asks for a
  zoomed window would make the two **evict each other and re-walk the whole envelope twice per
  frame** — the exact cost the column cache exists to avoid. The strip's window never changes, so
  width alone is a sufficient key. Measured: 2.4 ms recompute → 0.001 ms when interleaved.
- **It indexes the envelope exactly like `columnPeaks`** — floor/ceil on `bucketHz`, *not* a
  proportional split of `env.count`. The proportional version drops the bucket each column shares
  with the next, which measured up to **0.17 of normalised peak** at a transient: the strip and a
  zoomed-out waveform drew different shapes for the same audio. `--overview` asserts maxDiff 0.
- **It moves the view, never the playhead.** Two stacked surfaces where a click means different
  things is how an intended pan becomes an accidental seek — and `seekTo` re-derives the play mode,
  so that slip can disarm the intro-end stop (§10).

### Interaction
- **Wheel/two-finger** = zoom at the pointer; trackpad pinch arrives as `ctrlKey+deltaY` and lands
  on the same path. Shift-wheel or horizontal wheel = pan.
- **Drag on empty canvas** = pan. Because click-to-seek shares that surface, mousedown only records
  a *pending* seek (`panFrom`); past `PAN_SLOP` (4 px) it becomes a pan, and a release with no
  movement calls `seekTo()`. Dragging **on** a marker line still moves the marker (unchanged).
  Note the seek fires on mouse**up**, not mousedown — that is what makes the two gestures separable.
- `followPlayhead()` keeps the playhead on screen while playing, jumping a page at a time rather
  than scrolling continuously — cheaper, and much less dizzying to watch while marking.
- Markers are stored at **0.01 s** now (they were 0.1 s); zoom is what makes that precision usable.
  The `− / +` nudge buttons deliberately still step 0.1 s.

### Why `guardId` exists (important)
Drawing runs on `requestAnimationFrame`. **Chrome freezes rAF entirely for a backgrounded or
minimised window** — verified: 0 frames/sec. The intro-end auto-stop used to ride on that same rAF
tick, so a GM who switched apps mid-intro would have heard the intro run straight into the song,
violating the app's core requirement. `startLoop()` therefore also arms
`guardId = setInterval(checkIntroEnd, 40)`; pages playing audio are exempt from Chrome's intensive
timer throttling, so the guard keeps firing. **Don't move `checkIntroEnd` back to rAF-only.**

(The fade itself was never at risk: `startIntroFade` schedules a `linearRampToValueAtTime` on the
`AudioContext` clock, which no throttling touches. Only the `finish()` timeout is throttled, and it
just pauses and snaps `currentTime` back to `introEnd` — silent either way.)

### Persistence flow
Any settings change → mutate `config` in memory → `saveConfig()` (debounced 250 ms) → `POST
/api/config` → server writes `config.json`. On load, `init()` GETs both songs and config.

---

## 8c. Playlists (subfolders of `songs/`)

A subfolder of `songs/` is a **playlist = one taping session**; loose files form an unnamed round
labelled `ROOT_LABEL`. Songs are identified end-to-end by their **path relative to `songs/`**.

- `playlistOf` / `baseName` / `titleOf` / `songUrl` are the path helpers. `songUrl()` encodes each
  segment separately — `encodeURIComponent` on the whole path would turn `/` into `%2F`.
- `currentPlaylist` filters the list, the ↑/↓ navigation, the header counts, and **`resetPlayed`**
  (that button means "starting a new taping", and a taping is one folder — clearing other rounds
  from it would be a nasty surprise). `pruneOrphans` stays global.
- Remembered in `_settings.lastPlaylist`. **This is what makes a newly added folder look like
  "the app can't find my songs"** (reported from real use): the scan finds it, the picker lists it,
  but the app reopens on the remembered round so the new one is hidden behind the dropdown. The
  native app therefore rescans on window activation, on `Cmd+R`, and from a **⟳ อ่านโฟลเดอร์ใหม่**
  button, and names any newly-found rounds in a toast. The web version relies on `Cmd+R`.
- **The picker is hidden while every file is loose**, so a library that was never reorganised looks
  and behaves exactly as it did before this feature existed.

### Three columns inside a round
The list splits the selected playlist into 3 columns by the **leading digit of the filename**:
`1xx` / `2xx` / `3xx + everything else` (`colOf()`). It is display-only — nothing is stored per
column, and a file with no leading digit lands in column 3.

- `↑`/`↓` stay **inside** the active column; `[` / `]` hop between columns (skipping empty ones)
  and land on that column's first song. `←`/`→` were unavailable — they pan the waveform.
- `activeCol` follows whatever song is selected, including mouse clicks. `selectSong()` doesn't
  rebuild the list, so it calls `syncColHighlight()` to move the header highlight.
- Sized for the 2560×1080 ultrawide this runs on: list 780px still leaves ~1460px for the
  waveform. A `max-width:1500px` media query falls back to the original single column with the
  group headers stacked inline, so a narrower window still works.
- Titles are clamped to 2 lines with the full name in a `title` tooltip — uniform row heights
  matter more than complete titles when scanning during a take.

### Why paths, not filenames
Config keys had to move from bare filename to relative path. If two rounds contain the same
filename — which happens when a song is reused — filename keys would make them share one entry,
including **`played`**: you would open a fresh taping with songs already crossed off. Path keys keep
rounds independent, and loose files keep their bare-filename key, so old flat configs still match.

The cost is that a reused song starts blank. `findDonor()` looks for the same basename already
configured in another round and offers `copyCfgFrom()` — it copies markers/`ignoreEnd`/`trimDb` but
**never `played`**, and the button disappears once the song is configured.

> Moving a file between folders orphans its settings (same trade-off as renaming — see §9).

---

## 8d. Taping log (`log.json`)

Questions are not run in list order, so the running order itself is the thing worth recording. The
log is a flat chronological event list — that ordering plus the timestamps is what lets the edit
team find each take on the tape.

```json
{"events":[{"t":"2026-08-04T23:46:28+07:00","playlist":"EP01","path":"EP01/02_x.mp3","event":"correct"}]}
```

**Only `correct` and `wrong` are logged.** `reveal` means "question used" too, but the GM hammers
Reveal while hunting for the hook during setup, which would bury the real takes — so it is
deliberately excluded. The server rejects any other `event` value.

### The running order is the record (`Take`, `Takes`)

**Questions are never run in list order**, so "what did we open first, then what" is the only index
that works against the tape — and it is the question people actually bring to this file afterwards.
The log panel therefore opens on **ลำดับการถ่าย**, numbered from 1, with the raw event stream behind
a **ทุกเหตุการณ์** toggle for working out what happened when a row looks wrong.

A **take is a consecutive run of events on one song** (`Takes.build`). The summary this replaced
grouped by path across the whole session, which folded a song **revisited later** back into its
first appearance — destroying precisely the ordering the log exists to record. Going back to a song
is a new take, and the song list shows `#2,9` for one that was used twice.

- Events are taken in **file order, never sorted by timestamp**. File order is the running order
  even if a clock jumped, and a clock jump must not be able to reorder the tape index.
- `Takes.sittings` splits the order wherever there is a gap over `sittingGap` (4 h), and each
  sitting gets its own date heading and its own elapsed baseline. This is not hypothetical:
  `resetAt` is pressed by a human, so one "session" really can span months — the live `log.json`
  has takes **92 days apart**, and measuring elapsed from the session's first take printed
  `+2230:24:30`.
- Elapsed (`+M:SS`) is per sitting, for a camera whose timecode was reset when the camera was.
- A log row **click selects that song**, and refuses while playing — the log is a pane now and can
  be open during a take, where `select()` would load a new file and cut the audio on air.
- `AppModel.takes()` / `takeOrders(of:)` are cached behind `invalidateStatus()` for the same reason
  `status(of:)` is: the song list asks per row, and the pane re-renders at the player's tick rate.

Both exports lead with the running order; the grouped-by-outcome summary comes second and cites
take numbers, so the two halves point at each other. The CSV is **one row per take** (ลำดับที่,
วันที่, เวลา, จากเริ่มช่วงนี้, ช่วงถ่าย, ผล, ตอบผิดกี่ครั้ง) — `log.json` keeps the per-event
detail. Verify with `--takes`, which runs a synthetic self-check (retake, burned question, sitting
split) before printing the real library's order.

**Derived status** (`statusOf(path)`, scanning the events):
| result | meaning | badge |
|--------|---------|-------|
| `correct` | at least one Correct — answered | green ✓ ตอบถูก |
| `wrong` | Wrong(s) but never a Correct — **used on set, unusable in the edit** | amber ✗ ไม่มีคนตอบ |
| `null` | never used | — |

That middle row is the whole point of the feature: the question is burned (it aired on set and
can't be reused) yet contributes nothing to the cut.

**Why a separate file and an append endpoint.** `/api/config` POSTs the whole object, so two open
windows clobber each other (§12). The log takes one event and appends server-side, so it can't be
lost that way, and the timestamp comes from the server rather than a client clock.

Only `score()` (Correct/Wrong) sets `played=true`. **Reveal deliberately does not** — the GM
hammers it while hunting for the hook during setup, so it is the same bad signal that keeps it
out of the log. `P` remains the manual override.

**UI**: header button (or `L`), `Esc` closes. A left-pane swap, not a sheet. Scoped to the current
playlist with a "ดูทุกรอบ" toggle — which must go through `setLogAllRounds`, since the take
numbering is scoped to that filter and has to be invalidated with it. CSV carries a UTF-8 BOM so
Excel reads Thai. `↩ ยกเลิกรายการล่าสุด` exists because mis-presses happen live.

### Sessions: how `resetPlayed` interacts with the log
**`resetPlayed` does not delete log events** — the log is the tape's history and must survive
starting a new taping. But the ✓/✗ badges are *derived* from the log, so clearing only `played`
left them stuck forever and reset looked broken (reported from real use).

Fix: `resetPlayed` stamps `config._settings.resetAt[playlist]` with the current time, and
`statusOf()` ignores events at or before that stamp. Nothing is deleted; the badges just reflect
the current taping. `isCurrentSession(e)` is the shared predicate — the song badges, the log
summary tiles, the header button count and the text export all use it, so they can't disagree.

The log panel still lists **every** event: pre-reset rows are dimmed (`.lrow.past`) under a
`↺ เริ่มถ่ายรอบใหม่` divider, so older takes read as history rather than as a failed reset. The CSV
keeps every row too and adds a `รอบถ่าย` column (`ปัจจุบัน`/`ก่อนหน้า`).

> Clearing the log outright is still a separate, explicitly-confirmed button.

---

## 8e. Handover between setter and operator

The unit of handover is **one round folder**. `round.json` is written *into* it, so copying
`songs/EP05/` carries the questions with the audio and there is no second thing to remember.

```
songs/EP05/
├── round.json     ← the questions: introStart, introEnd, hook, trimDb, ignoreEnd (+ configured/auto)
├── 101_....mp3
└── 102_....mp3
```

**`round.json` is an export format, not the live file.** `config.json` stays the working file for
both the native and the web app — that is what keeps the web fallback usable mid-taping (§6c).
Dropping the live store into the round folder instead would have recreated §12's clobber problem
across two machines.

**Import is a MERGE**, touching only the five question fields. It never writes `played`,
`resetAt` or the log. This is why session state can stay inside `config.json`: the thing that
wiped a taping was whole-file handover, not the fact that `played` sits next to `introStart`.

### `base` — what was signed off

Every song carries `base: {introStart, introEnd, hook, trimDb, ignoreEnd}`, written **only** by
export and import — never by an ordinary marker edit. So:

- `onsiteEdits` is **derived** (`current != base`), never stored, so it cannot go stale — same
  reasoning as `isCurrentSession` deriving from `resetAt` rather than a flag.
- The setter's value is never lost, so every field has a `↺ คืนค่าเดิม` and the waveform can show
  a ghost stem at the old position.
- `base == nil` means this round never went through a handover, so a library that was never
  handed over shows no on-site badges at all.

Stamp `base` on every save and "แก้ที่กอง" means nothing. Don't.

### The return path

The operator exports `round.json` back (a few KB, no audio). The setter imports it and
`Handoff.plan` produces one `DiffRow` **per changed field**, compared **incoming-vs-local** — not
incoming-vs-base, so it is still correct when BOTH sides edited the same song since the handover;
the setter sees both values and picks. Accepting takes the sender's value, rejecting keeps the
local one, and either way `base` is re-stamped from the result so both sides agree again.

A bulk import drops the undo stack (`afterBulkChange`) — `Cmd+Z` must not restore half a round.

### Pre-flight

`Preflight.fast` is the no-decode checklist (missing file, never opened, still auto-guessed, intro
shorter than 3 s, hook past the end of the song, hook still at the default 60 s); the sheet opens
on it instantly. `Preflight.silentIntros` needs a decode per song and fills in behind it. Each row
jumps to its song and closes the sheet, so a warning is fixed in place rather than closed, hunted
and reopened.

> Run `--preflight` against the real library before trusting a change here. It was what confirmed
> the hook step is being skipped in practice: **8 of 9 songs still had `hook: 60` exactly.**

Handover never *blocks* — a round with warnings sometimes has to go out — but a blocking warning
routes the button through `confirmDestructive` first.

## 8f. Cover art (`Artwork.swift`)

Asked for as "search Spotify and draw the jacket cover". Implemented with the source changed,
and the reason is a measurement.

**The files already have the picture.** All nine songs in the real library carry an embedded
ID3 `APIC` frame, because they came from music videos. So the primary source is the audio
file's own metadata: offline, no key, instant, and incapable of showing the wrong song.
`--artwork` reports 9 embedded / 0 missing — for this library the network path never runs.

**Why not Spotify.** Its Web API needs a client ID and secret. That secret would have to sit on
every crew machine, or in `config.json` — the file §8e copies between machines. A credential
nobody manages, in a file designed to be passed around. The iTunes Search API answers the same
question with no key, so it is the fallback for files *without* embedded art. If Spotify is
specifically wanted later, only `Artwork.search` changes.

**The fallback is guarded, because it is weak here.** Measured against the real nine titles,
iTunes Search returned 2 clean matches, 5 nothing, and **2 confidently wrong songs** — searching
BOWKYLION's "วาดไว้" returns a different BOWKYLION track. A wrong sleeve on a quiz question is
worse than no sleeve, so a result whose track name shares nothing with the query is rejected.
Compared on the **track** name only: every wrong answer observed was the right artist.

> The shared-token floor is **3 grapheme clusters, not 4**. Thai combining marks fold into their
> base character, so `"ขี้แง"` is three `Character`s — a 4-cluster floor rejected the one Thai
> title the API actually got right. Three admits English filler, hence a stop list.

Offline guarantees (§1) are intact: nothing fetches by itself, the fetch is an explicit `⋯` menu
action that says it needs the internet, and with neither cache nor embedded art you get a blank
frame and **no error** — on a show day a missing picture must not produce a spinner, a dialog or
a retry.

Downloaded art caches to `songs/<round>/.covers/`, **inside the round folder**, so it travels
with the §8e handover instead of being re-fetched on a machine that is offline by design.
`Library.scan` passes `.skipsHiddenFiles`, so the dot-folder stays out of the song list.

The 52 pt frame is always rendered, empty or not — a frame that appears and disappears shifts
the title and everything under it (§12's recurring layout-shift defect). Resolution is off the
main actor and memoised **including a memo for "looked, not there"**: `cover(for:)` is called
from `body`, which re-renders at the player's tick rate.

---

## 9. `config.json` schema

Keyed by **path relative to `songs/`** (a bare filename for loose files). Example:

```json
{
  "_settings": {
    "normalize": true, "loudnessScope": "intro", "lastPlaylist": "EP01",
    "theme": "dark",          // "system" | "light" | "dark". An unreadable or unknown value
                              // falls back to DARK, not to the system: a garbled settings file
                              // must not be able to put a white screen in front of the
                              // operator mid-taping. §6d explains why dark is the default.
    "resetAt": { "EP01": "2026-08-06T01:40:00.000Z" },  // "new taping starts here" — see §8d
    "schema": 1,              // config format; absent means 1. NEVER written lower than the
                              // value already in the file — §15
    "writtenBy": "1.1.0",     // which build last saved this folder — §15
    "updateFeed": "",         // where to check for a newer build; empty = off — §15
    "lastRanVersion": "1.1.0",// rewritten on every save; a difference on launch means the
                              // update worked, and is the only way to SAY so — §15
    "dismissedUpdate": "",    // version the operator waved off; survives a relaunch — §15
    "dismissedSchema": 0,     // schema number they have already been told about — §15
    "backupDir": ""           // ALSO copy each launch snapshot here; empty = local only — §5c
  },
  "EP01/SongA.m4a": {
    "introStart": 14.2,   // seconds; intro begins here
    "introEnd": 15.5,     // seconds; auto-stop (with fade) lands here
    "hook": 60,           // seconds; Reveal jumps here
    "trimDb": 0,          // per-song manual gain trim, dB (−12..+12)
    "ignoreEnd": false,   // if true, don't auto-stop at introEnd
    "played": false,      // "used this taping" flag (ephemeral-ish)
    "configured": true,   // GM actually placed markers — drives the green "set" badge
    "auto": false,        // introStart was guessed, not set by the GM (§7a1)
    "base": {             // what the setter signed off at handover — §8e. Written ONLY by
      "introStart": 14.2, // export/import, never by an ordinary edit. Absent = this round
      "introEnd": 15.5,   // never went through a handover, so no on-site badges show.
      "hook": 60, "trimDb": 0, "ignoreEnd": false
    }
  }
}
```

- `cfgFor(name)` lazily fills defaults from `DEFAULT_CFG`
  `{introStart:0, introEnd:15, hook:60, ignoreEnd:false}`, and returns a **throwaway** copy when
  `name` is falsy so browsing with no song selected can't write a `"null"` key.
  `trimDb`/`played`/`configured` are optional (treated as 0/false when absent).
- **Merely selecting a song creates its entry** (with defaults). That's why the file grows just from
  browsing; the prune button is the cleanup.
- `configured` is written by `afterCfgChange()` — i.e. only by marker edits, not by trim/played.
  `isConfigured()` falls back to comparing against `DEFAULT_CFG` for entries written before the flag
  existed, so old configs keep their badge.
- `_settings` is app-wide; excluded from the song list and from orphan pruning.
- **Keys are paths**, so renaming *or moving* an audio file orphans its settings. The
  **🗑 ล้างเพลงเก่า** button (`pruneOrphans`) deletes entries whose files no longer exist under
  `songs/`. See §8c for why paths rather than filenames.

---

## 10. Playback state machine (and a fixed bug)

`mode` decides whether the intro-end auto-stop applies:
- `idle` — stopped/ready.
- `intro` — playing the intro; `checkIntroEnd` fades+stops at `introEnd` (unless `ignoreEnd`).
- `reveal` — playing from the hook; **no** auto-stop. This is the on-camera verb.
**`remode` may only ARM the guard, never disarm it.** It re-derives the mode after a marker edit,
but assigns it **only when the result is `.intro`**. Assigning unconditionally was a
core-requirement violation: pulling Intro End back *behind* the playhead — one typed value, one
drag — gave `.free`, which skipped the intro bound, left `want` at the file length, and passed the
"moved outward" test against the OLD boundary, so the node was rescheduled to the end of the file.
**Shortening the intro made playback longer, and the whole song went out on camera.** Holding
`.intro` lets `tick()` handle it: the playhead is already past the new Intro End, so `beginFade`'s
"already late" branch cuts at once. A *seek* still re-derives freely — that is a transport command
the operator can hear; a marker edit is not one. `--remodetest` covers all three directions, and
reverting the single line makes it report `NEVER STOPPED  mode=free  playing=yes`.

- `free` — playing from a point already past `introEnd`; **no** auto-stop.

> **Removed: `preview` (`G`, ฟัง Hook).** There used to be a fifth mode — a bounded six-second
> audition of the hook — taken out by product decision. Two things are worth keeping from it.
>
> First, the bug it ended on, because the *shape* recurs: `finishFadeNow` parks the playhead at
> the fade's end point, which is right for an intro stop (`introEnd` is where playback
> legitimately ended) but left an audition parked at `hook + 6`. `H` with playback stopped marks
> the hook **at the playhead, immediately**, and `G` is keyCode 5 while `H` is 4 — adjacent keys
> pressed by the same person in the same task. So `G` then `H` walked the hook 6 s further into
> the song, silently, every time. **A read-only verb that moves state the next keystroke reads
> is not read-only.**
>
> Second, `--previewtest` had a second half that proved the intro guard still armed afterwards,
> and that half covered the §10 Reveal regression below, which had no other test. It lives on as
> **`--revealtest`**: Reveal must play on, and the next Space from inside the range must stop at
> Intro End. Don't delete it as leftovers.

`modeForPosition(t,c)` is the single rule — `(t < introEnd-0.02 || ignoreEnd) ? 'intro' : 'free'` —
and **both** entry points below call it, so they cannot drift apart.

**Space/Start (`toggleStart`) — Start never rewinds:**
- If playing (any mode) → pause instantly (cancels any fade).
- If stopped → **play from wherever the playhead is**, mode via `modeForPosition`.

**Click-to-seek (`seekTo`) — seeking re-arms or disarms the guard:**
- Seeking is deliberate, so while playing it re-derives the mode for where you landed. That is what
  lets the GM **click past Intro End mid-playback and keep playing without ticking Ignore Intro
  End** — previously `mode` stayed `'intro'` and the guard faded out the moment you landed.
- Seeking *back* inside the range re-arms the auto-stop.
- It calls `cancelFade()` first: a click during the intro-end fade means "keep going", not "stop".
  Skipping that would leave the gain ramped to ~0 and the audio silent after the jump.
- While **paused** it only moves the playhead — it never starts playback, and leaves `mode` alone
  for `toggleStart` to derive on the next Space.

So the guard arms itself whenever playback is before Intro End, and past that point there is no
intro left to protect. The amber `free` chip makes it visible that the auto-stop is *not* armed.

Every other `currentTime` write is a deliberate rewind: `loadedmetadata` and `resetSong` park on
`introStart`, `testIntro` jumps there, `reveal` jumps to `hook`, and the fade's `finish()` snaps
back to `introEnd`.

The playhead lands on `introStart` by itself in the cases that matter — selecting a song, and
**Reset (`S`)**, which is the one key that rewinds. `Test Intro` also jumps to `introStart`
explicitly. Pause-on-buzz → Space resumes exactly where it stopped, still in `intro` mode.

> **Superseded behaviour:** Start used to force `currentTime = introStart` whenever `mode !== 'intro'`.
> That made it impossible to audition from a clicked position, which is why it changed. The bug the
> old rule was guarding against (below) is still handled — by deriving the mode from the playhead
> rather than by rewinding.

> **Bug that was fixed:** previously, after using Reveal (common while setting the hook), `mode`
> stayed `'reveal'`, so pressing Space resumed in reveal mode and played *past* `introEnd` — looking
> like "Ignore Intro End" was on when it wasn't. Fix: Start from a stopped state always begins a
> fresh intro unless we were paused mid-intro. Also added a defensive `fading=false` reset in
> `setIdle`, a `cancelFade()` at the start of `toggleStart`'s play path, and a visible status chip
> (`updateChip`: blue "เล่น Intro" / purple "เล่นเฉลย/Hook" / "หยุด") so the mode is always visible.

---

## 11. Keyboard shortcuts

| Key | Action |
|-----|--------|
| `Space` | Start / Pause (universal) |
| `S` | Reset (stop + jump to introStart) |
| `R` | Reveal (jump to hook, play on) — deliberately does **not** mark Played, and never stops |
| `1` / `2` | SE correct / wrong — **also writes the taping log** (§8d) |
| `L` | Open/close the taping log — a **left-pane swap**, not a sheet (`Esc` closes) |
| `P` | Toggle Played on current song |
| `I` / `O` / `H` | Mark introStart / introEnd / hook at playhead — **confirm-on-second-press while playing** |
| `Shift` + `←` / `→` | Nudge the **focused** marker by 0.01 s (`AppModel.nudgeStep`) |
| `M` | Cycle which marker `Shift+←/→` nudges |
| `E` | Toggle Ignore Intro End — same two-press rule |
| `Return` | ยืนยันค่านี้ — clears `auto`, advances to the next song needing review |
| `Tab` | Jump to the next song needing review |
| `Cmd+Z` | Undo the last marker edit (≤40 deep) |
| `Cmd+E` | Open the handover pre-flight |
| `↑` / `↓` | Previous / next song **within the active column** |
| `[` / `]` | Move to the previous / next column |
| `+` / `−` | Zoom waveform in / out (around the playhead) |
| `0` | Zoom to fit the whole song |
| `Z` | Zoom to the intro range |
| `←` / `→` | Pan the view by 25% of the visible span (plain; `Shift` nudges instead) |

Handler ignores keystrokes when focus is in an `<input>`, and bails on Cmd/Ctrl/Alt so `Cmd+R`
reloads instead of firing Reveal.

### Fine adjustment: `focusMarker`, `Shift+←/→` and the typed fields

Three ways to set a marker, each for a precision the others cannot reach:

| | precision | when |
|---|---|---|
| drag on the waveform | whatever a pixel is worth at the current zoom | placing it roughly |
| `−` / `+` buttons | 0.1 s (deliberately unchanged) | stepping by ear |
| `Shift` + `←`/`→` | **0.01 s** — what markers are actually stored at | the last 2–3 frames |
| typed `mm:ss.hh` field | exact | copying a time off a reference, or a value read out loud |

> **A marker must be ACTIVE before a drag can move it.** A press on an inactive marker only
> activates it and consumes the gesture — no move, no pan, no seek; a second gesture drags.
> The waveform is also the surface for panning and click-to-seek, so the old one-stage grab
> meant any press landing within 8 pt of a line moved a signed-off value: the waveform
> equivalent of the unguarded `I`/`O`/`H` above. "Active" reuses `focusMarker` rather than
> inventing a second notion of selection, so the thing `Shift+←/→` nudges and the thing a drag
> moves are always the same marker, carried by the same width-and-outline cue (§6d: never a new
> hue).
>
> The decision is a pure function, `MarkerGrab.decide`, so `--grabtest` can prove it without
> driving a gesture. Two details in it are load-bearing and invisible in a screenshot: the
> distance tie-break is `<=` not `<` (with `<`, two markers on the same time make the later one
> unreachable — song 102's real state), and a press that moves nothing must WRITE nothing. The
> old code called `updateConfig` on every `onChanged` including a zero-movement click, which
> stamps `configured` and pushes an undo snapshot — dropping the song out of the `Return`/`Tab`
> sweep and out of the pre-flight warnings. Exactly the defect recorded for the typed field.

`AppModel.focusMarker` is what `Shift+←/→` moves. It **follows the hand** — a waveform drag, an
`I`/`O`/`H`, a `±` press, a click on the card or focusing its text field all set it — so the key
always means "the one I am working on" and there is no mode to remember. `M` cycles it. It is
carried in the UI by *width and an outline*, never a new hue (§6d: one meaning per hue).

The nudge is deliberately **not** behind the two-press rule below, but be precise about why it is
safe: it is not the step size. Key autorepeat is suppressed for the whole app (`isARepeat` is
checked before the shortcut switch), and `remode` bails while a fade is running, so you cannot
slew Intro End across the playhead faster than the playhead advances. The *typed field* has no such
limit, which is why the `remode` rule in §10 is what actually protects this.

It uses `updateConfig(commit: false)` plus a 350 ms debounce, exactly like the waveform drag:
committing calls `player.remode`, which re-schedules the node once the accumulated move passes
0.05 s — an audible dropout every sixth keypress, during the one task the key exists for. It also
`cancelPending()`s, because a pending `I`/`O`/`H` holds the position of its **first** press and
confirming it after a nudge would write that older value and discard the nudge.

**The typed field commits on Return. Losing focus CANCELS.** Both halves are load-bearing:

- Not per keystroke — that would push an undo snapshot per character, and since `updateConfig`
  clamps `introEnd >= introStart + minIntro`, the lone `1` on the way to `1:20` would drag the
  other marker with it.
- Not on blur either, which looked friendlier and was **three** ways to destroy a signed-off
  marker: `Esc` belongs to the focused text view, so it ends editing and the blur then *commits*
  the typo it was meant to discard; a half-typed `1` plus a stray click wrote a 1-second intro;
  and clicking a field merely to **read** the exact time wrote it straight back — which stamps
  `configured`, dropping the song out of the `Return`/`Tab` sweep **and** out of the pre-flight
  warnings, so an unreviewed guess could pass the handover check. Snapping back is visible; a
  silent write is not.
- `dirty` is **derived** (`text != synced`), never a stored flag, and `commit()` additionally
  refuses when the song changed under it (`model.current != path`) or when the value is unchanged
  (`SongConfig.same`). Selecting a song in the list does **not** move first responder, so without
  that path check a field focused on song A committed A's number onto song B.

`parseClock` **rejects** rather than clamps (`1:75`, `-5`, `12s` → nil) — verify with `--timefmt`.
`setMarkerTime` refuses outright when `player.duration == 0` (an unreadable file): `Store.round2`
multiplies by 100, so a large enough *finite* value becomes `+infinity`, after which **every**
later save fails `isValidJSONObject` with nothing on screen naming the song at fault.

> A focused text field makes `NSApp.keyWindow?.firstResponder` an `NSTextView`, which the key
> monitor treats as "typing" and passes everything through. **Space is carved out of that** (as
> pause only, outside sheets): the time fields are numeric so Space is never valid input there, and
> a focus left in a field must never be the reason a buzz cannot be stopped.

### The two-press rule (`I` / `O` / `H` / `E`)

These keys were instant, silent and irreversible, and they sit on the same keyboard as the
four keys the operator hammers during a take. **`E` is the worst**: keyCode 14 is next to `R` (15),
and it disarms the intro-end stop outright — which plays the whole song on camera.

- **Stopped → immediate.** That is the setter's normal way of working and the playhead is parked
  where they chose, so the guard would only be friction.
- **Playing → the first press only proposes.** A second press of the SAME key within 2.5 s
  commits. `Esc`, a seek, Reveal, Reset or any song change cancels it; the window expires silently.
- **The committed value is the position captured at the FIRST press.** Using the second press's
  position would let 2.5 s of playback drift into the marker and silently set the wrong value —
  this is the detail that would make the whole feature quietly wrong.

`R` is not guarded and should not be: §10 calls Reveal the on-camera verb, something the GM
means to press.

### The hook audition (`G`) was removed — and why the argument for it was still right

`G` jumped to the hook, played six seconds and stopped. It is gone by product decision. The
reasoning is kept because it is the kind that gets re-litigated, and because the conclusion was
**not** "it was redundant".

Asked whether `R` and `G` were duplicates, the honest answer was no. The functional difference
was only *bounded vs unbounded*, so the obvious simplification is one key whose behaviour
depends on state — and that **does not work**: the discriminator would have to be `isPlaying`,
and the commonest on-camera reveal happens from a **paused** state (paused on a buzz, the
contestant answers, reveal). A key that was bounded when stopped would cut the reveal off after
six seconds in exactly the situation it exists for. The mirror version fails the same way.

What made them genuinely different rather than one-with-a-leash was that `G` ended up
**non-destructive and idempotent** — audition, and you are back where you started — which `R`
cannot be without ceasing to be a reveal.

Two notes that outlive the key itself:

- **Its guard was inverted on purpose, by adjacency rather than consequence.** The *safer* key
  (six bounded seconds) was confirm-on-second-press while the *more dangerous* one (`R`, the
  whole song on camera) was not. `H` sits next to `G` and is pressed during playback by design;
  nothing next to `R` is, and `E` — the other neighbour — is itself guarded. If a key is ever
  added near `R`, that reasoning says to guard the new key, not `R`.
- **Hunting for a hook is now `R` + Space again**, which is what §8e measured as the reason 8
  of 9 songs still sat on `hook: 60`. That gap is what §7a4's automatic hook guess now covers:
  the setter reviews a proposal instead of hunting from scratch.

The two-press rule is keyed on `isPlaying` rather than on a mode toggle for the same reason §1
rejects a show mode: a mode has to be remembered, and the day somebody forgets to switch it is
the day it does not help.

> **Switch on `e.code`, never `e.key`.** This machine's input source is often **Thai**, where the S
> key reports `e.key === 'ห'` — every letter shortcut in the app silently stopped working. `e.code`
> is `'KeyS'` under any layout. Digits likewise need `Digit1`/`Numpad1`. Don't "simplify" this back.

---

## 12. Known limitations / edge cases

- **Single machine, single operator.** No auth, no concurrency, localhost only.
- **Two open windows clobber each other's config.** Every save POSTs the *whole* `config` object, so
  a second window/tab loaded earlier will overwrite anything the first one saved. (Hit for real
  while testing the `.app` alongside a browser tab.) Two guards now exist, but the underlying
  whole-object write is still there — a per-song PATCH endpoint would be the real fix:
  1. The `.app` refuses to launch a second time (`pgrep` on the browser profile → alert → exit).
  2. Every window pings `POST /api/hello` every 4 s; the server keeps a `CLIENTS` dict with a
     12 s TTL and returns the live count, and any window seeing `clients > 1` shows a red banner.
     This is what catches a stray browser tab, which the launcher check cannot see.
- **Web Audio needs a gesture:** normalization/fade only engage after the first click/play. Before
  that, gain isn't applied.
- **Long files:** `decodeAudioData` loads the whole file into memory for analysis. Fine for songs;
  very long files could be heavy. Only the ~1 MB envelope is retained afterwards (§8b).
- **Filename-keyed config:** renaming a file loses its markers (by design; prune button cleans up).
- **`played` persists** in `config.json` across reloads (intentional, survives a mid-show reload);
  reset with the **↺ รีเซ็ตเล่นแล้ว** button when starting a new taping.
- **No automated tests.** Current verification is `node --check` on the extracted script + manual
  server smoke tests (curl the endpoints).

### Fixed (was broken, don't re-introduce)

**Native app** (see §6c for the AppKit/SwiftUI traps behind several of these):
- `I`/`O`/`H`/`E` wrote a marker **instantly, silently and irreversibly** from the live playhead,
  on the same keyboard the operator hammers during a take. `E` was the dangerous one — keyCode 14
  sits next to `R` (15) and it disarms the intro-end stop, i.e. plays the whole song on camera.
  See the two-press rule in §11, and note the committed value must come from the FIRST press.
- **There was no undo anywhere** (only `LogStore.undoLast`), and `store.set` writes straight
  through. One accidental waveform drag silently overwrote a configured marker for good.
  `pushUndo` coalesces same-song snapshots inside 700 ms, so one drag is one undo step, not sixty.
- The status chip rendered **only while playing** (`CenterView.chip` keyed on `playing`), and
  `Player.pause()` leaves `mode` untouched. So pausing past Intro End — or ticking `E` — left the
  disarmed state **invisible in exactly the moment the operator decides to press Space**. It is
  now a fixed-height strip derived from `modeForPosition` + `ignoreEnd`, truthful while paused,
  with a countdown: "armed" has to be proven by a moving number, not asserted by a label.
- `isARepeat` blocks a HELD key but not two taps: two `1`s 120 ms apart **overlapped two correct
  stings on camera and wrote two log events**. `score` now has a 400 ms lockout.
- The key monitor returned `e` for everything once `showLog` was true — including keyCode 49, so
  **Space could not pause when a contestant buzzed with the log open.** Space now passes through
  as pause-only; `1`/`2`/`I`/`O`/`H` stay blocked.
- `configured = true` was a side effect of ANY marker write, so there was no way to say "that
  guess is right" without first changing it — the setter could not sweep a round. `Return`
  confirms, `Tab` jumps to the next song needing review.
- `select()` called `zoomFit()`, which at ~6 px/s puts a 15 s intro in ~90 px of 1460 — every song
  started with a manual `Z`. It opens on `zoomIntro()` now. A second `zoomFit()` in the analysis
  callback also **wiped any zoom made during the decode**; removed.
- "Never opened" and "the app guessed it" both rendered the **same empty badge** — completely
  different things to a setter. Three states now: `○ ยังไม่เปิด` / `🎯 เดาไว้` / `✓ ตั้งค่าแล้ว`.
- `✓` meant both "played" (amber) and "correct" (green) — two near-identical glyphs, different
  meanings. `played` is the dimming and strikethrough only; it gets no badge.
- Marker flags were all at the top edge with a `<=` z-order tie-break, so two markers on the same
  time could not both be grabbed. Intro Start caps at the top, Intro End at the **bottom**, which
  makes song 102's `introStart == introEnd` reachable by construction.
- The full-height progress rect was drawn **on top of** the intro-range tint, so the zone changed
  colour as the playhead crossed it and both read as "some kind of range". Progress is 1-D now: a
  6 pt bar on the bottom edge.
- The waveform was pinned at `height: 140` with ~580 pt of empty `Spacer()` below it, so a quiet
  lead-in rendered 3–4 px tall and the marker drag target was a sliver. It fills the pane.
- Transport buttons used `.fixedSize()`, so "▶ Start" → "❚❚ Pause" changed width and Reveal /
  Reset / Played **slid sideways every time playback started** — a click aimed at Reset could land
  on Reveal. Fixed widths, fixed order. Correct/Wrong went from 12 pt apart to 56 pt.
- A failed save was 12 pt amber text in the header — the same colour as `played`, at the smallest
  size in the app, for the one condition that silently loses a day of markers. Full-width red bar.
- `isWide`'s 1500 px breakpoint left the centre pane 378 px at exactly 1500 (a 330 px waveform and
  a wrapped transport row). Raised to 1900.
- `Player.pause()` called `node.pause()` **before** reading the playhead. `playerTime(forNodeTime:)`
  returns nil the moment the node stops, so `livePosition()` fell through to the stale `pausedAt`
  and assigned it to itself — **the playhead jumped back to the previous pause on every buzz**
  (measured 5.00 s where it should have been 6.98 s). Read the position first.
- The intro-end stop relied on the guard timer alone. `play(from:)` now **bounds the scheduled
  segment at Intro End**, so the node has nothing left to render past it and the core requirement
  is structural rather than timer-dependent. `Player.remode()` re-schedules when the marker moves
  *outward* (or Ignore Intro End is ticked) mid-playback — the drag commits on mouse-up, not per
  frame, or the reschedule clicks.
- The fade ramped **dB**, which sounds like an instant 42% drop on the first step and is
  perceptually silent a quarter of the way in. It is linear in amplitude (`node.volume`), like the
  web original.
- The intro-end guard **failed open**: a missing config or a degenerate `introEnd <= introStart`
  let playback run on. It now stops instead. Independently, `Store.decode` repairs such a range at
  load (and demotes the entry to `auto`, so the green "set" badge shows the song still needs the
  GM) — the live `config.json` had song 102 at `introStart == introEnd == 33.73`, which made
  `modeForPosition` return `.free` and would have played the whole song on camera.
- `load()` didn't reset the gain, so a +12 dB track followed by a loud one went out 12 dB hot if
  Start was pressed before analysis finished.
- `Analysis` indexed the envelope at a flat `envHz` (1000) while the actual bucket rate is
  `sampleRate/step` = 1002.27 Hz at 44.1 kHz — a 0.227% drift, **half a second by minute four**,
  which put the drawn waveform out of step with the playhead used to place markers. Use `bucketHz`.
- `Analysis.columnPeaks` had no cache, so the whole envelope was re-walked on every Canvas render.
  The web version's `rebuildCols` early-return (§8b, "what keeps the draw loop cheap") had simply
  not been ported.
- `select()` spawned an uncancelled `Task.detached` full-file decode per song and cached nothing —
  holding ↓ through a round started one per song, all concurrent. Now cancelled and cached by path.
- `LogStore.append/undoLast/clear` rewrote a stale snapshot, which would delete every event the web
  fallback had appended server-side since launch. They `load()` first.
- `saveNow()` reported `"saved ✓"` unconditionally — a read-only volume or a TCC-blocked folder
  looked fine all day and lost every marker at quit. It now catches, sets `saveFailed`, and the
  header shows it. Also: `JSONSerialization` raises an **Obj-C** exception on NaN that `try?`
  cannot catch, so `Store.decode` rejects non-finite values before they reach the file.
- The save is debounced 250 ms, so quitting right after a marker edit dropped it. `AppModel`
  flushes on `willTerminate` / `willResignActive`.
- `resetAt` was decoded with a whole-dictionary cast, so one bad value failed the lot and
  `writeSettings` then **erased every reset stamp in the file**. Decoded per key now.
- `isCurrentSession` returned `true` for an undatable event (fail-open), which is what a stuck
  badge looks like. The web app writes `toISOString()` (always milliseconds) and the Python server
  writes `timespec="seconds"`; **one `ISO8601DateFormatter` cannot parse both**, so a reset done in
  the web app parsed as nil. There are two formatters, and the predicate fails closed.
- `↺ รีเซ็ตเล่นแล้ว` / `🗑 ล้างเพลงเก่า` / `🗑 ล้าง log` had no confirmation; `pruneOrphans` would
  delete the entire config if `songs/` became unreadable (scan returns `[]` → everything an
  orphan). Both are guarded, and `rescan` keeps the old list rather than silently emptying it.
- Reveal jumped to `hook` unclamped — the default is 60 s, so every song shorter than that
  scheduled zero frames and **Reveal went silent on camera**.
- Two markers on the same time: the tie-break was strict `<`, so the later one could never be
  grabbed and Intro End was unreachable on the waveform (exactly song 102's state).
- Switching playlist left `current` in the old round, so Correct/Wrong logged the song under the
  *other* round's playlist.
- `flash()` compared message text, so two identical messages made the first timer clear the second
  toast early. It counts instead.
- The taping log was a **sheet**, which hid the song it was describing. That is why `1`/`2`/`I`/`O`/`H`
  had to be blocked while it was open and why Space had to be special-cased back in as pause-only.
  It is a **left-pane swap** now — the song, the transport and the guard strip stay visible and
  live — so every key keeps its normal meaning and the carve-out is gone. Don't turn it back into
  a sheet to "save space": the carve-outs come back with it.
- The three list buttons were identical 11 pt pills in a row, and one of them (`↺ รีเซ็ตเล่นแล้ว`)
  clears a taping's badges. Only `⟳ อ่านโฟลเดอร์ใหม่` is still a button; the two that throw work
  away moved behind `⋯`, out of slamming range of the one pressed most.
- `Reveal` was the only way to hear the hook, and it never stops — so hunting for one meant Reveal,
  listen, Space, nudge, Reveal, with the song further away each time, and 8 of 9 real songs still
  had `hook: 60` untouched. `G` / `♪` is the bounded version (§10 `preview`).
- The guard strip read **`⚠ ไม่หยุดเอง`** during a hook audition, which is *bounded* — a warning
  that fires when nothing is wrong is a warning that gets ignored on the day it matters. `disarmed`
  excludes `previewArmed`, and the countdown reads whichever bound is in force (`secondsToStop`).
- A marker could only be set by dragging or in 0.1 s steps, so the 0.01 s the value is **stored**
  at was unreachable, and a time read out loud had no way in at all. See the fine-adjustment
  section in §11 for the three paths and why the typed field commits on blur, not per keystroke.
- `Analysis.overviewPeaks` had to be a second cache, and had to index the envelope the same way
  `columnPeaks` does. Both reasons are measured in §8b — getting either wrong is invisible in a
  screenshot and obvious in a dropped frame or a mis-placed marker.
- **`remode` disarmed the intro-end guard when a marker edit crossed the playhead** — the worst
  defect this app has had, and it predated the typed field that made it one keystroke away. See
  §10 and `--remodetest`.
- `seek` assigned `mode` **after** calling `play(from:)`, which reads `mode` to pick the segment
  bound. A seek during a hook audition was therefore still bounded by `previewEnd`: past it,
  `frames == 0` took the `pause()` path *after* `node.stop()`, re-creating the §12 defect where
  the playhead jumped back to the previous pause. Every caller must set `mode` first.
- **`1` and `2` were dead while a marker time field held focus.** This commit created that state —
  before it, every `TextField` lived inside a sheet. A buzz that cannot be *scored* loses the log
  event the edit room works from (§8d), which is the same class of failure as a buzz that cannot
  be paused. Space, `1` and `2` are all carved out of the "typing" branch while playback runs.
- `G` put six seconds of the chorus on air from a single unconfirmed press, on the key next to
  `H`. Two reviewers found this independently. See the two-press section in §11.
- The nudge used `updateConfig(commit: true)`, so `remode` re-scheduled the node every sixth
  keypress — an audible dropout during the one task the key exists for.
- `confirmDestructive` made the **destructive** button the default, and two of its callers now sit
  behind a `⋯` menu where Space activates the highlighted item. One Space could open the alert and
  confirm it. Return/Space are bound to Cancel.
- The log summary grouped by path across the whole session, so a song **revisited later** folded
  into its first appearance and the retake vanished from the running order. It also led with the
  outcome grouping, which answers a question nobody asks of this file — the edit room is holding a
  tape and needs to know what was shot when. See the running-order section in §8d.
- Elapsed time was measured from the session's first take, which printed **`+2230:24:30`** on the
  real `log.json`: `resetAt` is pressed by a human, so "one session" spans months. Found by running
  `--takes` against the live library instead of a fixture.
- The log pane **unmounts** the song list, so closing it discarded the scroll offset and left a
  60-song round showing track 1 with the selection off-screen — the exact problem the
  `ScrollViewReader` was added for. Both layouts scroll to `current` on appear.
- `OverviewStrip` takes fixed height (`frame(height: 34)`, ~40 pt with its padding) from a
  `VStack` whose only flexible child is the waveform, which had no floor — it could reach 0,
  where the Canvas draws nothing and the marker drag targets vanish. `minHeight: 160`. Note the
  floor converts the failure mode rather than removing it: past the floor, content that overruns
  the window centres and clips BOTH ends, so the song title and the Correct/Wrong row are what
  go. `App.swift`'s `minHeight: 640` is ~13–67 pt short of what `CenterView` actually needs even
  with no banners up — see §15's news-strip note.
- `copyConfig(from:)` overwrote five signed-off fields in one click with **no undo entry**.
- The focus-hint line was conditional, so focusing a card moved the two below it ~14 pt under the
  cursor. Reserved height. (Same family as the transport buttons that used to slide.)
- A waveform press that moved the marker **zero** distance still called `updateConfig`, which
  stamps `configured` and pushes an undo snapshot. Clicking a marker merely to select it
  therefore marked an unreviewed guess as reviewed, dropping the song out of the `Return`/`Tab`
  sweep **and** out of the pre-flight warnings. Identical in shape to the typed field writing
  on blur (§11). A press that moves nothing must write nothing.
- `Markers.all` coloured **Intro End green** while the waveform drew it cyan — a live §6d
  violation (green has exactly one meaning, and §6d names this marker among the four it was
  supposed to have given up). Two bright cool hues hid it for months; a light theme, where they
  became dark green and dark teal, made it obvious in one screenshot.
- The header bar's save-failure text was `Palette.amber` on `Palette.header`. Fine in dark,
  **1.2:1 in light** — unreadable, on the one indicator that means a day of markers is being
  lost. That bar is dark red in both themes, so anything on it must be fixed-light
  (`onHeader` / `onHeaderWarn`), never a theme-flipping colour.
- The playhead is a dark hairline under a white core, and the hairline was `Palette.ink` —
  which inverts with the theme, so in light the playhead was **white-on-white**. `ink` means
  "text on a saturated fill"; `Palette.outline` is the dark hairline. They were the same value
  only because there was one theme.
- `PressStyle`'s white press wash and the pulse ring went invisible on light surfaces, and the
  `brightness` shift pointed the wrong way. §12 already records that a keypress must LOOK like
  a click or a dead shortcut cannot be told from a working one — that applies per theme.
- The cross-check between the fast gated-LUFS path and the file-reading reference reported a
  0.72 LU disagreement that was **100 ms block phase**, not a defect. Snapping both to the same
  grid is what makes the check mean anything; a cross-check that compares two slightly
  different things trains you to tolerate a delta.
- Chroma similarity for hook detection used a raw cosine, which scores 1.41–1.44 for **every**
  candidate in every song — so "the most repeated section" was silently just "the loudest eight
  seconds". Mean-centre before normalising (§7a4).
- **`kLimiterParam_PreGain` was read as a threshold.** It is a flat attenuation; limiting starts
  at nominal **+1 dBFS**, not −1. Every "the limiter will eat N dB" figure was 2 dB too big, and
  that was enough to raise the new pre-flight warning on a song the limiter never touches.
  Measure an audio unit's behaviour by rendering it, not by reading its parameter names.
- The headroom peak followed the **measurement scope** instead of what is played, so
  `loudnessScope: song` reported every song as squashed; and it read channel 0 while the gain is
  applied to all of them, missing a hard-panned transient by 1.4 dB.
- BS.1770's **LFE is excluded, not weighted 1.41**. The old index-based rule gave 5.1's loudest
  channel a +1.5 dB weight, so the file measured loud and the auto-gain under-boosted it.
- `eq.globalGain`'s clamp **failed open on NaN**: `min(24, nan)` returns 24, i.e. the maximum
  possible boost to live playback. Everything else in that file fails closed.
- The limiter's release time was set to 0.120 s against a reported maximum of 0.040, and the
  `AUParameter` bridge does not clamp — the value read back out of spec, with OS-dependent
  behaviour. Clamp writes to the unit's own `minValue`/`maxValue`.
- `kBlockSec` used the nominal 0.1 s rather than `kSubFrames / sampleRate` — the `bucketHz`
  drift, in a new place, biting only at 11025 Hz.
- An `@Environment` property on a **`ButtonStyle`** is not reliably injected: SwiftUI installs
  dynamic properties on Views and ViewModifiers, and a style is neither. It silently reads the
  default (`.light`), which would have given every dark-theme button an invisible press. Read
  the environment inside a nested `View` instead.
- "A press that moves nothing writes nothing" was asserted and not true: the drag wrote the
  **cursor's** time, so a click anywhere in the 8 pt slop moved the marker — up to a second at
  full-song zoom. Dragging relative to the grab point makes the claim true by construction.
- The two-stage marker rule made **Intro Start undraggable when stacked** with Intro End: the
  `<=` tie-break always returned the later marker, which merely moved focus away, and `M` could
  not help. The active marker wins a tie now. `--grabtest` had the same blind spot.
- `rollback` skipped any item that had no backup counterpart — i.e. the one thing a FIRST
  upgrade had actually installed. The old bundle came back, the new one stayed, and the dialog
  said the original set was restored. And the loop that moves files aside called `die`, which
  cannot undo what it had already moved.
- `pgrep -f` was handed an operator-chosen path as an **extended regex**. A folder named
  `IntroPlayer (ใหม่)` makes the pattern uncompilable, pgrep exits non-zero with no output, and
  the running-app check fails **open**. Match `ps` output with `grep -F`.
- A `backups/<stamp>/` directory passed `valid_target`, and it is reachable: the Dock follows
  the old bundle when the installer moves it there, so the operator's own icon opens the old app
  rooted in the backup — which has a `config.json` and no `songs/`. Every later marker edit then
  lands in a folder `KEEP_BACKUPS` pruning deletes.
- `"${EMPTY[@]}"` under `set -u` is a fatal error in bash 3.2 (what macOS ships). Inside process
  substitution the subshell dies quietly and the running-app check returns empty — failing open.
- The cover cache keyed on the filename **without its extension**, so `x.mp3` and `x.m4a` shared
  one file and the second song showed the first one's sleeve.
- A failed cover **write** was reported as "song not found", hiding the cheapest early signal
  that the folder holding `config.json` cannot be written. Same shape as `saveNow()` reporting
  "saved ✓" unconditionally.
> **The safety audit of the auto-guess feature** (accuracy explicitly out of scope — the owner's
> requirement is that a wrong guess costs nothing and a bug costs a re-shoot). Everything below
> was found by three parallel reviews plus a corpus of 15 deliberately broken audio files, and
> `--guesstest` is what holds the conclusions.

- **A running app can outlive the bundle it was launched from, and §15's "leftover old bundle is
  a trap" then gets worse.** Found live on the dev machine: a process had been running for 10½
  hours from `IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative` — a path that **no longer
  existed**, because `build.sh` had renamed the bundle under it (§15). So it was a pre-1.3.0
  build holding the config it loaded at 01:00, and `_settings.writtenBy` still read `1.2.0`
  hours into a session on 1.3.1. Its next `willTerminate` or `willResignActive` would have
  flushed that stale state over anything written since — §12's two-window clobber, across two
  bundles instead. The installer's `running_in_target` check does catch it (it matches `ps`
  output against the target path, and the dead path is still under the target), which is the
  `LEGACY[]` handling earning its keep. What nothing catches is a *developer* writing
  `config.json` while it runs: check `ps -Ao command | grep -F IntroPlayerNative` first, not
  just whether the current bundle is open.
- **`applyAutoStart` was `applyGuess`'s unguarded twin** — same trigger, same callback, two of
  the same markers, and **none** of its four guards, 20 lines below the comment claiming
  `store.set` direct was the last write in the app to skip the clamps. Consequences, each
  reachable: it wrote both markers under live playback with no `remode`, so the node stayed
  scheduled at the OLD Intro End while `tick()` counted down to the new one — the intro cuts
  dead while the guard strip keeps counting and the button still reads Pause, which on camera
  is indistinguishable from a hang; via `Store.decode`'s degenerate-range repair the move can
  be ~32 s *backwards*, cutting the audio instantly; it overwrote a human's `introStart` because
  `isConfigured` is false whenever `auto` is true, with **no undo entry**; and it ignored `base`,
  so a reconciled round acquired "แก้ที่กอง" badges for edits nobody made.
- **The on-air guard tested `isPlaying`.** Paused-on-a-buzz is `isPlaying == false`. See §7a4 —
  a guess landing in that window changes Intro End, and the next Space derives `.free`.
- **A guess certified itself as human-reviewed.** See §7a4: the two halves disagreed about the
  policy inside a single button press, and the half that ran first won.
- **`wasConfigured` read `existing.configured`, not `existing.isConfigured`** — so a manual 🎯
  on a song configured *before* the flag existed (badge from the value fallback, §9) wrote
  `auto = true`, and `isConfigured` checks `auto` first, so the song lost its badge permanently
  and became eligible for the automatic overwrite above. Moot now: one rule, no flag to restore.
- **Background guesses evicted the operator's own undo entries.** `pushUndo(coalesce: false)`
  per guess, a 40-deep stack with `removeFirst` — reviewing a round at a human pace pushed the
  setter's edits off the bottom, and popping a robot entry runs `undo()`, which can move the
  selection to a different song. The automatic pass pushes nothing now: `mayWrite*` means every
  field it can touch is still exactly at its default, so there is no human state to restore.
- **The task map was cleared without an identity check.** A stale task's main-actor hop erased a
  NEWER task's handle; that task was then untracked and uncancellable, a further press found
  `nil` to cancel, and **two full FFT passes ran concurrently on one path and both applied**. The
  mirror case left a finished task in the slot forever, which made the automatic guess impossible
  for that song for the rest of the session — the feature silently not happening, which §7a4
  already records once for the old shared slot. Entries carry a monotonic id now.
- **A cancelled guess applied half of itself and reported the half it had not written.** A cancel
  landing after `extract` returns still lets the whole main-actor hop run (measured —
  `Task.isCancelled` is observable as true inside it); `AutoDetect.hook` then returns nil while
  `introEnd` has no cancellation check, so Intro End was written alone and the toast printed
  `Hook = 60.00` — the untouched default, announced as the thing the feature had just worked out.
- **`AutoDetect.introEnd` / `hook` ran on the main actor.** Measured in release: 2.1 ms for a
  4-minute track, **34.5 ms at the 20-minute cap**, against `Player.startGuard`'s 20 ms tick —
  and paid for a song that need not be the one on air. (0.24–8.2 s in a debug build.) Detection
  happens inside the detached task now; only the write crosses to the main actor.
- **`Store.decode` and `Handoff` clamped markers with `isFinite` and `max(0, v)` and NO upper
  bound**, while every in-app edit path clamps to `maxTime` — so a hand-edited, foreign-written
  or corrupted file was the only way past, and it was enough for two separate kills:
  `AutoDetect.introEnd` does `Int(start.rounded())`, and `Int(_: Double)` **traps** at >= 2^63,
  so `{"introStart": 1e19}` killed the process (SIGTRAP, exit 133) the moment that song was
  selected; and `round2` multiplies by 100, so any finite value >= ~1.8e306 becomes `+infinity`,
  which `isValidJSONObject` rejects — after which **every** later save fails with nothing naming
  the song, and a relaunch re-poisons it. `Store.clampMarker` is now the one bound and
  `AppModel.maxTime` reads it.
- **`AVAudioFile.framePosition` is a property SETTER that raises an uncatchable Obj-C
  NSException** — there is nowhere to put a `try` and `try?` cannot help; it is `SIGABRT`. And it
  raises for an **in-range** value: 50 KB of random bytes named `.mp3` opens with a plausible
  header (`length` 384 at 11025 Hz) and then throws `'fmt?'` on `framePosition = 0`. Bounds
  checking is not the fix — prove the format is usable with a `read`, which reports the same
  failure as a *catchable Swift error*, and only then seek. **This is also why `--loudtest`
  looked like it always passed: the process died before printing its own verdict.** A suite that
  cannot print a verdict reads exactly like a suite that passed — the `Palette.audit` lesson in a
  new costume.
- The compiler's `will never be executed` on `--loudtest`'s `fail == 0 ? … : …` is a **false
  positive** — proved by inserting one non-foldable failing assertion, which printed
  `ผ่าน 9 ตก 1`. The branch must stay; there is a comment there saying so.
- **`h?.time ?? -1` passed straight into a `CVarArg...` list printed `nan` for `-1.0`.** The `??`
  resolves to the `(T?, T?) -> T?` overload, because `Optional` itself conforms to `CVarArg`, so
  an `Optional<Double>` reached the va_list and `%f` read the wrong eight bytes. `type(of:)`
  reports `Double`, because in a non-variadic context the other overload wins — **so the type
  checker will not warn you and inspecting the expression lies.** Bind to a typed local first.
  It was the only occurrence in the project; the safe idiom is
  `opt.map { String(format: …, $0) } ?? "—"`, where the `??` yields a String.
- **`--autodetect` counted "declined to guess" as a failure**, so one odd file in the library made
  the whole run print `✗ ไม่ผ่าน`. Declining is the correct, safe outcome for audio with no usable
  structure, and the owner's requirement is that an absent guess costs nothing. Skips are printed
  separately, so a detector that silently stopped guessing everything is still visible.
- `AutoDetect` hardening from the same audit: the 20-minute cap bounds **seconds, not bytes** —
  measured, 19 minutes resident is 218 MB at 44.1 kHz and ~876 MB at 192 kHz, so there is a frame
  cap too; `similarity` had only the upper index bound while its sibling `novelty` had both; and
  the per-second loudness loop indexed `frameLoud` with a bound derived from `frameChroma.count`,
  which is safe only because the two appends are unconditional and adjacent.
- **`--updatestage` could only ever report failure.** Its staged-file loop spelled the bundle
  name as the literal `"IntroPlayerNative.app"`, and `Updater.stage()` *requires*
  `Install.bundleName` to be there before that loop runs — so the staged folder definitively
  never held the old name, and the only diagnostic for the in-app update chain printed
  `✗ ไม่ผ่าน` against a good release. `Install.bundleName`'s own doc comment names
  `--updatestage` as the proof that the Swift copy of the name still agrees with a real
  release: **a check that spells its subject literally is not checking the thing it claims
  to.** Two reviewers' reports are what found it; running the flag is what would have.
- **`dist/SHA256SUMS` named the zip beside it and gave the wrong hash.** It was written after
  the `--github` early `exit 0` and after the refusal for a missing download URL, so both
  paths left the *previous* run's file in place describing *this* run's zip — measured on
  1.3.0: `a97f96cd…` claimed for a zip hashing to `1f2ca771…`. The in-app installer checks the
  **manifest's** `sha256`, so it was never affected; the person verifying a hand-delivered zip
  is who it misled, and what it told them was that a good release was corrupt. A checksum file
  that lies is worse than none — the same lesson §7a3 records for a cross-check that compares
  two slightly different things. The hash is a property of the zip, so compute it as soon as
  the zip verifies, before any exit can skip it.
- **`--github` checked everything that can refuse at the END, after ~30 s of building,
  staging, zipping and verifying.** A second `--github` run on an already-published version
  therefore rebuilt and **re-zipped** before refusing — and **zip output is not
  byte-reproducible** (it stores timestamps), so the same commit re-zipped is a different
  file. Measured on 1.3.0: `dist/IntroPlayer-1.3.0.zip` and `dist/SHA256SUMS` were left
  describing `6acdc855…` while the asset the team downloads is `af8a0ed0…` — same size, same
  version, same commit stamp, different bytes. Anyone using SHA256SUMS to check a zip fetched
  from the release page would conclude a good download was corrupt: the lying-checksum defect
  above, one level up, reintroduced by *ordering* rather than by placement. The whole gh
  pre-flight (`gh` present, auth, repo slug, "does this tag exist") now runs **before the
  build**, so a re-run cannot write anything; the tag is re-checked after the build only in
  case someone else published meanwhile.
  > So `dist/` is **not** authoritative for a version that has shipped. `gh release download`
  > is. Hand over the published asset, not a local rebuild of the same commit.
- `gh auth status >/dev/null 2>&1 || echo "✗ gh ยังไม่ได้ login"` **swallowed the real error and
  asserted a cause.** That check also fails on a locked keyring, an expired token and missing
  scopes, and the fix differs for each — observed on this machine, the script refused while
  `gh auth status` itself reported a perfectly good `Logged in to github.com account sonnori
  (keyring)`, and the message sent the operator to re-run a `gh auth login` they did not need.
  Print what the tool actually said. Same shape as `saveNow()` reporting "saved ✓"
  unconditionally.
- `--updatestage` printed `info.openable?.path ?? info.openable?.absoluteString`, and for an
  https URL `.path` is **non-empty** — so the `??` never reached `absoluteString` and a GitHub
  release displayed as `/sonnori/IntroPlayer/releases/download/…`, i.e. **a remote link shown
  as a local absolute path**. `openable` is the one gate that distinguishes those (§15: a
  remote link must be `http`/`https`; a local path must end in `.zip`, and those rules are not
  interchangeable), so it was the single line in the diagnostic that must not blur them.
  Branch on `isFileURL`; do not lean on a nil-coalesce to pick a representation.
- A failed `release.sh` left its **staging tree** in `dist/` (`rm -rf "$STAGE"` was on the two
  success paths only), i.e. an unpacked release folder that looks exactly like an install
  folder. §15 step 3 means the installer would refuse to aim at it, but a human copying into
  it is not covered by that. Now a `trap`, and the unzip dir's `trap` was **folded into the
  same line** rather than added: a second `trap … EXIT` **replaces** the first, which is how
  the new cleanup would have been silently disarmed by the existing one.

**Web version:**
- `loadWaveform` opened with `if(decoding) return;`, which dropped the **newer** request: clicking
  song B while A was still decoding left B with no waveform, no auto-gain and no auto Intro Start,
  stuck on "กำลังวิเคราะห์คลื่นเสียง…" until re-selected. It uses a token — latest selection wins.
- `normalizeEnabled` used to be initialised at script-parse time, when `config` is still `{}` — so
  `_settings.normalize:false` never survived a reload. It is now read inside `init()` **after** the
  config fetch resolves.
- `draw()` used to call `cfgFor(current)` with no null guard (e.g. on window resize before any song
  was selected), creating a `config["null"]` entry. `draw()` now returns early and `cfgFor()` refuses
  to store for a falsy name.
- The green "set" badge used to test `c.introStart||c.introEnd||c.hook`, which the defaults
  (`introEnd:15`, `hook:60`) satisfy — so every song ever selected looked configured. See
  `isConfigured()` in §9.
- `document.querySelectorAll('.nudge')` also matched the trim **0** reset button (it carries
  `.nudge` but no `data-k`) and was assigned *after* `$('trimReset').onclick`, silently replacing it.
  Clicking it wrote `config[song][undefined] = NaN`, which serialises as `"undefined": null`. The
  selector is now `.nudge[data-k]`.
- The intro-end auto-stop ran only on the rAF tick, which Chrome freezes for a background window —
  see the `guardId` note in §8b.
- The keyboard handler switched on `e.key`, so every letter shortcut died whenever the Thai input
  source was active. See §11.
- **The song list would not scroll once a column was taller than the window.** Two separate breaks
  in the same height chain: (a) `#songList` sits between `.list` and `.cols` and had no flex rules,
  so it took its content height and the columns were sized against *that* rather than the window;
  (b) `.cols` used `flex-basis:auto`, which makes the base size the content height. Both let the
  stack outgrow `.list`, whose `overflow:hidden` then clipped it with no scrollbar anywhere. The
  narrow fallback had a third variant — `.col` kept the wide layout's `flex:1 1 0`. Rule of thumb
  for this layout: **every element between `.list` and `.colbody` needs `flex:1 1 0` + `min-height:0`**
  (or `flex:0 0 auto` in the stacked fallback, where `.list` itself is the scroller). Only shows up
  with more songs than fit on screen — test with ~60.
- The log overlay used the `hidden` attribute while `.logwrap` set `display:flex`. An author
  `display` beats the UA sheet's `[hidden]{display:none}`, so the panel could not be closed at all.
  Fixed with an explicit `.logwrap[hidden]{display:none}`. Any future overlay needs the same pair.

---

## 13. Suggested next steps / ideas

Product / UX
- Optional **true audio bypass** switch for bit-perfect output (see §7 note).
- Adjustable **fade length** and **loudness target** in the UI (currently `FADE_SEC` / `TARGET_RMS`
  constants). The level *bar* (gain as a position between the ±12 dB clamps, with a tick for the
  automatic part alone so the trim's contribution is the visible gap) is done — native only.
- Separate **audience/second-screen view** (read-only progress, big song reveal).
- Auto-sort or hide **played** songs. (Per-episode song sets via subfolders: done, §8c.
  Setter → operator handover: done, §8e. Typed marker fields, `Shift+←/→` nudge, bounded hook
  whole-song overview strip, log-as-pane, level bar, destructive buttons behind `⋯`,
  light/dark themes, Intro End + Hook auto-guess, cover art: all done, native only.
  The bounded hook audition (`G`) was done and then **removed** — see §11. Versioning, release packaging, the update check and the
  data-preserving installer: done, §15.)
- **Validate the hook detector against real annotations.** §7a4 ships unvalidated because the
  library has no trustworthy hook ground truth. The cheap way to get some: have the setter run
  a round normally, then compare the hooks they confirmed against what `--autodetect` proposed.
  Twenty confirmed hooks would say whether the detector is worth keeping, tuning or dropping.
- **The cover-art fallback is near-useless for Thai titles** (2 clean / 5 nothing / 2 wrong out
  of 9). It only matters for files with no embedded art, which is currently none of them — but
  if that changes, Spotify's catalogue is the obvious better source and the blocker is the
  credential, not the code (§8f).
- **Port the handover UI to the web version.** The web app plays, marks and logs as before and
  round-trips `base` untouched, but export / import / diff / pre-flight exist only in the native
  app. Only matters if the setter's machine is not a Mac.
- **Sign + notarize the bundles.** The one part of §15 that is not solved, and it is **not**
  once-per-machine: the installer strips quarantine from what it copies into the target, but the
  *next* release's own `ติดตั้ง-อัปเดต.command` arrives in a new download and Gatekeeper records
  approval per file. So a zip delivered through a browser or a Drive *download* needs
  right-click → Open every time; a *synced* folder avoids it. Needs a paid Developer ID — a
  product decision, not an engineering one.
- **Give `round.json` the forward guard `config.json` just got (§15).** This is the real gap:
  `round.json` is the file that actually crosses machines (§8e), and `RoundPackage.version = 1` is
  **written and never read** — a round from a newer build parses silently as version 1. It also
  carries no `writtenBy`, and worse, import decodes into a struct while the return path
  re-encodes *from* the struct, so unknown fields are **dropped rather than merged**: a round
  going setter(new) → operator(old) → setter(new) comes back with the newer build's fields
  erased. That is precisely what §15's merge-into-`raw` design avoids for `config.json`,
  happening in the file §8e calls "the unit of handover". Read `version` in `decode`, warn in the
  receive banner and in `Handoff.plan`'s sheet before anything is accepted, add `writtenBy`, and
  keep an unknown-keys passthrough so a round trip is lossless.
- **Put the app version in `log.json` events**, so the edit room's index can say which build
  produced a take.
- **Durable backup of the questions — the local half is DONE (§5c); the off-machine half is
  not.** Launch snapshots cover every cause except losing the folder or the disk, and
  `_settings.backupDir` closes that too — but **there is no UI for it**, so it has to be typed
  into `config.json` by hand, which means in practice no crew machine will have it set. The
  About sheet is the obvious home and the obstacle is its fixed 620 pt height (§15's news-strip
  note: `CenterView`'s only flexible child has a hard floor, so content that overruns centres
  and clips both ends). Superseded text follows, kept because the reasoning still applies:
- ~~**Durable backup of the questions.**~~ `config.json` / `log.json` are deliberately untracked
  (§5b) and the installer's `backups/` lives *inside* the folder whose loss is the risk and only
  fires on an update — so it is an undo for the update, not a backup. Between updates the
  questions still live in exactly one place. A snapshot on launch, or a scheduled copy into a
  synced folder, would close the one real data gap left. Anything that says "always backs up for
  you" must be bounded accordingly, or it makes the gap *feel* closed.
- Countdown timer / buzzer-time display during intro.

Engineering
- **Refactor `index.html`** into `app.js` + `styles.css` if it keeps growing (still no build step).
- Add a small **test suite** (e.g. Playwright) for the state machine and the intro-end/fade logic.
- Make **port configurable** (env var / CLI arg). "Port already in use" is handled; the `.app`
  reuses a live instance rather than failing.
- Consider **EBU R128 (ffmpeg loudnorm)** offline pre-processing as an alternative/complement to the
  in-browser RMS normalization for more accurate leveling.
- Persist **UI prefs** (last selected song, normalize toggle) — normalize already persists.

---

## 14. Quick verification recipe

### Native app

```bash
./native/build.sh debug
BIN="./RGF Intro Player.app/Contents/MacOS/IntroPlayerNative"   # the name has a space

# back up first — the write-y flags touch the operator's real data
cp config.json log.json /tmp/

# read-only — safe to run any time
INTROPLAYER_DIAG=1 $BIN --analyse     # detection + loudness per song
INTROPLAYER_DIAG=1 $BIN --playtest    # overshoot must be 0.000, ignoreEnd must still bypass
INTROPLAYER_DIAG=1 $BIN --revealtest  # Reveal plays on, and the intro guard re-arms after it
INTROPLAYER_DIAG=1 $BIN --grabtest    # two-stage marker rule, 10 assertions
INTROPLAYER_DIAG=1 $BIN --palettetest # both themes: contrast, ladder, deutan ΔE — 44 assertions
INTROPLAYER_DIAG=1 $BIN --loudtest    # BS.1770 coefficients + on-air spread + limiter headroom
INTROPLAYER_DIAG=1 $BIN --autodetect  # Intro End / Hook guesses with their evidence
INTROPLAYER_DIAG=1 $BIN --guesstest   # clamps vs NaN/inf/1e19 + the admission rules per song
INTROPLAYER_DIAG=1 $BIN --snapshot    # writes a real snapshot; restores nothing, deletes nothing
INTROPLAYER_DIAG=1 $BIN --guessflow   # plays a song for real; RESTORES the song it touched
INTROPLAYER_DIAG=1 $BIN --artwork     # cover source per song (offline, makes no request)
INTROPLAYER_DIAG=1 $BIN --remodetest  # marker edits mid-playback: 3 cases, none may outlive Intro End
INTROPLAYER_DIAG=1 $BIN --takes       # running order: synthetic self-check + the real log
INTROPLAYER_DIAG=1 $BIN --timefmt     # typed-field parser
INTROPLAYER_DIAG=1 $BIN --overview    # strip data matches columnPeaks; caches stay independent
INTROPLAYER_DIAG=1 $BIN --preflight   # the handover checklist
INTROPLAYER_DIAG=1 $BIN --updatecheck # semver compare + the configured feed (§15)
INTROPLAYER_DIAG=1 $BIN --updatestage # the in-app chain minus the swap (needs a feed) (§15)
$BIN --version                        # ungated

# the release path — no project data is touched, dist/ and a temp dir only
./native/release.sh --allow-dirty     # 10 zip checks must all pass
./native/installer-test.sh            # 123 assertions, 21 cases; data byte-identical

# these WRITE — the cp above is not optional
INTROPLAYER_DIAG=1 $BIN --resetflow   # must print "✓ ผ่าน" and keep every log event
INTROPLAYER_DIAG=1 $BIN --handoff     # then: rm -f songs/*/round.json

cp /tmp/config.json /tmp/log.json .  # restore
```

### Web version

```bash
# syntax-check the client script
python3 - <<'PY'
import re; h=open('index.html',encoding='utf-8').read()
open('/tmp/app.js','w').write(re.search(r'<script>(.*)</script>',h,re.S).group(1))
PY
node --check /tmp/app.js

# smoke-test the server
python3 server.py & sleep 1
curl -s localhost:8000/api/songs
curl -s -D - -o /dev/null -H 'Range: bytes=0-99' "localhost:8000/songs/SOME_FILE.mp3" | grep -i 'HTTP\|Content-Range'
```

---

## 15. Versions and updates (handing the app to the team)

Once the folder is on more than one machine, "which build is this" stops being obvious and starts
being the first question of every support call. This section is what makes it answerable, and what
makes replacing the program safe while the questions stay put.

### Why the swap can be surgical at all

The bundle sits **inside** the project folder, with `songs/`, `config.json` and `log.json` as its
siblings (§5). So the program and the data are already physically separate:

| | | |
|---|---|---|
| **program** — replaced by an update | `RGF Intro Player.app`, `IntroPlayer.app`, `server.py`, `index.html`, `วิธีใช้งาน-SETUP.md`, `ตรวจสอบเครื่อง.command`, `start.command`, `VERSION` | the release's |
| **seeded once, never overwritten** | `se/` | an operator may have swapped in their own stings |
| **never touched** | `config.json`, `log.json`, `songs/` | the only copy of the questions |

That table is the whole feature. It is the same split as §5b's tracked-vs-untracked, for the same
reason: git protects the program, not the questions — and so does the installer.

### The bundle is `RGF Intro Player.app` (renamed in 1.3.0)

The executable inside is still `IntroPlayerNative`: it is what `pgrep -f` matches on, what every
documented diagnostic invokes, and renaming it buys nothing the bundle name has not already got.

Two things made this more than a find-and-replace.

**A leftover old bundle is a trap, not litter.** `IntroPlayerNative.app` still launches and
still reads the SAME `config.json` and `log.json`, so an operator opening the familiar icon runs
the old build with nothing saying so — a second cause of "I installed the new one but nothing
changed". `installer.command` therefore has a `LEGACY[]` list. Those bundles are moved into
`backups/` with everything else and **restored by `rollback`** (on a failed update the old
bundle may be the only working app on the machine), but never re-installed. The running-check
covers the legacy executable too, or an update could swap under an old app holding `config.json`
open — §12's clobber across two bundles instead of two windows.

**The name has a SPACE.** `PROGRAM[]`, `SEED[]` and `LEGACY[]` in `installer.command` are now
declared **one entry per line**, and `release.sh` parses them that way. The old form was
space-separated and read with `read -r -a`, which would have split `"RGF Intro Player.app"` into
three filenames — and the cross-check that proves `release.sh` and the installer agree about
what ships would then have compared nonsense to nonsense and passed. `release.sh` reads
`APPBUNDLE` out of the installer so there is one source for the name, and `installer-test.sh`
does the same rather than hardcoding it, so a future rename cannot leave the harness asserting
the old name and passing in every possible world.

`installer-test.sh` is **123 assertions over 21 cases** now: the fixture's "previous release" is the
legacy-named bundle, which makes the ordinary update path the migration path, plus two new
checks — the legacy bundle is gone from the target, and it is in `backups/` rather than deleted.

### Version identity

`VERSION` at the repo root is the single source. `build.sh` stamps it into Info.plist together with
the short git sha and the build date, and `AppVersion` reads all three back out, so the number in
the UI cannot drift from the source it was built from. A build made with uncommitted edits is
stamped **`<sha>+dirty`** — it is not the commit it names, and once the folder is in other people's
hands that distinction is the difference between a reproducible report and a guess.

Where it shows up: in the song list's header row, **left of the spacer, right after
`⟳ อ่านโฟลเดอร์ใหม่`** (clickable → About), in the `⋯` menu, in About, from `--version`, and in
`_settings.writtenBy`. Describe it to an operator as "ใต้จำนวนเพลง ข้างปุ่ม ⟳" — four documents
once said "bottom-left", which is the opposite corner from where it was, and that string is both
the one read aloud on a support call and the final verification step of an update.

It sits left rather than right for a second reason: it was 6 pt from the `⋯` menu that holds the
two actions which throw work away — ~2 mm at 81 PPI. And it is `Palette.muted` (8.06:1) at rest,
not `Palette.dim` (4.80:1): the moment somebody squints at this number is the support call, i.e.
the resting state, so the dimmest tier in the app was exactly backwards. Cyan is reserved for
"there is an update", which makes it the durable cue that survives dismissing the strip.

> `writtenBy` means **last written by a native build**. The web app round-trips `_settings`
> key by key, so the field survives it untouched — but is not updated by it.

> `native/Info.plist` carries `0.0.0-dev`. That is deliberate: an un-stamped build should be
> obviously un-stamped rather than quietly claiming a release number.

### `_settings.schema` — the forward guard

Two builds can open one `config.json` once the folder is shared. `Store.set` already merges into
the raw dictionary, so **unknown keys written by a newer build survive an older one** — that is
what actually protects the data, and it predates this feature. `schema` is how the older build can
*say* it is the older one instead of looking fine:

- absent means 1, so every config written before this existed reads as current and raises nothing;
- a non-`Int` value reads as current too, or a garbled field would nag on every launch;
- the write is `max(Store.schema, schemaOnDisk)` — **never downgrade a number the file already
  carries**, or the build that actually understands the format gets told it is stale;
- `schemaAhead` raises a line in the news strip and nothing else. **Fail visible, not shut**: an
  operator mid-taping must not be locked out of their own questions over a version number.

### One news strip, not a stack (`NewsBanner`)

The update notice and the schema notice were two separate full-width banners. They are now one
slot showing the most actionable item, with a `+N` for the rest, for three measured reasons:

- **They co-occur by construction.** If the config was written by a newer build then that build
  exists, so the feed names it — so both fired together and said the same thing twice.
- **Height.** `CenterView`'s only flexible child is the waveform and it has a hard
  `minHeight: 160` floor, so content that overruns the window centres and clips **both** ends:
  the song title off the top and ✓ Correct / ✗ Wrong off the bottom, with no scroller. Two
  banners plus `saveFailureBar` plus `ReceiveBanner` is ~226 pt of strip. The production
  2560×1080 absorbs it with ~200 pt spare; a laptop at the declared `minHeight: 640` does not —
  and that minimum was already ~13–67 pt short before this feature existed.
- **Hue.** The update notice is cyan because §6d reserves amber for "the intro-end stop is not
  armed", and spending amber on software news dilutes the one warning that must never be ignored.
  The schema notice was then given amber on the *loose* reading of the same rule, at the same
  0.14 fill, 60 pt from the real thing and stacked against the red save-failure bar it sits only
  deutan ΔE 10.6 from — both opening with "⚠". It cannot be both ways. The schema notice loses
  nothing (its own text says so), is not actionable during a taping, and is true forever once two
  machines differ, so it gets no warning hue at all.

`ReceiveBanner` stays separate and renders **above** it: a round waiting to be accepted is work,
and software news must not push it further from the header.

Dismissals persist (`_settings.dismissedUpdate`, `dismissedSchema`). Session-only dismissal meant
the notice returned on every launch — and `schemaAhead` is permanent once two crew machines are on
different builds, which is the *normal* state of a rollout. A notice that is always there is a
notice nobody reads.

One case in the strip is **not** dismissible and is amber: the app was launched from an unzipped
release folder rather than an install. `AppPaths.root` is just the bundle's parent (§5), so
double-clicking the app inside a download — a natural "let me see if the new one works" — gives an
empty library that looks exactly like §8c's "the app can't find my songs". It has one cause and
one fix, so hiding the only thing that explains it would be the worst possible kindness.

### The update check

`_settings.updateFeed`, empty by default, pointing at either an `https://` URL or an absolute path
into a synced Drive/Dropbox folder — a bare folder or a URL ending in `/` gets `manifest.json`
appended. The folder form needs **no network at all**, which matters because this machine is
offline on set by design (§2). `UpdateInfo.openable` is the single gate before anything reaches
`NSWorkspace`: a remote link must be `http`/`https`, and a **local path must end in `.zip`** — a
release, not an executable.

> That `.zip` rule is the fix for a trap worth naming. The guard used to be split: the URL branch
> checked the scheme, the path branch checked nothing, so `download: "/Applications/Anything.app"`
> was openable. The only thing making that safe was `openUpdateDownload` happening to use
> `activateFileViewerSelecting` for file URLs — i.e. the comment claimed the *type* was safe while
> the safety lived in the *caller*. Anyone simplifying the caller to one `NSWorkspace.open(u)`
> would have been following the documented invariant straight into "a manifest can launch an
> arbitrary app". `--updatecheck` now tests the bare-path form too, not just `file://`.

```json
{ "version": "1.2.0", "notes": "…", "download": "…", "minMacOS": "13.0" }
```

- Checked **once on launch** and on demand from About. Not on a timer: a network call is not
  something to be doing between a buzz and a pause. The check is latest-wins — `setUpdateFeed`
  cancels any in-flight check and the result is dropped unless `feed == store.updateFeed` still
  holds. Without that, a check against the old feed could land afterwards and raise a banner for
  a feed that is no longer configured, and it left `updateChecking` true, which disabled the one
  button the operator needed to test the feed they had just saved. Same class as the web
  version's `loadWaveform` token (§12).
- `minMacOS` is **enforced**, not just displayed. Showing it and stopping there was a trap: the
  operator runs the installer, a working bundle is replaced by one that cannot launch, and the
  way back is a `backups/` folder they will not find unaided. `needsNewerOS` suppresses the
  download button and says so in words.
- The 5 s bound is a **dedicated `URLSession`** with `timeoutIntervalForResource`.
  `URLRequest.timeoutInterval` is an *idle* timeout and `URLSession.shared` inherits a 7-day
  resource timeout, so a server dribbling a byte every few seconds kept the request alive
  forever — leaving About stuck on "กำลังเช็ก…" with both buttons disabled for the session.
- `manifestLocation` is **purely syntactic**. `AboutPanel` calls it from `body` for the
  "จะอ่านจาก:" preview, and that body is invalidated by every `AppModel` publish — ~50x/s while
  playing. The first version probed the filesystem to decide folder-vs-file, which on the
  headline use case (a `~/Library/CloudStorage/GoogleDrive-…` path) is a `stat()` serviced by a
  userspace FileProvider extension: a stalled or re-authenticating extension would have blocked
  the **main thread once per frame**. A query or fragment now means "the operator pasted a link"
  and is left alone, because appending `manifest.json` to a Dropbox `?rlkey=…` share link
  produced `…/abc/manifest.json?rlkey=…` → 404, with nothing saying we had rewritten their URL.
- A failed check is the *expected* state on set, so it never raises a modal and never toasts on
  the automatic pass — it just sits in About. 5 s timeout.
- `notes` is capped at 1200 chars and `download` at 500: they are text from outside the app going
  into a sheet, and a runaway string must not push the buttons off screen.
- The notice carries **อัปเดตเลย**, which installs it — see the next section. The manual
  double-click path still exists and is the documented fallback.
- `AppVersion.compare` is numeric per component. A string compare puts `"1.10.0"` *below*
  `"1.9.0"`, which would silently hide every release after the ninth — a bug that surfaces months
  later, on the machine of whoever is furthest behind. `--updatecheck` pins that case.

### Installing from inside the app

> Superseded: this used to read "it never downloads and never installs — the check raises a
> banner; the swap is a deliberate double-click." That was a misreading of the scope, not a
> safety finding. The constraints below are what the original caution was actually about, and
> they are all still enforced.

An app cannot replace its own running bundle, so the last step has to be another process. That
process is the **same `ติดตั้ง-อัปเดต.command`** run with `--unattended`: the backups, the
checked `rm`, the full rollback and the "ask the installed binary its version before claiming
success" check are reused rather than reimplemented, which is why the 123 assertions cover the
in-app path too.

The chain, and every step of it can refuse:

1. **Three refusals before anything is downloaded.** Not while `player.isPlaying` — the swap ends
   in quitting the app, and a song may be on camera. Not when `needsNewerOS`. Not from an unzipped
   release folder (`launchedFromRelease`), where there is no install to update.
2. **Confirm**, through `confirmDestructive`, so Return and Space land on Cancel (§12). It names
   the version and says the app will close and reopen itself.
3. **Download** to a fresh dir under the system temp root, so a crash mid-way leaves nothing in
   the operator's folder. A feed in a synced folder is already on disk, so that case is a copy and
   needs no network. Progress is throttled to ~10 updates/s.
4. **Verify, in three independent ways**, before anything is swapped: the zip's SHA-256 against
   the manifest's (catches a truncated download or a half-synced Drive file — not an attacker,
   since whoever can replace the zip can replace the manifest beside it); the bundle and installer
   are present; and then it **runs the staged binary's `--version` and requires it to equal the
   manifest's version**. That last one is what makes a one-click update defensible, and it is not
   hypothetical — the first test of this chain used a manifest claiming 9.9.9 over a 1.1.0 zip and
   the whole thing stopped there with the working app untouched.
5. **Hand off and quit.** `Updater.apply` launches the installer detached with
   `--wait-pid <our pid>`; `store.saveNow()` flushes first, because the debounced save would
   otherwise still be pending. The installer waits for that pid to disappear (bounded at 30 s,
   plus 0.5 s for the terminate-time write to land), swaps, and relaunches.

**This path has no Gatekeeper step at all** — worth knowing, because it removes the most repeated
friction in the whole feature. Quarantine is applied by whatever *downloads* a file (a browser,
Drive's client), not by the kernel; a zip written by this app's own `URLSession` carries no flag.
So the staged bundle runs and the installed one opens with no right-click → Open and no trip to
System Settings. A release delivered as a hand-passed zip still needs that dance every time.

`_settings.lastRanVersion` closes the loop. It is rewritten on every save, so a difference on
launch means this is the first run of a new build — which is the only way the operator gets told
the update *worked*. Without it the sole evidence is a notice that failed to appear, which is not
something anybody can check.

Three things that were wrong on the way here, all of which looked fine:

- **The running check was too broad.** `pgrep -f "$APPEXE"` matches any instance anywhere, so the
  unattended run refused whenever *another* copy was open — and in the in-app flow the app it was
  refusing for was the one that had just quit. There are two scopes now: `running_anywhere` is an
  early courtesy refusal in the attended flow, and `running_in_target` is the load-bearing one,
  checked after the target is known. A different install elsewhere on the disk is none of our
  business; two folders have two `config.json`s, so §12's clobber does not apply.
- **The progress callback was `@MainActor`.** `fetchZip` is a non-isolated async func, so it runs
  on the generic executor — and a main-actor callback from there deadlocks any caller blocking the
  main thread, which is exactly what a headless diagnostic does. The callback is plain now and the
  UI hops to main itself.
- **Unattended answered its own dialogs with the wrong button.** `say` returned the *first*
  argument, which is the cancel slot by this script's convention, so the unattended run cancelled
  itself; and the confirm block ran regardless of mode, so it reached a dialog at all. It returns
  `${!#}` — the default, what Return would do — and both target-resolution dialogs are gated on
  attended.

```bash
INTROPLAYER_DIAG=1 $BIN --updatestage   # fetch → download → unpack → verify, then delete
```

`--updatestage` is the whole chain except the swap, against whatever `_settings.updateFeed`
points at. It needs a feed holding a real `manifest.json` + zip whose version is higher than the
running build; point it at a folder and it prints exactly what the installer *would* be invoked
as. The swap itself is covered by `installer-test.sh`, which can test it without quitting
anything.

### Cutting a release

```bash
./native/release.sh                    # build + package the version in ./VERSION
./native/release.sh --download <url>   # also fill in manifest.json's download field
./native/release.sh --skip-build       # package the bundle as it stands
./native/release.sh --allow-dirty      # package from a tree with uncommitted edits
```

**Everything that can refuse runs before the build.** With `--github` that means `gh` being
present, the login, the repo slug and whether `v<VERSION>` already exists — all checked while
`dist/` is still untouched, because a re-run that builds first **re-zips**, and zip output is
not byte-reproducible: the same commit packaged twice gives two different files. See §12 for
what that cost on 1.3.0. The consequence worth remembering is a rule about where truth lives:

> Once a version is published, **`dist/` is not authoritative for it** — `gh release download`
> is. Hand over the asset from the release page, never a local rebuild of the same commit,
> even when `git` and the version stamp both say they are identical.

Refuses a dirty tree unless told otherwise, and asserts the bundle's stamped version equals
`VERSION` — otherwise a release could be cut from a stale app and nobody would find out until a
support call. Output: `dist/IntroPlayer-<ver>.zip`, `dist/manifest.json`, `SHA256SUMS`.

The dirty check is `git status --porcelain`, **not** `git diff --quiet HEAD --`: the latter
returns 0 when the only change is an *untracked file*, which is the commonest form of uncommitted
work and was the state this entire feature was written in, `VERSION` included. For the same
reason `COMMIT` is read back **out of the built bundle's Info.plist** rather than recomputed —
recomputing dropped `build.sh`'s `+dirty` suffix, so the published `manifest.json` asserted a
clean sha for a binary that was not that commit, in the one machine-readable artifact that
outlives the conversation.

It also refuses to write a manifest with an empty `download` (pass `--no-download` to skip the
manifest and hand the zip over by hand). An empty one produces a dead-end notice: the operator is
told there is a new version and then told to unzip a file they have no way to get.

Three checks in it are worth keeping:

- **`SHA256SUMS` is written as soon as the zip verifies**, before any path can exit. It used to
  be written down in the manifest section, which both `--github` and the no-download refusal
  skip — leaving the previous run's hash beside this run's zip. See §12; the short version is
  that a checksum which names the wrong file is worse than no checksum.

- **It verifies the zip, not the staging folder.** Permissions and bundle structure are what
  survive or fail to survive a zip, a Drive upload and Archive Utility; checking the folder you
  just built proves nothing about that. It unzips to a temp dir and asserts the `.command` files
  are still executable, the binary is still universal, no `config.json`/`log.json`/`songs/` rode
  along — and runs the unzipped binary's `--version` to confirm it reports the right number.
- **It asserts `SHIP[]` and the installer's `PROGRAM[]` name the same files**, and reads `SEED[]`
  out of the installer rather than hardcoding `se/`. release.sh decides what ships and the
  installer decides what lands; a file in one list and not the other goes stale in place. This
  was a real miss — `ตรวจสอบเครื่อง.command` shipped in the zip and was never copied out of it,
  so a team member would have had a new app reporting through the previous release's diagnostic
  script.

### The installer (`native/installer.command` → `ติดตั้ง-อัปเดต.command` in the zip)

Double-clicked by the operator. In order, and the order is the point:

1. **Refuses while the app is running** — matched on the executable path, not the word
   "IntroPlayer", so the script's own argv cannot look like a running app. Warns separately if
   `server.py` is up, because the web fallback holds `config.json` in memory (§12) — and that
   dialog defaults to **Cancel**, per §12's `confirmDestructive` lesson: the destructive choice
   must never be what Return or Space activates, least of all on the one dialog whose wrong
   answer can cost a day of markers.
2. **Finds the folder with no questions asked**, from a breadcrumb the app writes at
   `~/Library/Application Support/IntroPlayer/location` (the folder can move, so it is rewritten
   on every launch — but never from a temp root and never from a folder with no `songs/` or
   `config.json`, so a trial launch from a download cannot poison a good breadcrumb). A folder
   picker is the fallback, and **it confirms the picked path too** — that branch used to go
   straight from the picker to the swap, which was backwards: the branch where a non-technical
   operator navigates by hand is the one that most needs confirming.
3. **Knows what is not an install.** The target must contain `config.json` or `songs/` *and* must
   not contain the release markers (`ติดตั้ง-อัปเดต.command`, `อ่านก่อน.txt`). The earlier
   "songs/ OR config.json OR the bundle" was wrong twice: any folder with a subdirectory called
   `songs` qualified — and `index.html`, `server.py` and `start.command` have generic names, so a
   wrong answer destroyed the operator's own files of those names — while an unzipped *release*
   qualified via the bundle clause, which is how the installer could aim at `~/Downloads` and
   leave the real install untouched. `[ "$TARGET" -ef "$SRCP" ]` is the second line of defence;
   a string compare let the same directory through under two spellings (a symlinked
   Desktop/Documents, `/tmp` vs `/private/tmp`, a case difference on a case-insensitive volume)
   and the installer then installed over its own source.
4. **One at a time**, via a `mkdir` lock. An operator who sees nothing happen double-clicks
   again, and two concurrent runs raced into the state below where rollback was disarmed.
5. **Backs up before anything moves** — `config.json` and `log.json` **copied** (not ours to take
   away), and then **every program file it is about to replace moved** into `backups/<timestamp>/`.
   It stops if the data copy failed. Backing up only the bundle meant a failure part-way restored
   the bundle, announced "คืนแอปตัวเดิมให้แล้ว", and left `index.html`, `server.py` and the
   diagnostic **deleted with no copy anywhere** — i.e. the mid-taping web fallback (§6c) and the
   tool you would ask them to run next.
6. **Swaps with every exit status checked, and rolls everything back on any failure.**
   `rollback` **always** dies; it used to `return 0` when there was nothing to restore, so on a
   *fresh* install `cp -R … || rollback` was satisfied by the rollback itself — the loop carried
   on past a failed copy and the operator was shown "เรียบร้อย" over a bundle with no executable
   in it. `rm -rf`'s status is checked and the destination asserted gone before the copy, because
   when `rm` fails on a *directory* `cp -R src dst` copies *into* dst and returns 0 — one locked
   or sync-held file nested the new bundle inside the old one and reported success.
7. **Strips `com.apple.quarantine` from what it copied**, never the whole folder — the operator's
   own files are not ours to relabel.
8. **Proves the installed app runs** before reporting success: it asks the new binary
   `--version` and rolls back if the answer is not the version it just installed. `release.sh`
   makes the same check against the zip; the thing the operator ends up with deserves it more.

Only three `rm -rf`s exist in the script and all write their target as `"${TARGET:?}/${item:?}"`,
so the shell aborts rather than running the command if either variable is somehow empty.

```bash
./native/installer-test.sh     # needs dist/ — run ./native/release.sh first
```

**123 assertions** against the real script with `osascript`/`pgrep`/`open` stubbed, so
**production code is tested unmodified**. It proves the promise the feature rests on by hash: `config.json`,
`log.json`, `songs/` and a customised `se/correct.mp3` come out byte-identical. 16 cases: the
app-running refusal, the web-server warning (including that Cancel is the default button), the
cancel, a full update (asserting *every* program file was replaced), a mid-copy failure (asserting
every program file came *back*), install-onto-itself directly and through a symlink, a stale
breadcrumb pointing at a download, a folder that merely contains `songs/`, a fresh install that
completes, a fresh install whose source is unreadable, a path with spaces + Thai + a quote,
the concurrency lock, dialogs denied by TCC, backup pruning — and five for `--unattended`: the
in-app swap (data by hash, relaunch called, no dialog opened, log written), a missing `--target`,
a `--target` that is not an install, an app still running *in the target*, and a `--wait-pid`
that is already gone.

> The stub answers dialogs from a **queue**, which matters: a single fixed answer meant any flow
> with two questions — the entire fresh-install branch, the branch where rollback was disarmed —
> fell through to cancel, and its assertions then passed in every possible world.

> **Gatekeeper is not solved, and it is not once-per-machine.** The installer strips the flag from
> what it copies *into the target*, which cannot help the **next** release's own
> `ติดตั้ง-อัปเดต.command`: that file arrives later, in a new download, and Gatekeeper records
> approval per file. So a release delivered as a downloaded zip needs right-click → Open (or
> System Settings → Privacy & Security → "Open Anyway", which is the reliable route on recent
> macOS) **every time**. A release delivered through a *synced* Drive/Dropbox folder avoids the
> browser quarantine path entirely, which is the better channel for that reason as well as the
> offline one. Signing would need a paid Developer ID.

### `ตรวจสอบเครื่อง.command`

Predates this work and is aimed at the same problem — "double-click this on the machine with the
issue and send a screenshot". It now leads with `[0] เวอร์ชั่น`: the `VERSION` file, the bundle's
stamped version, and `config.json`'s `schema`/`writtenBy`. If `VERSION` and the bundle disagree it
says so — that means the folder was updated by hand and half of it is stale, which is invisible
otherwise and is exactly what "I installed the new one but nothing changed" looks like. It also
checks quarantine on **both** bundles now; it only ever checked the web launcher, which stopped
being the app people open at §6c.

> Its Python block runs with `python3 -I`. The cwd is the install folder, which holds files we did
> not write, and a planted `json.py` there would otherwise be imported.
