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
├── brand/               # logo.png — the programme's logo, drawn in the header. Seeded like
│                        # se/: an update never overwrites it, and it is not in the public
│                        # repo (README.txt is). See §6e.
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

## 5d. Where the questions live (`AppPaths`) — the DMG groundwork

Asked for as "ทำเป็น dmg แล้วลากลง Applications ได้ป่ะ แล้วให้เลือก Browse Folder ที่เก็บไฟล์เพลง".
**Those are one change, not two.** `AppPaths.root` used to be the bundle's parent, so an app in
`/Applications` would look for `/Applications/songs/` and try to write `/Applications/config.json`.
Making the data folder choosable is what lets the bundle move; the DMG is then packaging.

This section is **step ก**: the data root is explicit and choosable, while the app still sits beside
the data by default. Nothing about an existing install changes — see the resolution order.

### `programRoot` vs `root`, and why the names are the only defence

| | what it is | who reads it |
|---|---|---|
| `AppPaths.programRoot` | the folder the `.app` sits in. Derived, never stored | the installer target, `InstallLocation`, `launchedFromRelease` |
| `AppPaths.root` | where the questions are. Resolved, cacheable, choosable | `songs/`, `config.json`, `log.json`, `se/`, `brand/`, `Snapshot` |

They were one value, so **every call site had to be read and classified by hand**. Get one wrong
and the failure is silent and severe in both directions: `Updater.apply` handed the data root would
tell the installer to replace program files *inside the operator's questions folder*; `Store` handed
the program root would look for a library beside the app and find none. There is no test that
catches this — only the names. `--roottest` section 4 at least pins that the five data accessors
all hang off one root.

### The resolution order (`AppPaths.resolveRoot`)

1. **what the operator chose** — `UserDefaults`, key `dataRoot`;
2. **the bundle's sibling** — the classic layout. **This is why nothing breaks today:** the folder
   beside the app wins before any prompt;
3. **the breadcrumb** the app already writes (§15), so a machine that has been running the classic
   layout keeps working after the app moves to `/Applications`, with nobody asked anything;
4. **nothing** → `.none`.

> **`beside` must come before `breadcrumb`, and the first draft had it the other way round.**
> `InstallLocation.record()` rewrites the breadcrumb from the program folder on every launch — but
> it runs in `AppModel.init` *after* the root has been resolved. So with the breadcrumb first,
> copying a whole classic-layout folder somewhere new and opening it read the **old** folder for
> one entire launch before the breadcrumb caught up: a session of marker edits landing in the copy
> the operator thought they had left behind. Found by running `--whereami` in the project folder
> and seeing `source: breadcrumb` where `beside` was the honest answer — the two happened to be
> the same path, so nothing looked wrong. In `/Applications` there is no library beside the app,
> so step 2 falls through and the breadcrumb still does the migration it exists for.

Each candidate must pass `looksLikeLibrary`: it has `songs/` (as a *directory*) or a `config.json`,
and is not in a temp root, not on `/Volumes`, not inside `backups/`, and not an unzipped release
(§15's `ติดตั้ง-อัปเดต.command` / `อ่านก่อน.txt` markers). Those exclusions are lifted out of
`InstallLocation`, which had the identical list private — and that mattered, because **the resolver
reads the very file `InstallLocation` writes**, so a breadcrumb the writer rejects could otherwise
still be adopted by the reader.

> **The chosen root is in `UserDefaults`, not in `config.json`.** It cannot be in `config.json`:
> that file lives *inside* the root. Chicken and egg. It is the one setting in this app that is not
> in `_settings`, and that is structural rather than a style slip.

### `.none` must stay inert — the most important guard in this change

With nothing resolved, `AppPaths.root` falls back to the bundle's parent. So a save in that state
would write `config.json` next to the app — i.e. `/Applications/config.json` once the app lives
there. That is not just a failed save: `looksLikeLibrary` tests for exactly that file, so **the next
launch would adopt `/Applications` as the library** and the operator's real folder would never be
looked at again. An empty second library that the app *prefers* is strictly worse than no library.

`Store.saveNow`, `Store.scheduleSave`, `LogStore.save` and `Snapshot.write` therefore all refuse
while `!AppPaths.hasRoot`, and the resolver refuses to guess or to create anything.

Verified end to end rather than argued — on the **second** attempt, and the first one is the part
worth keeping:

> **`HOME` does not isolate this, and a test that thinks it does proves nothing.**
> `InstallLocation.file` goes through
> `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, which reads the
> user record, **not** `$HOME`. A first run with `HOME` pointed at an empty directory therefore
> still found the real breadcrumb, resolved `.breadcrumb`, and was never in the `.none` state the
> test claimed to be exercising — it wrote nothing for an entirely different reason. The isolation
> that works is `CFFIXED_USER_HOME`, which CoreFoundation does honour. Same family as §7a3's
> cross-check that compared two slightly different things: the run was green and measured nothing.

With `CFFIXED_USER_HOME` set, `--whereami` reports `source: none` and `data: — ยังไม่ได้เลือก`,
and the app run in that state for seven seconds with its window up wrote **no `config.json`, no
`log.json`, no `backups/snapshots`** into the folder holding the bundle, and did not touch the
fixture library it was not pointed at.

What the operator sees instead is a non-dismissible amber strip — `NewsBanner`'s `.noLibrary`, ahead
of every other item — with both verbs on it. It has to explain itself, because an empty song list is
§8c's "the app can't find my songs", which was reported from real use when the cause was merely a
remembered playlist.

### Opening vs creating are separate verbs

`AppPaths.setRoot` only accepts a folder that already looks like a library; `AppPaths.createLibrary`
is the only thing that may make one, and it creates **`songs/` only**. An "open" that quietly
creates `songs/` wherever you pointed it is how an empty second library appears and a day of markers
looks lost. `se/` and `brand/` are not created: they are the production's own files (§6e, §15's
`SEED[]`), and this build may not be carrying them at all.

### Switching at runtime (`AppModel.switchDataRoot`)

Four things in it, three of them about not damaging the library you are *leaving*:

- **Refused while playing.** It tears down the song list and reloads the store; §10 is the reason.
- **The old store is flushed FIRST, to the old root.** The save is debounced 250 ms, so a marker
  edited a moment ago is still pending — after `setRoot` it would land in the *new* folder, writing
  one library's markers into another. Same debounce §12 records losing an edit at quit.
  (`LogStore.append` writes immediately and re-reads first, so it has nothing pending. Do not add a
  flush there that does not exist.)
- **Guesses are cancelled.** An in-flight `AutoDetect` finishes with a main-actor hop that writes by
  *path*, and a path means a different song once the root moves (§7a4).
- **Every per-path cache is dropped.** `analysisCache` and `coverCache` key on the path under
  `songs/`, which is **not unique across libraries** — `EP01/101.mp3` exists in both — so keeping
  them would draw one library's waveform for another's audio. §8f records the same defect from the
  cover cache dropping the file extension.

It also takes a §5c snapshot of the library it moved *into*: otherwise the only pre-run copy the
session holds is of the library it left, and §5c's promise is "the state before this run touched
anything" — which, right after a switch, is still true of the new one.

`rescan(force:)` exists for this and nothing else. The two guards in `rescan` — bail when the list is
unchanged, keep the old list when the scan comes back empty — are right for a routine rescan (§12)
and wrong after a switch, where the new library legitimately holds different songs or none.

### Verify

```bash
INTROPLAYER_DIAG=1 $BIN --roottest   # 27 assertions, read-only, temp fixtures only
$BIN --whereami                      # NOT gated: program folder, data folder, and WHICH
                                     # fallback answered. The second question of every support
                                     # call, now that those are two places.
```

It never reads or writes the stored root or the breadcrumb — `resolveRoot` takes its three inputs as
parameters for exactly that reason. A diagnostic that had to write the real "chosen folder" key in
order to test it would be the one flag capable of pointing the app at the wrong library.

> `hasLibraryMarkers` is split out from `looksLikeLibrary` so the test can build fixtures in the
> system temp dir — which `isTransient` rejects by design — and still check the marks. There is no
> flag that turns an exclusion off. Negative control: deleting the exclusion `guard` fails exactly
> the two assertions that are about it (23/25), which is how you know they are not decorative.

---

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

A full SwiftUI/AppKit port of the GM app. **It is the way the tool is run.**

> **Superseded: the web version is no longer a shipped fallback.** It is kept in the repo, still
> reads and writes the same `config.json` / `log.json`, and `server.py --root <folder>` makes it
> work from anywhere — but it is not in the bundle, not seeded, and not something a crew machine
> has. The owner's call, in one line: *"เวอร์ชั่นเว็บสำรองไม่จำเป็นก็ได้นะ ทำให้ Mac OS Active App
> Stable มากมายก็พอ"*. Effort spent making the native app solid beats a second half-maintained
> implementation of it, and §8g had already stopped the web version from being able to EDIT the
> fields the native app owns, for the same reason.
>
> What that costs, said plainly: there is no longer a mid-taping fallback if the native app
> becomes unusable on set. The recovery is the native app itself — which is why §5d's launch
> snapshot, the `.none` guard and `--whereami` matter more than they would have otherwise.

```
native/
├── Package.swift                  # SwiftPM executable, macOS 13 target, no .xcodeproj on purpose
├── build.sh                       # builds + assembles "RGF Intro Player.app"
│                                  #   --with-payload bundles se/ + brand/ as first-run seed (§5d)
├── dmg.sh                         # the drag-to-Applications disk image (§15)
├── swap-app.sh                    # replaces an installed bundle, in-app updates (§15)
├── swap-test.sh                   # 29 assertions against it, production script unmodified
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
    │                      (note + tags have no file of their own — Store/CenterView/SetupPanel, §8g)
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
INTROPLAYER_DIAG=1 $BIN --loudtest     # BS.1770 coeffs, on-air spread, headroom, REVEAL level
INTROPLAYER_DIAG=1 $BIN --autodetect   # guessed Intro End / Hook vs configured, with evidence
INTROPLAYER_DIAG=1 $BIN --guesstest    # can the guess feature damage anything? (read-only)
INTROPLAYER_DIAG=1 $BIN --snapshot     # the launch backup: writes one, prunes, proves the dedup
INTROPLAYER_DIAG=1 $BIN --guessflow    # the admission rule, with a REAL playing player (§7a4)
INTROPLAYER_DIAG=1 $BIN --artwork      # where each cover comes from; never makes a request
INTROPLAYER_DIAG=1 $BIN --remodetest   # marker edits DURING playback must never outlive Intro End
INTROPLAYER_DIAG=1 $BIN --takes        # take model self-check, then the real log's running order
INTROPLAYER_DIAG=1 $BIN --timefmt      # typed-field parser: round-trip, accepts, rejects (read-only)
INTROPLAYER_DIAG=1 $BIN --overview     # overview strip: same data as columnPeaks, caches independent
INTROPLAYER_DIAG=1 $BIN --notetest     # the note: clamps, merge rule, measured layout, the ※ (§8g)
INTROPLAYER_DIAG=1 $BIN --tagtest      # tags: registry, UNION merge, the chosen colour, the box (§8g)
INTROPLAYER_DIAG=1 $BIN --filtertest   # tag filter + filename search narrow the LIST only (§8g)
INTROPLAYER_DIAG=1 $BIN --incomingtest # receive sweep, note/tag-only, declined rows: 50 (§8e)
INTROPLAYER_DIAG=1 $BIN --focustest    # คลิกที่อื่นแล้วต้องเลิกพิมพ์ — 8 assertions (§8g)
INTROPLAYER_DIAG=1 $BIN --logotest     # โลโก้: memo ค้างไว้ และ invalidate ได้จริง (§6e)
INTROPLAYER_DIAG=1 $BIN --foldtest     # พับคอลัมน์ + ความกว้างคอลัมน์/แผง: 55 ข้อ (§8c)
INTROPLAYER_DIAG=1 $BIN --roottest     # where the questions live: order, exclusions, .none (§5d)
INTROPLAYER_DIAG=1 $BIN --updatecheck  # semver compare, feed resolution, blocked URL schemes (§15)
INTROPLAYER_DIAG=1 $BIN --updatestage  # download + unpack + verify a real release, then delete (§15)
$BIN --version                         # NOT gated: writes nothing, and is the flag a support
                                       # call asks for
```

`--whereami` is **not** gated — it writes nothing, and "which folder is the app reading" is the
second question of every support call now that the program and the questions are two places (§5d).

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

### Why this is an `HStack` and not `NavigationSplitView` — and a custom header bar

A native-macOS design audit (the `macos-golden-gate-design` skill, from `github/awesome-copilot`)
finds exactly two structural divergences here. Both are deliberate, and the skill's own rule is
that a divergence has to carry its reason, so here it is. **Do not "modernise" either without
reading this.**

What the audit found that we PASS, because it is worth knowing the app is not guessing: zero
`.material`, zero `NSVisualEffectView`, zero `glassEffect` — nothing in this app is translucent,
so "hierarchy depends on blur or wallpaper colour" and "stops being coherent with Reduce
Transparency" are passed *by construction*. The panes are flat `Palette.panel` fills meeting at
1 pt `Rectangle` hairlines with **no rounded wrapper anywhere structural**: the largest corner
radius in the project is 10 pt and 65 of the ~97 `RoundedRectangle`s are radius 6 or 7, i.e.
buttons. The "structural card budget of zero" is met.

**`NavigationSplitView` is wrong for this app**, for reasons that are about the taping and not
about taste:

- ~~The left pane is a **fixed 900 pt**. A split view's divider is user-draggable by design —
  which adds a way to resize the waveform mid-take by brushing the mouse. §12's recurring defect
  is a control that moves under the cursor; a draggable structural divider is that defect
  promoted to a feature.~~ **Superseded: all three panes are draggable now** (§8c, `PaneLayout`),
  on request. The reasoning above was not wrong and is what the mitigations answer — a 4 pt
  `minimumDistance` so a brush is not a drag, hard floors so no pane can collapse, a deliberate
  8 pt handle with a visible grip. The rest of this section still holds: the panes are a plain
  `HStack`, not a split view, and the remaining bullets are why.
- The left pane is not a source list. It is **three independent `ScrollView`s side by side**
  (1xx / 2xx / 3xx, §8c) with their own keyboard navigation (`[` / `]`). `List(selection:)` is one
  list.
- The log **replaces** that pane rather than covering the app, which is what let §12 delete the
  `1`/`2`/`I`/`O`/`H` carve-outs. That swap is the thing `NavigationSplitView` is least willing to
  do cheaply.
- `.inspector` is macOS 14. We target **macOS 13** so the folder still runs on the older crew
  Macs, and the universal build exists for the same reason.

**The header bar stays custom**, because a native toolbar cannot be brick red with the
programme's logo in it, and that colour belongs to the production rather than to this program
(§6e). It is also not merely a title banner: it carries live state (`ยังต้องตรวจ n`,
`✎ แก้ที่กอง n จุด`) and the handover action. What the audit was right about is the part that
*was* duplication — see §12 for the app name appearing three times in two strips.

> The one thing in the audit this app genuinely has no answer to is its macOS 27 half: Liquid
> Glass, `backgroundExtensionEffect`, edge-reaching sidebars and concentric corners are all
> `macOS 26`/`27` API. At a macOS 13 target none of it compiles, and raising the target would
> strand the crew machines. So the *material* half of that skill is permanently out of scope
> here; the *structural* half is version-independent and is what was applied.

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

`--palettetest` measures both themes in Swift — 195 assertions over the ladder, text contrast,
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

### `audit` IS the colours now, not a copy of them (`Palette.named`)

For as long as both existed, `Palette.audit` was a hand-maintained hex table running parallel to
38 `dyn(...)` literals **with nothing tying the two together** — and `PaletteCheck` reads only
`audit`, `auditHex`, `tagSlots` and `tagSwatch`, never a real colour. So every assertion in
`--palettetest` measured the table while the app rendered the literals.

Measured rather than argued: setting `amber = dyn(0x2FD17A, 0x1F5534)` — amber byte-identical to
green, i.e. §6d's "the intro-end stop is not armed" rendered in the colour that means "a human
answered correctly", with the deutan separation gone — left the suite at **187 ผ่าน / 0 ตก with
byte-identical output.**

**Third occurrence of the `Palette.audit` lesson, and the first fix that removes the second copy
instead of adding a check over it.** The 38 were verified equal to their audit entries *before*
being rewritten to go through `Palette.named("x")`, so no colour changed. What stays outside it is
deliberate: `outline` / `onHeader` / `onHeaderWarn` must not flip with the theme, and the tag
ramps are arrays whose completeness the indexed loop already covers.

> A name not in `audit` now resolves to **screaming magenta**, not `0x808080`. A typo in one of
> those strings is the new structure's only failure mode, and grey is a value this palette could
> plausibly have wanted — which makes it the worst possible sentinel. Note the existing assertion
> spelled `0x808080` as a literal, so moving the sentinel would have made it pass *for free on
> exactly the colour that had gone missing*; it reads `Palette.missingColour` now.

**And the comment that sent `tagSwatch` to `audit` claimed an assertion that did not exist** —
"`--palettetest` already asserts `audit` names every value". What actually works is the *indexed*
loop over `tagFill\(i)`; the named scalars had no enumeration and therefore no coverage at all.

#### amber vs red collides in the LIGHT theme, at deutan ΔE 6.1

Found by running the negative control after the fix above: amber := green still passed 191/0,
because **section 5 compared amber against `accent` and `purple` only.** Adding green and red:

| | dark | light |
|---|---|---|
| amber vs green | 16.1 | 22.3 |
| amber vs red | 20.6 | **6.1** |

6.1 is the same colour to a deutan viewer. **Pinned, not fixed**, by the same reasoning §6d
applies to accent-vs-purple — separating it means moving a shipping status colour, and this
palette's light-theme lightness budget is already spent (a white ground forces every accent down
to roughly L\* 46, which is what flattens the spread).

Survivable for specific reasons rather than hopeful ones: light is the **setter's** theme at a
desk, so neither state is read under time pressure there; both carry a word, and §6d's rule is
that amber plus a word is the carrier and never the hue alone; and the save-failure bar is not
this red — it sits on `header`, dark in both themes with fixed-light text. **So amber and red may
never be the sole difference between two things in the light theme.** If that ever has to be
fixed rather than pinned, it is a decision about the show's colours, not a threshold to nudge.

> **Dark is the default and that is not a style preference.** The operator's position is a dim
> corner of a studio; a white 2560×1080 panel at arm's length is a light source pointed at the
> person who has to watch the stage. Light is for the setter at a desk. An unreadable `theme`
> value falls back to **dark**, not to the system, so a garbled settings file cannot put a white
> screen in front of the operator mid-taping.

## 6e. The programme's logo (`ShowLogo`, `brand/logo.png`)

A small logo drawn in the header bar before `RGF INTRO PLAYER`. Three decisions in it are
worth keeping.

**It lives beside the app, not inside the bundle.** `brand/` is in the installer's `SEED[]`
alongside `se/`, which means copied on a fresh install and **never overwritten by an update**.
That is the right category for the same reasons as the stings: the artwork belongs to the
production rather than to this program, it changes on the production's schedule, and this repo
is public. Baking it into `Resources/` would mean a rebuild and a release every time the
branding moves. `brand/README.txt` is tracked so the folder and its spec always exist;
`brand/*` is otherwise gitignored.

**The spec is set by the bar, not by taste.** `Palette.header` is brick red in BOTH themes
(`#C8402A` / `#BA2616`) and `onHeader` is fixed white — so the logo must be a light or white
knockout. A dark logo is invisible there, and no theme setting will rescue it. It draws at
**22 pt tall**, which fits inside the header's existing line box: a taller bar takes its height
from `CenterView`, whose only flexible child has a hard `minHeight: 160` floor, so the overflow
clips the song title off the top and ✓/✗ off the bottom (§15's news-strip note). Width is
clamped at 90 pt and the exact draw size comes from the image's own aspect ratio, so a narrow
logo does not reserve 90 pt it will not use.

**Transparent margins are cropped on load.** A designer's export is almost always padded, and
that padding is not decoration here — it is height. The real logo arrived as a 1024x1024 PNG
whose artwork occupies **1024x508**: half the canvas is empty. Drawn as-is inside the 22 pt box
that gives a logo **10.9 pt tall** next to 15 pt text, in a 22 pt square that wastes the 90 pt
of width it was allowed. Trimmed, the same file is 2.02:1 and draws **44 x 22** — full height,
right proportion, and nobody has to re-export anything. The alpha test is `> 8`, not `> 0`: a
PNG out of a vector tool carries an antialiased fringe of near-zero alpha, and testing for
nonzero finds "artwork" in it and trims nothing. A fully transparent file returns nil rather
than reserving 22 pt for nothing. Measured at 7.2 ms for 1024x1024, once per process.

> **Do not assume the logo needs a white knockout.** Rendered against the real `#BA2616` at
> the real 44x22, the show's full-colour logo reads *better* than an automatic knockout of it
> — because its structure comes from heavy black outlines, not from its alpha, so flattening
> every opaque pixel to white produced one solid white blob with no internal detail at all.
> Knockout is right for a mark whose shape IS its alpha; it is wrong for anything outlined.
> Render it on the actual colour at the actual size before deciding — that comparison took one
> throwaway script and settled a question two people had been reasoning about.

**A big reduction must average areas, not sample points.** Reported from use as "ภาพมันเละ".
The logo is 1024x508 drawn at 44x22 on a **1x** panel (§6d), so one output pixel covers
**23 x 23 = 529** source ones. `CGContext`'s `.high` samples a handful of those, and on artwork
carrying a halftone dot pattern the dots alias into mush. Measured on the real file at 44x22,
zoomed back 7x to inspect the pixels that actually reach the screen:

| method | result |
|---|---|
| `CGContext` `.high`, one step (what shipped) | aliased, the upper text line breaks up — 0.7 ms |
| successive halving | clean but soft — 1.6 ms |
| Core Image Lanczos | **ringing**: purple specks inside the yellow — **82 ms** |
| **exact area average** | **sharpest and cleanest — 1.3 ms** |

So: box average, in **premultiplied** space (a transparent pixel must contribute transparency,
not its undefined colour), and **only for reductions of 2x or more on both axes** — below that
each output pixel claims one source pixel, which is nearest-neighbour and worse than the
bilinear it replaced. Lanczos is the textbook "high quality" answer and was the worst of the
four here; this is a case where reaching for the sophisticated filter is the mistake.

It also resamples **once at load, to the exact pixel count the logo will occupy**
(`points x NSScreen.backingScaleFactor`), instead of handing SwiftUI a 1024 px bitmap and a
44 pt frame to rescale on every draw. `prepared` therefore carries the image and its point size
together — they cannot be resolved separately without the 1:1 guarantee breaking.

**Loaded once per process**, memoised **including the memo for "looked, and it is not there"**.
`ContentView` is re-initialised on every model publish (§6c) and the header re-renders at the
player's tick rate, so reading the disk from `body` would `stat` 50 times a second — §8f's
memoised-cover lesson. Dimensions are read from the file header *before* decoding and anything
over 4096 px a side is refused; a missing, empty or corrupt file draws nothing and raises
nothing.

> **It was a `static let`, which made the memo permanent, and that was a bug on a machine with
> no library yet.** `Seeding.run` is guarded on `AppPaths.hasRoot`, so on a FIRST run it copies
> nothing; the header then draws and memoises nil; the operator picks a folder, `switchDataRoot`
> seeds the logo in — and nothing re-read it, so **the logo did not appear until the app was
> relaunched**. Reported from the first install on a second machine. `ShowLogo.invalidate()` is
> called from **`Seeding.run` itself**, when and only when it actually placed a file, so a third
> caller cannot forget it — the same reason `markTakenIn` lives in `Handoff.apply` (§8e). The
> blast radius was exactly the first launch on a new crew machine, which is where branding
> matters most. `--logotest` is the cover; swapping the file by hand still needs a relaunch,
> which `brand/README.txt` says.

**The wordmark is drawn beside it, always** — `{logo} RGF INTRO PLAYER`, on request, in their own
`HStack(spacing: 10)` so the pair reads as one lockup against the bar's 14 pt. §12's design audit
had made the words conditional on there being NO logo, and that reasoning was not wrong, it just
did not bind: at `App.swift`'s declared `minWidth: 1100`, with both header chips up, both buttons,
the save state and the logo at its full 90 pt cap, the bar needs **792 pt — 308 pt spare** (the
real 44 pt logo leaves 354). The words cost 156 pt of that. Measured through `Typo`'s own cascade
rather than estimated, because the audit's "~170 pt" was the whole case for removing them. The
titlebar still carries the name too, and the duplication is the owner's call.

> It replaced a hardcoded 9 pt **green** dot with no state behind it — decoration, and a live
> §6d violation, since green in this app means "a human answered correctly" and nothing else.
> It was not even a `Palette` value.

Two things the release path needed and did not have. `release.sh` stripped the payload with a
hardcoded `rm -f "$STAGE/se/correct.mp3" "$STAGE/se/wrong.mp3"`, so the day `brand` joined
`SEED[]` the show's logo went into a public GitHub release — measured, the zip went from 2.4 MB
to 3.9 MB and every check passed. It is a `SEED_PAYLOAD[]` list now, with the zip assertion
driven by the same list. And `installer-test.sh` only ever proved the promise for
`se/correct.mp3`: adding a seed left "an update never overwrites this" untested for the new
one, at 123/123 green. Both are the same shape as the SHIP[]-vs-PROGRAM[] cross-check — **a
rule that names its subjects literally stops covering the subject that arrives later.**

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

### a5) Reveal is levelled on its own window (`Analysis.revealLufs`)

The auto-gain measures the **intro** (§7a2) and that is still right — but the figure was then
applied to everything the node plays, and **Reveal plays the hook**. A pop master puts its
loudest fifteen seconds in the chorus, so every song whose sparse intro earned a boost sent that
boost out on camera.

Measured on the real nine songs, before and after:

| | spread | sd |
|---|---|---|
| the songs' hooks, untouched | 9.93 LU (**3.53** for 8 of the 9) | 2.82 |
| hooks under the intro's gain — **what shipped** | **15.21 LU** | **5.02** |
| hooks under their own gain | **0.00 LU** | 0.00 |

So the feature was taking material the mastering engineers had **already levelled** and making
the one moment that goes on camera *less* even than doing nothing at all. The worst case is the
whole bug in one line: song 107's intro measures −35.9 LUFS and earns +12 dB, its hook measures
−11.1, so Reveal went out at **+0.86 LUFS — 15.9 LU over target — with the limiter clawing back
10.78 dB.** The reveal was simultaneously the loudest thing in the show and the most crushed.

Three things about the fix are load-bearing:

- **Only Reveal gets its own figure.** `Player.levelDb(for:)` is keyed on the mode, and `.free`
  deliberately keeps the intro's level. A seek can land anywhere, so re-deriving the level from
  wherever the playhead stopped would change loudness under the operator's hand on **every
  waveform click** — constant during marker work, and with no cut to hide it. Reveal is one jump
  to one fixed place, so the level change is masked by the jump it already makes.
- **The headroom check uses the hook's window too.** §7a3 records what it cost when the peak
  followed the measurement scope instead of what is played; `Analysis.revealRange` exists so the
  level and the peak cannot drift onto different windows.
- **`scope: song` is honoured.** That setting means "one number for this file", so `revealLufs`
  returns the whole-file figure and there is nothing to re-level. With normalize **off** both
  figures collapse to the trim, so Reveal behaves exactly as it did.

`Analysis.revealTargetLufs` is deliberately **equal to `targetLufs`**, and is its own constant
because "should the payoff be a few dB hotter than the question?" is a production decision, and
that is the one number which answers it. Trim applies to both stretches — it is a human decision
about the song, not about a stretch of it.

> **The fix moves the show's reveal level down.** The old behaviour averaged roughly −10 LUFS
> across the reveals; they now land on −15, same as the intro. That is the point — the old
> number was not a choice, it was the intro's gain leaking — but it is a 5 dB change to what
> the room hears at the reveal, so it is a thing to listen to before a taping, not just a
> green test.

**Why nothing caught it.** All three places that should have were scoped to the intro:
`--loudtest` measured only the intro range, the level card showed one number, and the
pre-flight's `squashedIntro` looks only at the intro. `--loudtest` sections 6 and 7 are the
cover now — 6 asserts every reveal lands on target with no claw-back, 7 asserts that turning
normalize off collapses both figures to the trim.

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
- Sized for the 2560×1080 ultrawide this runs on: list **900px** (780 until it was reported as
  too narrow) still leaves ~1320px for the
  waveform. A `max-width:1500px` media query falls back to the original single column with the
  group headers stacked inline, so a narrower window still works.
- Titles are clamped to 2 lines with the full name in a `title` tooltip — uniform row heights
  matter more than complete titles when scanning during a take.

### Folding a column (`AppModel.collapsedCols`, `ColumnFold.decide`) — native only

The three columns are `.frame(maxWidth: .infinity)` in an `HStack`, i.e. fixed thirds — 299 pt
each of the 898 the pane has after its two dividers. Measured on the real round, which is
**7 / 1 / 1**: two thirds of the pane renders two songs while seven share the other third. A
folded column becomes a 36 pt rail and `1xx` gets **812 pt against 294.7**, which is what decides
whether two 2-line clamped Thai titles still tell two songs apart. Folding one gives the other two
424 pt each.

> A fully prepared taping is presumably nearer 7/7/7 and the gain shrinks. This is worth most on
> a round that is half-prepared or uses one group.

Six things, each for a reason that is invisible in a screenshot:

- **The fold control is a small glyph at the header's trailing edge, NOT the header strip.** The
  header sits directly above row 1 and `select()` has **no playing guard** — it calls
  `player.load(url:)` at once — so a whole-strip toggle would put "reflow every row sideways" one
  slip above "cut the audio on camera". §12 records that class four times. `‹` measures 5.48 pt at
  12 pt bold and resolves to `.SFNS-Bold`, not LastResort (§12's glyph lesson: the honest test is
  which FONT the run lands in, because LastResort has a glyph for every codepoint).
- **The folded rail is ENTIRELY the unfold button**, which is safe exactly where the header is
  not: a folded column holds no song rows, so a click in it can only mean one thing.
- **Folded, not hidden.** The rail still reads `1xx` and `(7)`. §8g measured a view state that
  hides questions as §8c's "the app can't find my songs", reported from real use once already.
- **It dies with the process. No `_settings` key** — `tagFilter`'s and `search`'s measured reason.
  Cleared by `setPlaylist` too: a `2xx` that was empty and folded in the round you are leaving may
  be the fullest column in the one you are entering.
- **It is a width, not a filter.** Nothing in it touches `songsIn(_:)`, so the handover, the
  pre-flight and the `Return`/`Tab` review sweep are untouched. Implementing a fold by dropping
  rows from the list is the one way this becomes a defect instead of a layout.
- **Two states are refused rather than left to the UI**: the column holding the selection may not
  fold (§8g — one guard at the choke point, with `select` unfolding from the other direction, next
  to the tag-filter and search guards that are there for the same reason), and the last expanded
  column may not fold. Unfolding is never refused: it can only reveal.

`ColumnFold.decide` is pure, which is the house pattern for a decision no headless test can drive
— `MarkerGrab.decide` (§11) and `FocusRelease.shouldRelease` (§8g). `--foldtest` proves the table
and its negative control, deleting the selection guard, fails exactly the three assertions that
are about it. What no check here can establish is that the UI calls it; see §13.

### The window opened too narrow for its own layout

**`isWide` needs 1900 pt and `defaultSize` was 1600, so the app opened in the NARROW one-scroller
layout even on the production 2560x1080 panel.** 900 pt of song list + 340 of SETUP + the ~660 the
centre pane needs for its waveform floor is 1900; at 1600 the left pane is 300 and the three
columns §8c treats as the primary design — sized at 900 on request — were not what the operator
saw unless they happened to widen the window.

Reported as *"ลากปรับขนาดแต่ละ COLUMN ไม่ได้"* and *"Collapse Expand Group ไม่ทำงาน"*, because
both controls exist only in the wide layout: from inside the narrow one the whole feature looked
absent. The screen was measured at 2518x1050 usable, i.e. the wide layout was always reachable —
nothing was broken except the default.

Three things came out of it, and the first is the general lesson:

- **A layout breakpoint above the default window size means the default experience is the
  fallback.** Nothing in the app said which layout was in force, and no diagnostic could — this
  is reachable only by looking at a running window.
- `defaultSize` is **2000x1000**. macOS fits a default down to the screen, so a laptop that cannot
  reach 1900 gets its own width and the narrow layout. It applies only to a window with no saved
  frame, so it fixes fresh installs rather than a machine that has already stored 1600.
- **The narrow layout can fold a group too**, which it could not before. Same `collapsedCols`,
  rendered the other way round: a folded group hides its rows instead of narrowing to a rail. One
  state, two layouts, so both refusals in `ColumnFold.decide` and `select`'s unfold apply in both
  without being written twice. §6c keeps the macOS 13 target so older crew Macs still run this,
  and some of those are laptops that can never reach 1900 — the narrow layout is not a fallback to
  be left half-built.

> Superseded by the pane-resize section above: there is no breakpoint left to lower. Each pane
> sizes itself and decides its own internal layout from its own width.

### Dragging the three PANE edges (`PaneLayout`, `PaneEdge`)

Asked for as *"ที่ผมอยากให้ขยับปรับขนาดได้คือ 3 column นี้ |LIST เพลง| ส่วนกลาง | Right Tab"*,
with *"เครื่องส่วนใหญ่จะเป็นหน้าจอแคบ"*.

> **Read this before the two column sections below.** "Three columns" in that request means the
> three **panes**, not the 1xx/2xx/3xx columns inside the song list. The fold and the in-list edge
> drag were built on the other reading first; they are useful and they stayed, but this is the one
> that was asked for.

**It supersedes §6c's refusal, which was explicit.** §6c rejected a draggable structural divider
because it "adds a way to resize the waveform mid-take by brushing the mouse". That is a real
risk, so it is carried rather than waved away:

- **A brush is not a drag.** `DragGesture(minimumDistance: 4)` on the pane handles — double the
  2 pt the in-list column edges use, because this is the divider §6c was afraid of.
- **Nothing can collapse.** `PaneLayout.floors` is `[240, 480, 300]`, applied before any fraction
  is honoured. Measured: a list row's 2-line clamped title with its tag chips and note line needs
  240; §12 records a 378 pt centre pane as broken, so the floor sits above it at 480; the SETUP
  marker cards need 300. They sum to 1020, and with the two 8 pt handles that is 1036 against
  `App.swift`'s declared `minWidth: 1100`.
- **The handle is a deliberate 8 pt target with a visible grip**, so a drag is something you aim
  at rather than something that happens to you.
- **Nothing about audio depends on it.** A pane width changes the waveform's drawn width, which
  `Analysis.columnPeaks` re-derives from the view window; the playhead is time-based.
- **Double-click resets.**

> The transport row needs **834 pt** not to wrap — four fixed buttons at 200/210/190/150, 36 pt of
> spacing, 48 of pane padding. The current wide layout never gave it that either (660 at the old
> breakpoint), because wrapping is the designed behaviour: a `FlowRow`, "wraps instead of
> compressing, because a squeezed button renders its label as vertical text". So the 480 pt floor
> protects the waveform, not the row.

**`isWide` is gone, and that is the structural half of this change.** It was one window-wide step
function — ≥1900 → a 900 pt list, else 300 — driving the list's internal layout, the log pane's
width and its stat tiles, and the waveform legend. Every one of those now reads **its own pane's**
width: `listShowsColumns` (list ≥ 700), `centreIsWide` (centre ≥ 700). That is what makes dragging
work rather than merely resize things — on a screen that could never reach a 1900 pt window, the
operator can now drag the list to 700 and get the three columns.

`AppModel.listWidth` is still the **one** number the song list and the log pane share; it is a
computed property now instead of a function. §12 records 120 pt of divergence between those two
when they were separate literals, and that rule has not changed.

**The split persists** (`_settings.paneSplit`), unlike the fold and the filters: with floors in
force it cannot hide a pane, let alone a question, so §8g's die-with-the-process rule does not
bite — and *most machines are narrow screens*, so every machine wants its own proportions. It is
closer to `theme` than to `tagFilter`. Stored as fractions of the surplus, clamped through
`PaneLayout.normalised` on read, so a hand-edited or foreign-written file cannot produce a pane of
zero width.

**The default is a compromise and says so.** `defaultFractions` gives **392 / 699 / 334** at a
1440 pt window and **564 / 948 / 372** at 1900 — deliberately NOT the 900 pt list §8c asks for on
a wide screen, because one fraction set cannot be both and the step function it replaces could.
The 900 is one drag away and it sticks.

`--foldtest` section 6 covers it: widths at 1100/1440/1900/2518, the floors against **literals**,
and the drag round trip at ±120 and ±900 pt.

> **The first version of those assertions could not fail.** They compared each width against
> `PaneLayout.floors` — the constant they were meant to be testing — so setting the floors to
> zero moved the goalposts and the suite stayed green at 52/52 while the centre pane went to
> **0 pt**. Found by running the negative control. It is the `Palette.audit` lesson in a third
> costume, and the fix is the same one: pin the real numbers as literals.

### Dragging a column edge inside the list (`ColumnLayout`, `ColumnEdge`)

Asked for as *"อยากให้แบบลากตรงขอบเพื่อปรับขยายได้"*.

**§6c's refusal of a draggable divider is about a DIFFERENT divider, and that distinction is the
whole licence for this.** §6c rejects `NavigationSplitView` partly because its divider would let
the operator resize the *waveform* by brushing the mouse mid-take, and §12's recurring defect is a
control that moves under the cursor. `ColumnEdge` lives *inside* the left pane, which stays a
fixed `AppModel.leftPaneWidth`: dragging one moves the boundary between two columns of song rows,
and the centre pane — waveform, markers, transport, ✓/✗ — cannot move at all. Do not read §6c as
forbidding this, and do not read this as permission to make the PANE boundary draggable.

- **A press that moves nothing changes nothing**, which is §11's marker-grab rule.
  `DragGesture(minimumDistance: 2)` is what delivers it: a click on the edge is not a 0 pt drag,
  it never starts. The handle is its own 8 pt view sitting ON the 1 pt divider, so it cannot
  swallow a click meant for a song row — the rows end where it begins.
- **Double-click resets to equal thirds**, the only reset that needs no memory of the previous
  widths.
- **The cursor push/pop is balanced by a flag**, not by trusting the two `onHover` callbacks to
  pair up. An unmatched `push` leaves the resize cursor over the whole app; an unmatched `pop`
  takes somebody else's off the stack. `onDisappear` pops too, because the log pane unmounts this
  list (§12).
- **Dies with the process**, like the fold. The reason is weaker here and goes the same way: a
  resized column still shows every one of its songs, so unlike `collapsedCols` it cannot hide
  work — `ColumnLayout.minWidth` (140 pt) is what guarantees that. Persisting it is one
  `_settings` key if that turns out to be wanted.
- **It shows a grip at rest.** The first version's only affordance was the cursor changing on
  hover, which nobody discovers by not hovering, and the feature was reported as not working.
  Three 10 pt `dim` segments down the middle, drawn only where the edge is live so a dead
  boundary does not advertise a gesture that cannot happen. §12's `P`-had-no-shortcut lesson:
  **a control nobody can find is indistinguishable from one that is broken**, and the same
  correction applied to the fold button, which was a bare 5.48 pt grey `‹` with no background and
  now reads as a button.
- **The edge is 8 pt wide itself**, with the hairline down its middle, rather than an 8 pt
  overlay on a 1 pt parent — which would depend on hit-testing reaching outside the parent's
  bounds. `AppModel.columnWidths` takes both edges off the pane first, so the columns know they
  are there: 900 − 16 = 884 to divide.
- **A handle exists only between two EXPANDED neighbours.** With the middle column folded the two
  expanded ones are not adjacent, so there is no handle — a handle whose two sides are not the
  things it sits between is worse than none.

**The arithmetic is in surplus space, and the first version got it wrong in a way that looks
right.** `widths` gives each expanded column `minWidth + surplus × f`, so the floor is a constant
offset and **a fraction is not proportional to a width**. Converting a drag back by "share of the
pair's width" put a +50 pt drag at 325.9 pt instead of 349.3 — an error that grows with `minWidth`
and would have shipped as "the divider does not keep up with the mouse". `f = (w − minWidth) /
surplus` inverts it exactly, and the pair's combined `f` is preserved by construction, so every
other column's width is untouched. `--foldtest` section 5 asserts the round trip at ±50 and ±400
pt, including that the third column does not move and that the three still sum to the pane.

> The floors are applied *first*, with only the surplus distributed by fraction. Scaling first and
> clamping after lets three clamped columns sum past the pane, which in an `HStack` of fixed
> frames overflows silently and clips the third column's rows.

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

`round.json` also carries `tagColors` — which colour the sender chose for each tag the round
uses (§8g). Merged silently and additively, with no `DiffRow`, because it changes nothing that
goes to air.

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

### Spotting a round that has arrived (`detectIncoming` / `Handoff.waitingRounds`)

A folder copied in while the app is open has to announce itself, so the app looks for a
`round.json` nobody has taken in yet — on launch and on window activation.

**It sweeps every round, and that is the whole point.** It used to read `currentPlaylist` alone,
which is right for one setter and loses two thirds of the work for three: drop `EP01/`, `EP02/`
and `EP03/` in and only the selected round raised a strip, while the other two sat unimported
with nothing anywhere saying they were waiting. Measured as a number by `--incomingtest`, because
the counterfactual is the thing worth writing down: **เห็น 1 จาก 3 — หาย 2 ชุด.**

`Handoff.waitingRounds` is a pure function with `read` and `songsIn` injected, for one reason:
the defect was never in the per-round decision, it was in **how many rounds the caller asked
about** — so a test of the decision alone would have passed before and after. The diagnostic
drives the real loop. `compactMap`, so there is no shape in which it stops at the first hit.

**A package already signed off here is NOT waiting, however much it now differs**
(`Handoff.alreadyTakenIn`). Export and import both stamp `base` from the result, and `plan`
compares incoming-vs-local — so a round the setter sent and then kept editing, and a round the
operator imported and then changed on set, both produce rows. The diff sheet pre-accepts every
row, so pressing the obvious button would have **reverted the on-site edits to the snapshot they
were derived from**, which is the one thing the "แก้ที่กอง" badges exist to protect. The test is
therefore `base == the package's values for every song in it`, not "do the values differ". It
mattered little while only the selected round was checked; sweeping every round turns it into a
strip that reappears from anywhere, and §12 is explicit that a warning which fires when nothing
is wrong is one that gets ignored on the day it matters.

Three more things in it are load-bearing:

- **One strip, not one per round.** `ReceiveBanner` shows the round on screen if it is waiting,
  with `· อีก n ชุดรออยู่` folded in; otherwise it shows the others and a way to reach them.
  The rule `NewsBanner` follows, for the measured reason in §15: two banners plus
  `saveFailureBar` is already more height than `App.swift`'s declared `minHeight: 640` has, and
  past `CenterView`'s waveform floor the overflow clips the song title off the top and ✓/✗ off
  the bottom.
- **The durable half is the 📥 in the playlist picker.** The strip can be waved off; the mark
  cannot, so "which folders are still waiting" survives a dismissal and a relaunch. Same shape as
  §15 keeping the version number cyan after the update strip is dismissed.
- **"ไว้ก่อน" is per package**, keyed on folder **plus** the export time. One flag would be the
  same defect as one `incoming` — waving off EP01 must not hide EP02 — and including `at` means a
  round the sender **re-exports** raises the strip again instead of staying hidden behind a
  wave-off of the older file. Nothing about it is persisted; it dies with the process.

The strip also names the **folder**, not `package.round`, and says so when they differ. Filing a
round under another folder name is legal by design — `round.json` is keyed by file name for
exactly that — so `package.round` is where it came FROM while the folder is where accepting it
lands. `ImportPlan.round` carries the same value, so `applyImport` cannot clear the wrong round.

### "Has a human dealt with this?" is not a comparison (`Store.takenIn`, `Handoff.reviewKey`)

`alreadyTakenIn` asks **"does `base` equal the package's values"**, and for two years that was
treated as the same question as "has this been reviewed". It is not, and the gap cost the
feature its two most important cases. Both were found by a review pass and then confirmed by
reading the code, not by running anything — neither had a test.

| | what happened | why no comparison can see it |
|---|---|---|
| a handover carrying only a **note** or a **tag** | matched on every song, `alreadyTakenIn` answered "already taken in", **no strip and no 📥** — the operator never saw the field §8g exists for, while the setter watched `round.json` land and assumed it had arrived | `base` is a `SongBase`: the five marker fields. `note` and `tags` are not in it (§9) and never will be |
| **declining** a row | the strip came back on every launch and activation, and the sheet pre-accepts every row — so the obvious button accepted the thing that had just been turned down | `apply` stamps `base` from the RESULT, correctly (§8e: stamp it from the sender and "แก้ที่กอง" means nothing). So local and `base` agree while both differ from the sender — identical to an untouched round |

§8e derives everything it can, on purpose, because a stored flag goes stale. **This is the one
piece of handover state that is genuinely not derivable**, so it is stored — in `_settings`,
beside `resetAt` and `dismissedUpdate`, which are the same species of "a human already dealt
with this".

**The key is `Handoff.reviewKey`, not `IncomingRound.id`.** The id is folder + `at`, which is
right for the "ไว้ก่อน" dismissal — §8e wants a re-export to reappear even when nothing changed,
because a wave-off is "not now" rather than a decision. A review *is* a decision, so it is keyed
on what was decided about: folder + `at` + an FNV-1a fingerprint of the content. With `at` alone
a `round.json` hand-edited while keeping its timestamp would have been swallowed as
already-reviewed, which is strictly worse than the bug being fixed.

> `Store.fnv1a` is now one function with two callers — the tag-colour slot and this. **Never
> `hashValue`**: Swift seeds it per process, which §8g already records as the defect that made
> `tagsInUse` pick a tag's surviving spelling at random between launches. The refactor is pinned
> by `--tagtest` staying at 89, the same way `clampName`/`clampNote` are pinned by `--notetest`
> staying at 66.

Two more pieces, each for a reason that is invisible in a screenshot:

- **`DiffField.isAdditive`.** The first fix was a `takenIn` check alone, and `--incomingtest`
  **caught that it was incomplete** — `isWaiting` still ended on `return !alreadyTakenIn(...)`,
  so a note-only package was vetoed on the strength of the markers agreeing. An additive row is
  *unambiguous*: `plan` raises one only when the sender has something this machine does not, so
  unlike a marker row it can never be our own on-site edit looking back at us. It is therefore
  checked BEFORE `alreadyTakenIn` gets a vote. Deliberately a separate property from `isProse`,
  which happens to name the same two cases today: one is about how a row is laid out, the other
  about whether it may be ignored, and a field that is additive but fits in a value column would
  have to split them.
- **`Handoff.packagesOnDisk`, and it lives in `Handoff`.** The prune set for `takenIn` has to be
  *every* package on disk, because a reviewed package is by definition not waiting — pruning
  against the waiting set deletes every record on the first sweep and puts the feature back where
  it started. `--incomingtest` section 12 measures that counterfactual (`เหลือ 0 จาก 2`). It is
  not a second loop in `AppModel` for the reason §8e already gives: the defect the sweep replaced
  was never the per-round decision, it was **how many rounds the caller asked about**, so a loop
  written in the UI layer is exactly the shape that regressed. `waitingRounds` is now a filter
  over `packagesOnDisk`, so there is one implementation.

`markTakenIn` is called from **`Handoff.apply`**, not from `AppModel`'s two import paths. That is
the choke point both already go through, so a third caller cannot forget it — and it is what lets
`--incomingtest`, which drives `apply` directly, see the behaviour at all. The first version put
it in `applyImport` and the test could not reach it.

### Who sent it (`_settings.setterName` → `round.json`'s `by`)

`by` is the only field saying whose round this is, and it used to be typed into a sheet that
forgets — a `@Published` on `AppModel` with nothing behind it — so in practice every handover
arrived reading **"ไม่ระบุชื่อ"** on both screens that show it. Invisible with one setter; with
three machines preparing three rounds it is the first thing the person merging them needs.

- **In `_settings`, never per round.** It describes the person at this keyboard, not the work.
- **Committed on Return and again inside `doExport`**, not on every keystroke: `clampName`
  trims, so a write-through binding would eat the space the moment you typed it and a name with
  one in it would be untypeable. (§11's commit-on-Return rule for the marker fields is about
  undo snapshots and clamps dragging the other marker — neither applies here. Same shape,
  different reason; don't merge the two arguments.)
- **Clamped on read AND on write**, ≤40 grapheme clusters, one line, NFC —
  `RoundPackage.read`'s `by` was unbounded, and it lands in a one-line strip on a machine that
  did not write it. §15's rule for `notes` and `download`, in the file that actually crosses
  machines.
- **`switchDataRoot` reseeds the buffer**, or the folder you just left would stamp its name into
  the next handover of the one you moved into. Same family as every per-path cache it drops.

`Store.clampName` and `Store.clampNote` are the same `oneLine(_:max:)` — the refactor is pinned
by `--notetest` staying at 66.

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

## 8g. The setter's note, and tags (`note` / `tags`)

Asked for as "a function to create tags and assign tags to each song". Built with the centre of
gravity moved, and the reason is one sentence of the owner's: the tags are *"เหมือนเป็น note
สำหรับคนเปิดโจทย์ เช่น โจทย์นี้ ฝั่งนี้น่าจะได้เปรียบ ใครน่ารู้"* — a note for the person opening the question.

### Why both, and why the note is the primary field

Those examples are two different species:

| the owner's words | species | the right tool |
|---|---|---|
| "ฝั่งนี้น่าจะได้เปรียบ" | a sentence, used once | **`note`** |
| "ใครน่ารู้" → `ยุค 90` · `คนรุ่น 40+` | a short fact, repeats across songs | **`tags`** |

> **Building only tags and handing them this job produces something worse than either.** A
> registry full of one-off sentences, autocomplete that never matches, chips wrapping four
> lines, and a filter with nothing to filter on. That is not a mistake somebody has to make —
> it is what the feature turns into on its own if the prose has nowhere else to go.

### Where they are read, and the measurement that decides it

**Read in `CenterView`'s title row. Written in SETUP.** The split is not tidiness.

The read placement costs **zero height**, which is the only reason a free-text field is allowed
anywhere near the centre pane. That row is already 52 pt tall because of `coverFrame`, the title
is `lineLimit(1)`, and the trailing `Spacer` was ~1400 pt of unused width. A box of two 13 pt
lines measures **44.6 pt** — it fits inside height the row already spends. §15 is why that
matters: the pane's only flexible child is the waveform, with a hard `minHeight: 160` floor, and
past that floor content that overruns the window centres and clips **both** ends — the song
title off the top and ✓ Correct / ✗ Wrong off the bottom, with no scroller. `App.swift`'s
declared `minHeight: 640` is already 13–67 pt short before this feature existed.

Three things about that box are load-bearing:

- **`.lineLimit(2)` is the height guarantee. The length caps are not.** Measured: 120 Thai
  clusters is 818 pt → 2 lines in the 497 pt box, but 120 Latin capitals is **1501 pt → 4
  lines**. `Store.noteMax` keeps truncation rare for the content people actually write; the line
  limit is what makes overflow impossible. Don't drop it because the text "is already bounded".
- **The note is drawn FIRST and the tags trail**, in one paragraph sharing those two lines rather
  than taking a line each (a separate tag row costs ~15 pt of real height). With a line limit
  something has to truncate, and losing the sentence the setter wrote is worse than losing the
  tail of a list that is also visible in SETUP.
- **The tag runs carry a FILL now**, asked for so the box matches the chips in the song list.
  It is an attributed run with a `backgroundColor` and thin spaces (U+2009) for padding, **not a
  real `TagChip`** — a chip is a view, so a row of them needs `FlowRow` beside the note's `Text`,
  which is the ~15 pt of real height this box does not have, and two sibling views cannot carry
  the `.lineLimit(2)` guarantee between them. Same colours, same meaning, guarantee intact; what
  it gives up against a real chip is the rounded corner. The separator went from `·` to a plain
  space, because a dot floating between two fills reads as a third chip. **The note's own run
  must stay unfilled** — a highlighted sentence in the operator's eyeline reads as a warning, and
  §6d gives every hue one meaning. `CenterView.noteTagFillAudit` exists so `--tagtest` can assert
  both halves from a file that imports AppKit rather than SwiftUI: without it the fill could be
  deleted with all 25 suites green, which is the `Palette.audit` lesson.
- **Rendered only when there is something to show.** Absence then means "no note", which is
  unambiguous; an always-present empty frame in the operator's eyeline is the decoration §6e
  removed when it took out the green dot. The cover frame's always-render rule does not apply —
  it protects against a *hit target* moving, and a title truncating is not one.

The write placement keeps the one thing that makes the key monitor's `typing` branch true out of
the centre pane. A note is held in focus far longer than a numeric time field, so it does not get
to sit beside the transport. See §11 for the cost that remains and is not fixable from here: a
digit typed while a song plays still reaches `1`/`2`.

### `note`

≤120 grapheme clusters, flattened to one line, NFC, trimmed. The cap is a layout constant, the
NFC is so two visually identical Thai strings don't produce a handover diff where nothing
changed (§8f's grapheme-cluster lesson), and the one-line flattening is the only input that can
defeat the height argument above.

**Writes go through `updateConfigQuiet`, never `updateConfig`.** This is the whole safety story
for the field: `updateConfig` stamps `configured = true, auto = false`, so a note written through
it would certify an unreviewed machine guess as human-reviewed — dropping the song out of the
`Return`/`Tab` sweep **and** out of the pre-flight's `stillAuto` and `hookDefault` warnings, so a
round nobody looked at would pass the handover check. That is §11's typed field committing on
blur and §7a4's `applyGuess` certifying itself, in a third costume. And a note is exactly what
a setter writes *before* deciding where the markers go.

Commit on **Return**; losing focus **cancels** — the same contract as `MarkerTimeField`, for the
same three reasons (§11). Clearing the field and pressing Return is how a note is deleted.

### `tags`

Stored as **the strings themselves, not ids into a registry.** Ids look tidier and are wrong
here for two reasons that both bite at the handover: two machines each minting `t4` collide, so
a merge would have to reconcile two registries instead of taking a set union; and an id is
unreadable in a file people hand-edit and that the web fallback round-trips without
understanding.

The registry is therefore **derived from use** (`Store.tagsInUse`), never stored — the same
reasoning as `onsiteEdits` deriving from `base` rather than a flag (§8e). A tag stops being
offered the moment the last song carrying it drops it. It is cached, because `SetupPanel` reads
it from `body`, and the cache is cleared in the four places `songs` changes **and nowhere else**,
which is a completeness you can check by reading `Store.swift` rather than by remembering to add
a call.

≤6 per song, ≤24 clusters each. Both numbers are about the same two lines above. Deduped on
`Store.tagKey` (`localizedLowercase`), because "Pop" and "pop" on one song are one tag by any
reading and two spellings make the registry's suggestions useless.

> **Superseded, and the replacement is narrower than it looks.** This used to read "a tag
> carries no colour, and that is a rule": a user-colourable chip hands §6d's mechanism — one
> meaning per hue — to someone with no reason to know it exists, and an amber chip beside the
> "unreviewed guess" badge is how the one warning that must never be ignored gets diluted.
>
> The owner asked for a colour per tag. It is granted on one condition, which is what keeps
> §6d intact: **a tag chip always shows its word.** The colour is therefore a second cue on
> something already named in full — a scanning aid, never the sole carrier. §6d forbids a hue
> that is the only thing telling you a state; it does not forbid redundant encoding. **If a
> chip ever loses its text, the colour has to go with it.**
>
> Superseded again, and the second round is the one that matters. The first version of this
> paragraph kept two guards: no green/red/amber in the ramp, and `tagsMaxDistinct` pinned to
> the palette size. The owner then asked for **แดง เหลือง เขียว น้ำเงิน ม่วง เทา** and a way
> to choose which tag gets which. Both guards are gone, and the condition above — the word is
> always there — is now carrying the whole thing on its own. See the next two sections.

### The six colours, and what dropping the hue exclusion cost

`TagColor` is the named face of `Palette.tagFill` / `tagInk`: **แดง เหลือง เขียว น้ำเงิน ม่วง
เทา**, in that order. The owner's words, because the picker is the one place a colour has to be
nameable out loud, on a support call or across a studio floor.

**The old rule was "no tag ink within deutan ΔE 8 of green, red or amber".** A red/yellow/green
ramp cannot pass it — a red tag is red. What replaces it is a bound on the thing a glance could
actually misread, and it is **wider**, not looser:

| | old | new |
|---|---|---|
| what is measured | the chip's **ink** (small text) | the chip's **fill** (its whole area) |
| bar | deutan ΔE ≥ 8 | deutan ΔE ≥ **20** |
| worst real value | — | **29.8** (light เหลือง vs red) |

That works because the three status colours only ever reach the eye as **text and badges**,
never as a filled chip — so "could this chip be read as a state" is a question about the fill.
`--palettetest` section 7b asserts it for both themes, plus ink-on-fill ≥ 4.5:1, fill-vs-`panel`
ΔL\* ≥ 2.0, and that **no two chips are the same chip to a deutan viewer** — `max(fill, ink)`
ΔE ≥ 4.0 per pair, which is a measurement result rather than a softened bar (see below).

**The cost, measured and printed on every run rather than left in a comment.** For a deutan
viewer the warm inks sit on top of the status colours — dark เหลือง-vs-amber **ΔE 0.2**,
แดง-vs-green **1.5**, เขียว-vs-green **3.5** — and on top of each other (แดง-vs-เขียว 4.6,
น้ำเงิน-vs-ม่วง 5.4, which is §6d's own accent/purple collision in a new place). So **this is
about four distinguishable groups to a deutan viewer, not six.** The word is the carrier; the
colour is a scanning aid. That is why `--palettetest` prints the ink table under the heading
"ราคาที่จ่าย (วัดไว้ ไม่ใช่ข้อสอบ)" — the number nobody asserted is the one that gets forgotten.

Lightness is deliberately **spread** inside each theme rather than held constant, because §6d
records that this palette's deutan separation comes from the lightness spread and not from hue.
Dark has room — fills L\* 16–32, chip-vs-chip **5.2–45.6** on the fill alone.

**The light theme is where this got decided, and the first answer was wrong.** `panel` is
L\* 88.6 and a fill must clear it by 2, so the usable band is *two* bands (79–86.5 and
90.6–97) with three fills in each. A first pass optimised for separation and produced a
"ม่วง" at L\* 96 and a "แดง" at C 7 — rendered at the real size they read as **plain white
chips**, which fails the request outright. Chosen for legible hue instead, pale แดง and pale
เขียว land **ΔE 2.2** apart: to a deutan viewer, the same colour. Their *inks* are 12.9 apart.

Hence `max(fill, ink)`: in dark the saturated fill carries the identity, in light the ink does.
Asserting the fill in both themes would have been a number arguing for the palette that fails
the thing it was asked for — the inverse of §7a3's "re-measure the constant, don't read it off
the parameter names".

> **ORDER IS THE WIRE FORMAT.** `_settings.tagColors` and `round.json` store the slot **index**.
> Reordering `TagColor`, `Palette.tagFill` or `Palette.tagInk` silently repaints every tag
> anyone chose a colour for, on every machine that opens the file. Append; never reorder.
> `--palettetest` asserts the enum and the ramp are the same length — a name without a colour
> crashes the picker, a colour without a name is unreachable in it.

**`Store.tagsMaxDistinct` is no longer tied to the palette size**, and that is the point rather
than an oversight: once the operator picks the colours, two tags sharing one is their decision,
so keeping the numbers equal would only mean that *naming six colours refused tags that work
today*. It stays at **8** as a readability bound, and `--tagtest` asserts
`tagsMaxDistinct >= Palette.tagSlots` — fewer colours than tags is allowed and means a repeat;
more colours than tags would be dead slots.

### Which colour a tag gets

`Store.tagColors` maps tag key → slot, derived and cached like `tagsInUse`, never stored.
`_settings.tagColors` holds only the **choices**, which is a different thing.

**The operator's choice is applied first and claims its slot; everything else is a hash of the
word.** `tagsInUse` is ordered by how often each tag is used, so a position-based colour would
repaint tags nobody touched every time a song gained or lost one. FNV-1a over the UTF-8 of
`tagKey` — **not** Swift's `hashValue`, which is seeded per process, the identical defect
`tagsInUse` already recorded once. Collisions take the next free slot, walking the keys in
sorted order so the result does not depend on dictionary iteration either.

Claiming the chosen slots before the hash runs is what stops an automatic assignment from
sitting on a colour a human asked for. **It costs the one property the old version had:** the
automatic half is no longer a pure function of the word alone — it depends on which slots are
already claimed, and on whether the library is over-subscribed. So two machines with different
choices can colour an *unchosen* tag differently, which is precisely why the choices travel in
`round.json`. Choosing explicitly is what makes the two screens agree.

### Picking it: the chip is a MENU now, not a remove button

Clicking a tag chip in SETUP used to remove the tag immediately. It opens a menu instead — the
six colours, "อัตโนมัติ", and "เอาแท็กนี้ออกจากเพลงนี้" — and the chip's trailing glyph changed
from `✕` to `▾` to say so.

That is the **safer** direction, not a compromise for the picker: the one thing a slip could do
on that chip was destroy part of a signed-off round, and now a slip opens a menu. It is also how
the colour gets an entry point without putting two different *immediate* meanings a few pt apart
on one ~60 pt chip — §13 rejected exactly that for "click a chip to filter by it", and a menu is
not subject to the objection because nothing happens until you choose. Removing a tag is two
clicks now; that is the price and it is paid in the right direction.

Three details:

- **The menu names the tag, and says "ทุกเพลงที่ใช้แท็กนี้".** The colour is a property of the
  *tag*, library-wide. Without the header, "set this to red" reads as a change to the song in
  front of you — and the setter would discover otherwise by seeing another round repaint.
- **A colour is written through `Store.setTagColor`, a `_settings` write, never `updateConfig`.**
  `updateConfig` stamps `configured = true, auto = false`, which certifies an unreviewed machine
  guess as human-reviewed and drops the song out of the `Return`/`Tab` sweep **and** out of the
  pre-flight's `stillAuto` and `hookDefault` warnings. That is §8g's note trap and §7a4's
  `applyGuess` trap in a third costume, and a chip's colour is further from a decision about
  what goes to air than either of them.
- **`Menu` renders a plain `Button(String)` as a system menu item**, so the colour itself cannot
  be drawn there without a custom label — and a custom label in an AppKit menu loses the
  checkmark idiom. The row is named and ticked instead, which is also the only form that works
  for someone who cannot tell two of the six apart.

### The colours cross the handover, additively and in silence

`RoundPackage.tagColors` carries `tagKey → slot` for **the tags that round uses and that the
sender actually chose a colour for** — a hash-coloured tag needs nothing in the file, because
both machines compute the same answer from the word.

`Store.mergeTagColors` applies it: a local choice always wins, and a tag missing from an incoming
set means "I have nothing to say", never "clear yours" — §8g's rule for the note and the tag
list, unchanged. The difference is that a colour gets **no `DiffRow`**: it changes nothing that
goes to air, and a diff row per tag colour would bury the rows that decide what the audience
hears. Stated plainly so nobody has to rediscover it: **a colour the operator CHANGED does not
travel back if the setter had already chosen one.** Same safe direction as a removed tag.

The web fallback shows tags as muted text in the note box and gives them no colour — the same
reasoning as its read-only note (§8g below): one implementation of the slot→colour mapping, not
two. It never touches `_settings.tagColors`, because it mutates named keys on the object it
loaded and POSTs the whole thing back.

### Tags in the song list

Shown under the title, up to three chips then `+n`.

**The line is reserved for every row as soon as the library holds any tag**, rather than
appearing only on tagged songs. §8c clamps titles to two lines because uniform row heights are
what make a column scannable under pressure; rows that grow only where a tag happens to be is
the worst of both — it moves every row below it and still lines nothing up. A library with no
tags keeps exactly the row it had, because the flag is `tagsInUse.isEmpty` (cached, one lookup
per row).

**The chips are display-only.** Clicking one to filter was considered and rejected for the
reason §13 already records for the SETUP chips: two different meanings a few pt apart on a small
chip is §12's recurring defect, and the filter already has an unambiguous entry point above the
list. That entry point is now labelled **`⌕ กรองตามแท็ก`** rather than `⌕ แท็ก` — the menu only
exists once the round HAS a tag, so the first person ever to use tags has never seen the control
before, and the shortest possible label is the worst possible one.

> **`tagsInUse` cannot use "the first spelling we see".** It walks `songs.values`, and Swift
> seeds Dictionary hashing per process — so that rule is not a rule, and "Rock" vs "rock" would
> have relabelled the suggestion chip at random on each launch. The most-used spelling wins,
> ties broken lexicographically. Found by `--tagtest` failing on one run after passing on the
> previous one: **a check that passes by luck is worse than no check.**

### The handover: additive, in one direction only

Both travel in `round.json` — that is the entire point of a note, written on one machine to be
read on another (§8e). One rule governs the merge:

> **An empty or absent incoming value means "I have nothing to say", never "delete yours."**

| | rule |
|---|---|
| `note` | empty incoming → no row, nothing changes · both sides non-empty and different → one row, the setter picks |
| `tags` | **union**, as a row with a checkbox so the setter can decline · `theirs` shows the RESULT of accepting, not the sender's list |

**That rule is what stops §13's `round.json` gap from blocking this.** `RoundPackage.write`
rebuilds its dictionary from the struct, so a build that does not know a field **drops** it
rather than merging it — a round sent setter(new) → operator(old) → setter(new) comes back with
the field missing. Under an additive rule that reads as *silence* and the local value survives.
Under a symmetric one it reads as a *deletion*, and the diff sheet pre-accepts every row. The
proper fix (hold `raw` per song, read `version`, add `writtenBy`) is still worth doing and is
still in §13 — it is just no longer a prerequisite.

The cost, stated so nobody rediscovers it: **a note or tag REMOVED on the operator's machine
does not travel.** It has to be said out loud. That is the safe direction of the two.

A diff row for either is rendered on **its own lines**, not in a value column: a sentence or a
tag list cannot be compared in ~160 pt, and reading both sides is the entire decision the row
exists for. `copyConfig(from:)` carries both (additively) — the donor exists because a reused
song should not start blank (§8c), and a note is a fact about the song, not about the round.

### The filter: a separate accessor, because of what the other 22 call sites are

Narrowing the list to one tag is three lines of filtering and one real decision: **where**.

`songsIn(_:)` has 26 call sites and only **four** are the list and its navigation. The rest are
`Handoff.export` / `plan` / `apply`, `Preflight.fast`, `reviewRemaining`, `nextNeedingReview`,
`onsiteSongs`, `onsiteFieldCount`, `resetPlayed`, `usedInRound`, the playlist picker's per-round
counts and the `Songs (n)` header. So the natural minimal diff — filter inside `songsIn(_:)` —
would have quietly handed a round over with two thirds of its questions missing, scored the
review sweep against a view instead of the round, and made `✓ ยืนยันครบทุกเพลงในรอบนี้` a lie.

| | |
|---|---|
| `songsIn(_:)` | **the round.** Counts, review sweep, handover, pre-flight, reset |
| `visibleSongs(_:)` / `visibleSongs(column:)` | **what the list shows.** Rows, column counts, ↑↓, `[` `]` |

**The unfiltered column accessor was deleted, not kept beside the new one.** That is the part
that actually protects this: no headless check can prove the UI calls the right accessor, so the
remaining defence is that narrowing the handover now requires typing `visibleSongs` somewhere it
does not belong — a visible mistake instead of an invisible one. `--filtertest` pins the other
half, including the counterfactual (`Handoff.package` handed the filtered list loses 2 of 4
songs) so the cost of getting it wrong is written down as a number.

Four properties, each for a reason:

- **It dies with the process.** `tagFilter` is on `AppModel`, has no `_settings` key, and
  `--filtertest` asserts none appears. A filter that survived a relaunch is how an operator opens
  the app on a show day to a round missing most of its questions — and §8c already measured that
  exact failure for `lastPlaylist`, reported from real use as "the app can't find my songs".
- **It always says what it is hiding.** The strip states the tag, `เห็น n จาก N`, `ซ่อนอยู่ k`,
  and carries its own way out. The `Songs (N)` header above it stays unfiltered on purpose, so
  the two numbers together say "this is a view, not the round".
- **The selection can never be hidden.** `select` clears the filter and TOASTS when handed a song
  the filter excludes — one guard at the one choke point, because `Tab`, `Return`'s advance, a
  log row and `nextNeedingReview` all target the whole round on purpose. And `setTagFilter`
  refuses a filter that would show nothing, even though the menu only offers tags present in the
  round: the invariant should hold by construction, not because one caller behaves.
- **No hue.** `Palette.tintSelect` — the selection emphasis the active column header already
  uses — not a colour with a meaning. §6d gives each hue exactly one, and amber in particular
  means the intro-end stop is not armed and nothing else.

### Searching the round by filename (`/`)

Asked for as *"ค้นจากชื่อไฟล์เฉย ๆ เวลาอยากหาเพลงที่อยากเล่น"*. Same machinery as the tag filter
— `Library.visible` gained a `search:` parameter, so there is still exactly **one** place the
list narrows, and `songsIn(_:)` is still the round.

- **The haystack is the RAW basename, not `displayTitle`.** `displayTitle` only ever *removes*
  from the raw name (the leading track number, the trailing `[Official MV]` boilerplate), so the
  raw name is a superset of what is on screen: typing the `107` you can see at the left of the
  column works, and so does anything you read off the row. The one thing `displayTitle` rewrites
  rather than removes is runs of whitespace, and `searchKey` collapses those on both sides.
- **NFC on both sides**, because a human types this comparison by hand and two visually identical
  Thai strings compare unequal otherwise — §8g's lesson for the note, in the place it bites most.
- Tokens are **ANDed and order-free** (`palmy ooh` finds `202_Ooh! - Palmy`). Thai carries no
  spaces, so one-token substring is the common case.
- **It does not refuse an empty result**, unlike `setTagFilter`: every keystroke on the way to a
  word passes through states matching nothing. The row says `ไม่เจอในรอบนี้ · มีใน EP02 (2)`
  instead — an empty list that does not say where the song *is* is §8c's "the app can't find my
  songs" with a search box on top.
- **Dies with the process, and `setPlaylist` clears it.** Same measured reason as `tagFilter`.
- `select` clears it at the same choke point it clears the tag filter, and says so.

### Clicking away ends editing (`FocusRelease`, the mouse monitor)

AppKit does **not** resign first responder when you click empty space — so until this, a field
kept focus until Esc or Return, and while it has focus the key monitor's `typing` branch is on:
`S`, `R`, `P`, `I`/`O`/`H` and `L` are all dead with nothing on screen saying so. Reported as
*"ตอนนี้ต้องกด ESC เพื่อจะออก มันไม่ make sense"*, and it is a safety fix rather than a
convenience one — §12 already records this trap having no exit at all before Esc was wired up.

- **A local `.leftMouseDown` NSEvent monitor, not a background `.onTapGesture`.** The views most
  likely to be clicked when you are done typing — the waveform, every button — consume their own
  gestures, so a root tap would never see them. Same reasoning as the scroll monitor (§6c), and
  it is nil'd on disappear for the reason recorded there.
- **The click is never swallowed.** It still does whatever it was going to do; the blur just
  happens first.
- **Blur CANCELS, it does not commit.** Resigning fires each field's `onChange(of: focused)`,
  which is the §11 contract — so clicking away means exactly what Esc means: discard. §11 lists
  three separate ways a *committing* blur destroyed a signed-off marker; do not "improve" this
  into a commit.
- **Clicking another text field must not release.** AppKit is already moving focus there, and
  stealing first responder mid-move fights it. The hit view may be a subview of the field (its
  border, its clip view), so `isTextInput` walks up the superview chain.

The decision is the pure function `FocusRelease.shouldRelease(firstResponder:hit:)` because a
click cannot be driven headlessly; `--focustest` asserts it over throwaway AppKit views, and its
negative control (making it always release) fails exactly the three "another field" cases.

**The row appears and disappears; it is not a box that sits over the list.** A field holding
first responder turns the key monitor's `typing` branch on, and in it `S`, `R`, `P`, `I`/`O`/`H`
and `L` all stop working — only `Space`, `1` and `2` are carved out, and only while playback
runs. A permanently focusable search box above the song list would put the transport one stray
click from dead with nothing on screen saying so (§8g records the note field hitting exactly
this). So: opened on a deliberate key, `Return` hands the keyboard straight back after selecting
the first match, and `Esc` closes it in ONE press from inside its own field — gated on
`searchFieldFocused`, because the note field and the search row can both be open and Esc must
still mean plain blur in the other one.

`Return` refuses while playing, like a log row (§8d): narrowing the list is free, but `select`
loads a different file and cuts the audio on air.

**It has a visible button as well as the key** (`⌕ ค้นหาเพลง /`, which names the key). §11
records the same defect for Played: `P` had worked since the native app shipped and was still
reported as "no shortcut", because nothing on screen said so.

Column navigation needs no special case: `select` sets `activeCol` from the song it opens, so
after `Return` the `↑`/`↓` walk the matches, and `[`/`]` already skip columns with none.

`--filtertest` covers it — 25 assertions now, including the counterfactual with a number
(`Handoff.package` handed the searched list loses 3 of 4 songs).

### Where the note is visible: three surfaces, one rule each

| surface | shows | why that much |
|---|---|---|
| the song list, `※` | **that there is a note** | a 9 pt slot holds a glyph, nothing more |
| `CenterView`'s box | note + tags, 2 lines | the height the title row already spends (§8g above) |
| the row's tooltip | note + tags, in full | a hover is asked for, so it can afford to be complete |

**`※` in the song list.** Until this, nothing in the list said *where* the annotations were, so
a setter scanning a round had to open every song to find out.

- **A second reserved slot, not a share of `✎`'s.** A song edited on set can also carry a note,
  and one slot would have to hide one of the two. Reserved whether or not it is filled, because
  a slot that appears only when filled moves the title under the cursor — this row's recurring
  defect (§12: the transport buttons, the focus hint).
- **The glyph was measured, not chosen.** Every other mark here is spoken for — `✎` on-site,
  `✓`/`✗` outcome, `○` never opened, `🎯` guessed, `#` take order — and of the unspoken
  candidates `※` is the only one that fits: **7.01 pt** at the 12 pt it renders at
  (`Typo.font(10)` clamps to `thaiFloor`), against a 9 pt slot. `☰` and `▤` are 10.4–10.6 and
  read as a menu or a filled block; `≡` fits but is the hamburger idiom; `🗒` is an emoji, i.e.
  17 pt and a colour this palette does not control. `※` also carries real ink at 1× rather than
  an all-antialiased stroke, and its radial shape cannot be read as the pencil's diagonal.
  > Measured in passing and worth knowing: **`✎` is 10.93 pt in its own 9 pt slot** and has
  > always overflowed it by ~1 pt a side. Nothing is broken by it — the neighbouring gap is 8 pt
  > — but size a new slot from a measurement, not from the one next to it.
- **Grey, never a hue** (§6d), and **note-only, never tags.** The filter above the list answers
  "which songs carry tag X" better than a glyph can, and a mark meaning "note or tags" would
  answer neither question. Absence meaning exactly "no note" is the property worth having.

**The note's text is under the row too**, asked for as *"ให้โน้ตคนรันแสดงใน list เพลงด้วย
ข้างล่างตรง ก็ได้"*. The `※` says only *that* there is one, so a setter scanning a round for
"which question did I flag" still had to open every song.

- **Reserved for every row as soon as any song in the library carries a note**, exactly like the
  tag line and for the same measured reason: a line that appears only where a note happens to be
  moves every row below it while lining nothing up. `Store.anyNote` is cached beside `tagsInUse`
  and cleared by the same `clearTagCaches()` — deliberately one function, because both are
  "something about the whole library derived from a per-song field", and a second cache with its
  own invalidation is how one of them goes stale. A library with no notes keeps the row it had.
- **One line, truncated.** A column is ~299 pt at equal thirds and a note is up to 120 clusters,
  so most will clip. The row's tooltip carries it in full and the centre pane shows two lines of
  it the moment the song is opened; a second line here would cost ~16 pt on every row in the round
  to finish a sentence that is about to be on screen anyway.

**The read-only box in the web fallback.** `index.html` now draws the same note beside the same
title. It is the *mid-taping* fallback (§6c), so an operator who falls back to it was losing
sight of the one field written for them to read.

- **Reading only. Writing stays in the native app**, where the caps, the NFC normalisation and
  the commit-on-Return contract live. A second half-implementation of those is how the two
  would drift.
- Nothing there can lose either field, which was verified rather than assumed: `cfgFor` builds
  an entry wholesale only when one is absent, and `saveConfig` POSTs back the object it loaded.
  Measured end to end — a note, a 2-line note, a tags-only song and a note full of `<script>`
  all survived a round trip through the web app byte-intact, and `_settings` with them.
- **`⤵ ดึงค่าจากรอบ` carries them too**, matching `copyConfig(from:)`: additive, union on tags,
  deduped case-insensitively, and capped at the native's own numbers so this path cannot write
  a value the native app would silently trim on its next load.
- **Two lines there, as in the native app — but for a different reason, and the difference is
  the point.** The native box is free because the title row is already 52 pt tall (`coverFrame`).
  The web has no cover art, so its title block is only 36–40 pt and a second line grows the row
  by ~9 pt. That is still free, because `.se{margin-top:auto}` pins ✓ Correct / ✗ Wrong to the
  bottom and the 9 pt comes out of the slack above them: measured at a **620 px** viewport —
  below the native app's own declared minimum — a 2-line note still leaves **156.5 pt** of
  slack. The native's hard `minHeight: 160` floor, where overflow clips both ends, has no
  equivalent here.
- **`.notebox[hidden]{display:none}` is load-bearing.** An author `display` beats the UA sheet's
  `[hidden]`, and the box sets `display:-webkit-box` for the line clamp — the identical pair the
  log overlay needed (§12). Without that line the empty box can never be hidden.
- Every node in it is filled with `textContent`. The note is free text a person typed, and the
  row's glyph is a literal so the note never goes near `innerHTML` either.

### If an audience or second-screen view is ever built, notes must not reach it

§13 lists one as an idea. `note` is the first free text in this app that one person writes for
another to read on the day, and its content is precisely what the contestants must not see:
`"ฝั่งซ้ายน่าจะได้เปรียบ"`. Written down here because by then nothing in the code will say why.

### Verify

```bash
INTROPLAYER_DIAG=1 $BIN --notetest   # 66 assertions
INTROPLAYER_DIAG=1 $BIN --tagtest    # 89 assertions
```

Both are **read-only**, and by construction rather than by care: every `Store` they build comes
from `Store.init(rawForTest:)`, which sets a `readOnly` flag that makes `scheduleSave` and
`saveNow` no-ops. That is what lets them exercise `set`'s read-it-before-you-delete-it guards and
`Handoff.apply` (which ends in `saveNow()`) against controlled values instead of the operator's
real file — something `--handoff` cannot do, which is why `--handoff` is in the write-y list.
They also **measure** the layout claims through `Typo.nsFont` rather than asserting them.

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
    "backupDir": "",          // ALSO copy each launch snapshot here; empty = local only — §5c
    "setterName": "ภู",       // who this machine's setter is, stamped into round.json as `by`
                              // — §8e. ≤40 clusters, one line, NFC, clamped on BOTH read and
                              // write because it crosses machines into a one-line strip.
                              // Absent when empty; never per round — it describes the person
                              // at this keyboard, not the work.
    "tagColors": { "ยุค 90": 2 }  // which colour the operator CHOSE for a tag — §8g. Keyed by
                              // Store.tagKey, value = INDEX into Palette.tagFill, so the ORDER
                              // of that array is a wire format. A tag absent here is coloured
                              // by a hash of its own word. Max 64 entries; a slot outside the
                              // running build's ramp is dropped on read, not clamped into it.
  },
  "EP01/SongA.m4a": {
    "introStart": 14.2,   // seconds; intro begins here
    "introEnd": 15.5,     // seconds; auto-stop (with fade) lands here
    "hook": 60,           // seconds; Reveal jumps here
    "trimDb": 0,          // per-song manual gain trim, dB (−12..+12)
    "ignoreEnd": false,   // if true, don't auto-stop at introEnd
    "note": "ฝั่งซ้ายน่าจะได้เปรียบ · คนรุ่น 40+ รู้แน่",  // what the setter tells the
                          // OPERATOR, read beside the song title the moment they open the
                          // question — §8g. ≤120 clusters, one line, NFC. Absent when empty.
    "tags": ["ยุค 90", "ผู้หญิงร้อง"],      // ≤6, ≤24 clusters each. The STRINGS, not
                          // ids — the registry is derived (`Store.tagsInUse`), §8g.
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

- **`note`/`tags` are not in `base` and not in `MarkerField`.** They change nothing that goes to
  air, so they have no `revert` and no on-site badge — and a text- or list-valued `MarkerField`
  case would force `onsiteEdits`, `revert`, the setup panel's field cards and `--handoff` to
  answer "what does reverting a sentence mean". The handover carries them through
  `DiffField.note` / `.tags` instead — §8g.
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
| `T` | Toggle Played on current song — **one key from `R`**, see below |
| `I` / `O` / `H` | Mark introStart / introEnd / hook at playhead — **confirm-on-second-press while playing** |
| `←` / `→` | Nudge the **focused** marker by 0.01 s (`AppModel.nudgeStep`). Autorepeats — hold to slew |
| `Shift` + `←` / `→` | The same nudge at **0.1 s** (`nudgeStepCoarse`) — the `±` buttons' own step, i.e. Unity's 10× |
| `M` | Cycle which marker `←`/`→` nudges |
| `/` | Open the song search (filename) — `Esc` closes, `Return` takes the first match |
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
| `⌥` + `←` / `→` | Pan the view by 25% of the visible span (was `Shift`, which the coarse nudge took) |

Handler ignores keystrokes when focus is in an `<input>`, and bails on Cmd/Ctrl/Alt so `Cmd+R`
reloads instead of firing Reveal.

### Fine adjustment: `focusMarker`, `←`/`→` and the typed fields

Three ways to set a marker, each for a precision the others cannot reach:

| | precision | when |
|---|---|---|
| drag on the waveform | whatever a pixel is worth at the current zoom | placing it roughly |
| `−` / `+` buttons | 0.1 s (deliberately unchanged) | stepping by ear |
| `←`/`→` | **0.01 s** — what markers are actually stored at | the last 2–3 frames |
| typed `mm:ss.hh` field | exact | copying a time off a reference, or a value read out loud |

> **A marker must be ACTIVE before a drag can move it.** A press on an inactive marker only
> activates it and consumes the gesture — no move, no pan, no seek; a second gesture drags.
> The waveform is also the surface for panning and click-to-seek, so the old one-stage grab
> meant any press landing within 8 pt of a line moved a signed-off value: the waveform
> equivalent of the unguarded `I`/`O`/`H` above. "Active" reuses `focusMarker` rather than
> inventing a second notion of selection, so the thing `←`/`→` nudges and the thing a drag
> moves are always the same marker, carried by the same emphasis cue (§6d: never a new hue).
>
> The decision is a pure function, `MarkerGrab.decide`, so `--grabtest` can prove it without
> driving a gesture. Two details in it are load-bearing and invisible in a screenshot: the
> distance tie-break is `<=` not `<` (with `<`, two markers on the same time make the later one
> unreachable — song 102's real state), and a press that moves nothing must WRITE nothing. The
> old code called `updateConfig` on every `onChanged` including a zero-movement click, which
> stamps `configured` and pushes an undo snapshot — dropping the song out of the `Return`/`Tab`
> sweep and out of the pre-flight warnings. Exactly the defect recorded for the typed field.

`AppModel.focusMarker` is what `←`/`→` moves. It **follows the hand** — a waveform drag, an
`I`/`O`/`H`, a `±` press, a click on the card or focusing its text field all set it — so the key
always means "the one I am working on" and there is no mode to remember. `M` cycles it. It is
carried in the UI by **emphasis** — the other markers dim to half strength while the active one
keeps full colour and gains a 4 pt stem, a taller flag, an outline ring and a soft halo band —
never a new hue (§6d: one meaning per hue).

> Asked for as *"อาจจะเปลี่ยนสีเป็นสีเหลืองก็ได้"*, and that is the one colour it cannot be:
> §6d gives amber exactly one meaning — the intro-end stop is not armed — and a yellow marker
> sitting 60 pt under the amber guard strip is precisely the dilution that rule exists to
> prevent. §12 records the Played button living as a §6d violation for months because a hue in
> a place nobody is editing does not announce itself. Dimming the other two says "this is the
> one" at least as loudly and costs no hue.

The nudge is deliberately **not** behind the two-press rule below, and the reason moved when the
key did. It used to be that autorepeat is suppressed app-wide, so you could not slew Intro End
across the playhead faster than the playhead advances. **The arrows are now the one pair exempt
from that suppression** — 0.01 s a press is 100 presses per second of audio, so holding the key
has to work or the feature does not. What actually protects this is what always actually
protected the *typed field*, which never had a rate limit either: §10's rule that `remode` may
only ARM the intro-end guard, never disarm it. The nudge also commits through a 350 ms debounce,
so a held key cannot thrash the node.

> **A debounce that is re-armed per keypress is never reached by a HELD key, and that is not a
> detail.** Autorepeat arrives every ~30 ms against a 350 ms timer, so `remode` never ran at all
> while the key was down: the node stayed bounded at the OLD Intro End, the audio stopped there,
> and the guard strip counted down to the new value with the button still reading Pause. Not a
> §10 violation — nothing played past Intro End — but a dropout during the one task the key
> exists for. `Player.boundRunsOutEarly` commits immediately *only* when the node is about to run
> out; holding the key far from the boundary still coalesces into one commit on release, which is
> what the debounce is for.
>
> **Superseded, and worth reading before touching either step.** That paragraph used to end "the
> physics the fix does not change: 0.01 s per press against a playhead advancing 1 s per second
> means you cannot outrun the playhead by holding the key". `Shift` + the same keys is 0.1 s a
> press, i.e. **~3.3 s of marker movement per second of real time**, so you can. Measured, that
> changes nothing about safety, and the measurement is the point:
>
> - `boundRunsOutEarly` answers true only when the bound moved **OUTWARD** (`want >
>   scheduledEndFrame`). A held `Shift+←` therefore calls `remode` **zero** times, and the node
>   stays bounded at the original Intro End.
> - What stops the audio is the **guard timer**. `Player.tick` reads `configProvider()` live every
>   20 ms and fades at `introEnd - fadeSec` with no reference to the scheduled end — §8b's
>   independent safety net, doing exactly its job. Measured on the real library: slewing Intro End
>   from 20 s at 5 s/s from a playhead at 4 s, the two meet at ~6.7 s and the audio stops at
>   **7.500 s**. Not the 13-second hang the node bound alone would have given.
>
> `--remodetest` case 4 pins that, and its negative control is instructive: making the guard
> refuse to stop earlier than the scheduled end sends `maxReached` to **19.580**. Note that
> removing §10's arm-only rule does NOT fail case 4 — `remode` is never called on that path, so
> the control's code never runs. Case 1 is what covers §10. **Two protections, two cases; do not
> read either as cover for the other.**

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

### `T` for Played, and why it is NOT behind the two-press rule

`P` toggled Played from the day the native app shipped, and was still reported as having no
shortcut — a discoverability defect rather than a missing feature: the SETUP button named no key
and the transport button read **"Mark Played"** in English among Thai labels two panes away. The
first fix bound `T` as well and named both on both buttons. The second, on request, **dropped
`P`**: naming the key is what the problem needed, and two keys for one toggle is two things to
remember plus one more key that does something while a take is running. Both buttons say `T`.

**`T` is keyCode 17, one key from `R` (15), which puts the chorus on camera.** §11 above says
that if a key is ever added near `R`, the reasoning says to guard the new key. It is deliberately
**not** guarded here, and the reason is worth keeping because the rule looks like it applies:

- The mis-press that costs something is **reaching for T and hitting R**. A guard on `T` only
  guards the other direction — reaching for R and hitting T — which costs a toggle.
- Toggling Played writes **no log event**, airs nothing, and is undone by pressing the key
  again. Nothing about the key itself needs confirming.

So the adjacency is a thing to know, not a thing a guard fixes. If it ever bites, move Played off
the QWERTY row; **do not guard `R`** — §11 explains at length why Reveal must stay immediate.
The same trade shows up in the transport row: see §12's note on moving the Played button.

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

> **The note and tag fields do not change which keys are carved out, and that has a cost worth
> knowing.** §12 keeps `Space`/`1`/`2` live while a text field holds focus AND playback is
> running — deliberately: a buzz that cannot be paused or scored is worse than a character that
> does not arrive. For the numeric marker fields that was free ("nobody types a time while a
> question is on air", and a digit is never valid mid-time anyway). A note is the first field
> here where a digit is ORDINARY CONTENT: typing `ยุค 2000` while a song plays fires ✗ Wrong
> and writes a log event. Paused is not playing, so during a real take the field types normally
> — the window is the setter auditioning while writing. The SETUP card says so on screen rather
> than leaving it to be found, and `↩ ยกเลิกรายการล่าสุด` undoes a stray event. If that window is
> ever worth closing, the fix belongs in the field, not in the monitor.

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
- **The auto-gain was measured on the intro and applied to Reveal**, which plays the hook. It
  took hooks the masters had already levelled to within 3.53 LU and spread them to 15.21 LU —
  the feature made the on-camera moment *less* even than doing nothing — with song 107's reveal
  at 15.9 LU over target and 10.78 dB into the limiter. All three things that should have caught
  it were scoped to the intro: `--loudtest`, the level card's single number, and the pre-flight's
  `squashedIntro`. **A measurement window is part of a feature's contract: when a second verb
  plays a different stretch, the window has to follow it or the levelling runs backwards.** See
  §7a5.
- `--loudtest` measured the intro peak with `an.peak()` — **channel 0 only** — while the shipping
  `applyGain` uses `peakAllChannels`, which §7a3 records as a deliberate fix after channel 0
  missed a hard-panned transient by 1.4 dB. The test kept the old call, so it under-reported
  headroom by **1.41 dB on song 106**: the cross-check was comparing something slightly
  different from the code it was checking, which §7a3 itself calls worse than not comparing. It
  happened not to change any verdict on this library, which is exactly how it survived.
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

- **Two keys for Played, and the useful one unnamed.** `P` and `T` both toggled it; the reason
  `P` was reported as "no shortcut" was that nothing on screen named it, which naming fixed.
  Dropped to `T` alone on request — a second binding is a second thing to remember and one more
  live key during a take.
- **The one list in the app that is ABOUT colour showed none of it.** The tag colour menu was
  six plain names. §8g had written off the idea ("`Menu` renders a plain `Button(String)` as a
  system menu item") — true of a `String` label, not of a `Label` with an image: AppKit renders
  a **non-template** `NSImage` in a menu in its own colours. `Palette.tagSwatch` draws one per
  slot, reading the hex out of `Palette.audit` **by name** so a seventh colour cannot ship with
  a stale grey square — `--palettetest` section 9 asserts exactly that, plus `isTemplate ==
  false`, which is the one flag whose loss would silently repaint every swatch in the menu's
  own text colour.
- **The active marker was carried by a 3 pt stem against a 2 pt one.** Legible when the only
  thing that moved it was `Shift+←/→`, not when a plain arrow does — and at 81 PPI a 1 pt
  difference is about 0.3 mm. The unfocused markers dim to half now and the active one gains a
  halo band, a taller flag and a ring. Emphasis, not a fourth hue.
- **The receive banner looked at the selected round only.** `detectIncoming` read
  `RoundPackage.url(forRound: currentPlaylist)`, so three setters each handing a folder over
  raised a strip for whichever round happened to be open and the other two sat unimported with
  nothing on screen saying so — **1 of 3**, measured by `--incomingtest`. Invisible with one
  setter, which is why it survived. The fix is a sweep, and the test had to move with it: the
  defect was not in the per-round decision but in how many rounds the caller asked about, so an
  assertion about the decision would have passed before and after. `Handoff.waitingRounds` is a
  pure function with its two disk touches injected, so the diagnostic drives the real loop.
- **The setter's name was never saved.** `AppModel.setterName` was a bare `@Published` with
  nothing behind it, so the field in the handover sheet reset on every launch and `round.json`
  went out with `by: ""` — which both display sites render as **"ไม่ระบุชื่อ"**, the one field
  that says whose round it is. Harmless with one setter, which is why it shipped. And
  `RoundPackage.read` took `by` unbounded from a hand-editable file written by another machine,
  straight into a one-line strip.
- **A round you had already signed off came back asking to be "received" — and accepting would
  have reverted your own work.** Export and import both stamp `base` from the result and `plan`
  compares incoming-vs-local, so a round the setter sent and kept editing, or one the operator
  imported and then changed on set, both produced rows; the diff sheet pre-accepts every row, so
  the obvious button restored the snapshot those edits were made on top of. Latent while only the
  selected round was checked, and a strip that reappears from anywhere once it is swept.
  `Handoff.alreadyTakenIn` is the test — `base` equals the package for every song in it — not
  "do the values differ". Negative control: removing the call fails exactly the one assertion
  that is about it.
- `tagsInUse` picked the surviving spelling of a tag by **Dictionary iteration order**, which
  Swift seeds per process — so "Rock" and "rock" in one library relabelled the suggestion chip
  at random between launches, and `--tagtest` was flaky rather than wrong. Most-used spelling
  wins, ties lexicographical. A check that passes by luck is worse than no check (§8g).
- The note's height safety was first documented as coming from `Store.noteMax`. Measured, that
  is false: 120 Thai clusters is 818 pt but 120 Latin capitals is 1501 pt, i.e. 4 lines in a box
  budgeted for 2. `.lineLimit(2)` is the guarantee and the cap is only a readability bound —
  stated that way round now, because the wrong version is an invitation to delete the line that
  actually holds (§8g).
- The tag add field is hidden at the per-song cap, which also hid the `n/6` counter next to it —
  so hitting the limit looked like the row had broken. It says so in words instead.
- **`Palette.audit` grew by sixteen values and `--palettetest` stayed at 64 assertions.** The
  per-tag colours were added, named in the audit list, and measured by nothing — the identical
  failure §6d records for the ten tints the light theme added. Completing it took the suite to
  **144** and immediately found four real faults: `tagFill2/3/4` sat 1.1–1.6 ΔL\* from `panel`
  in the LIGHT theme, i.e. chips that do not read as chips, and `tagInk5` was **ΔE 7.1 from
  green** for a deutan viewer — a tag that could be read as "a human answered correctly", which
  is the exact confusion the no-colour rule existed to prevent. Adding a value to the audit list
  is not the same as measuring it.
- **The transport's Played button was `Palette.green` when set** — a live §6d violation that
  outlived the rule by months. Green means "a human answered correctly" and nothing else, and
  §12 already records that `✓` once meant both "played" and "correct" with two near-identical
  glyphs. The SETUP card for the *same flag* has always been `tintWarn`/`amberOnTint`, so the
  two halves of one toggle disagreed about what colour the state is. Both are amber now.
  Noticed only because the button was being moved for an unrelated reason — a hue violation in
  a place nobody is editing does not announce itself, which is the argument for `Palette.audit`
  naming every value and for a check that can actually fail.
- **`--tagtest` asserted `Palette.tagSlots == Store.tagsMaxDistinct`**, which encoded "the cap
  exists so every tag gets its own colour" as an equality. It was true and useful right up to
  the moment the owner named six colours — at which point the honest change (six colours) would
  have silently become "the library may now hold only six distinct tags", refusing words that
  work today. The equality is `>=` now and the cap's doc comment says what it is for instead of
  what it happens to equal. **An assertion that pins two numbers together outlives the reason
  they were equal**, and the test is then the thing arguing for the wrong design.
- **A `ps | grep` that matched its own `grep`** — see the installer entry below; it also makes
  the point that `ps` output is a live process table and anything reading it is in it.
- Esc did not work inside a text field: the key monitor's `typing` branch returns the event to
  the field before the Esc cascade is reached, so the only way out of the note or tag field was
  the mouse. On a shoot the keyboard IS the instrument — `S`, `R`, `P`, `I`/`O`/`H`, `L` all die
  while a field holds focus, and the note is the first field in this app where typing letters
  LOOKS like it is working, so nothing on screen says the transport is dead. Esc now resigns
  first responder from anywhere, which fires each field's blur-cancels contract (§11) and so
  keeps Esc's meaning: discard, do not write.
- **A "does this glyph exist?" check that could not fail**, written to protect the song list's
  `※` and caught by its own negative control on the first run. Two wrong ways to ask it, both
  of which look right: `CTFontGetGlyphsForCharacters` queries the **base** font only and knows
  nothing about fallback, so it reports `※` as absent — true of SF and irrelevant, because
  §6d's whole mechanism is the cascade (`※` lands in HelveticaNeue exactly as `ก` lands in
  SukhumvitSet). And testing the laid-out line for glyph 0 **never** fails: CoreText's
  `LastResort` font supplies a glyph for every codepoint in Unicode, assigned or not — U+E000
  comes back as glyph 4 at 13.20 pt. The discriminator is the run's **font name**: landing in
  LastResort *is* the placeholder box. `Palette.audit` in a new costume, and the negative
  control is the only reason it was not shipped green.

> **The test-honesty audit.** One question — do these diagnostics fail when the thing they claim
> to check is broken? — answered by injecting 16 deliberate defects. Everything below was then
> confirmed by hand before being acted on.

- **Every diagnostic in this project exited 0, whatever it found.** `App.swift` had **32
  `exit(0)` and zero `exit(1)`**, so `INTROPLAYER_DIAG=1 $BIN --remodetest && echo ok` printed
  `ok` with the intro-end guard deliberately broken. None of these checks could fail a script, a
  release step or a pre-push hook — they could only be read by a human who remembered to look.
  §12's `--loudtest` lesson is that a suite which cannot report its verdict reads exactly like
  one that passed; this was the same hole one level out, for all of them at once. Verdicts go
  through `Diagnostics.verdict` now and the diagnostic exits are `exit(Diagnostics.exitCode)`.
  `--version` and `--whereami` stay at 0 — they report, they do not assert.
- **`--playtest` printed three lines of facts and NO verdict**, while §14 described it as
  "asserts playback stops AT introEnd (overshoot must be 0)". It asserted nothing: a human had
  to read `overshoot=0.000` and know what it should be. That is the only end-to-end check of §1's
  core requirement. It has a verdict now, and it needs **both** halves — a guard that never
  released would make `overshoot` 0 forever and look perfect, so `ignoreEnd` having to go PAST
  the boundary is what proves the stop is a decision rather than a wall.
  > Writing it, the first version read `stopped` *after* the second phase had reset it to nil and
  > failed a passing run. Capture a phase's verdict inside the phase.
- **"no songs" read as a pass.** `--remodetest` and `--overview` — the only end-to-end checks of
  the intro-end stop and of the waveform markers are placed on — opened with
  `guard let s = songs.first else { print("no songs"); return }` and exited 0. On a fresh clone,
  in CI, or on a `/Applications` install before the operator has chosen a library, they printed
  one line and claimed nothing was wrong. `Diagnostics.cannotRun` says "ตรวจไม่ได้" and fails:
  **"I could not check this" is not "this is fine".**
- The handover's receive sweep could not see a **note-only or tag-only** package, and a
  **declined** row made the round wait forever with the decline pre-accepted. See §8e's
  `Store.takenIn` section; `--incomingtest` went 27 → 50 and its negative control fails exactly
  the four assertions that are about the new guard.
- `Palette.audit` was a parallel copy of the colours and **nothing measured the real ones** —
  amber could become green with 187 assertions saying the palette was fine. And `--palettetest`
  never compared amber against green or red at all. See §6d.
- **`/` then `L` then `L` silently killed the transport.** `ContentView`'s
  `if model.showLog { LogPanel() } else { SongListView() }` gives the two branches separate view
  identities, so toggling the log remounts the whole song list and refires every `onAppear` in
  it — including `searchRow`'s unconditional autofocus. First responder landed back in the search
  field with nobody having touched it, which turns the key monitor's `typing` branch on: `S`,
  `R`, `T`, `E`, `I`/`O`/`H`, `M`, `L`, `Tab`, `Return` and the arrows all dead, with the row
  looking exactly as it did. "Search a song, open the log to check the running order, close it"
  is an ordinary sequence mid-taping. `AppModel.searchWantsFocus` is a one-shot: the focus belongs
  to the ACT of opening the row, not to the row appearing.
- **Holding `←`/`→` on Intro End during playback made the audio stop dead.** The nudge commits
  through a 350 ms debounce on purpose (committing per keypress calls `remode`, which
  re-schedules and clicks), but the arrows are the one pair exempt from the app-wide autorepeat
  suppression (§11) and autorepeat arrives every ~30 ms — so a held key **re-armed the debounce
  before it could ever fire**. `remode` never ran, the node stayed bounded at the old Intro End,
  and the guard strip went on counting down to the new value while the button still read Pause.
  On camera that is indistinguishable from a hang. Not a §10 violation — nothing played past
  Intro End — but a dropout during the exact task the key exists for.
  `Player.boundRunsOutEarly` is a read-only query (it schedules nothing); `nudgeFocused` commits
  immediately only when the node is genuinely about to run out, so holding the key far from the
  boundary still coalesces into one commit on release.
- `switchDataRoot` cleared every per-path cache and left **`incomingRounds` / `dismissedIncoming`
  describing the folder it had just left.** Round names repeat across libraries (`EP01` exists in
  both), so the strip and the picker's 📥 answered for the wrong folder and a round genuinely
  waiting in the new one stayed invisible until the next window activation — §8e's measured
  "เห็น 1 จาก 3 — หาย 2 ชุด" through a different door. Nothing could be written across libraries
  (`openImport` re-reads under the new `AppPaths.root`), so the cost was what was on screen.
- The `ignoreEnd` Intro End marker was **fainter than the value its own comment said it was
  rescuing**: `marker` halves an unfocused marker and `Color.opacity` MULTIPLIES, so 0.55 × 0.5
  composited to **0.275** against the 0.30 it replaced. The value there is a factor, not a
  result — work out both composites before changing it.
- **`L` moved the centre pane sideways by 120 pt.** `SongListView` and `LogPanel` occupy the same
  slot and were both 780 until 1.6.2 widened the list to 900 on request and left the log pane
  behind. So pressing `L` — which the operator does *during a take* to check the running order —
  moved the waveform, the playhead, every marker, the transport row and ✓/✗ 120 pt across
  (measured at the 1900 breakpoint: the centre pane went 660 ↔ 780). §12 already records that
  class three times (the transport buttons that slid when playback started, where a click aimed at
  Reset could land on Reveal; the conditional focus-hint line; the cover frame that appeared and
  disappeared). **Two literals in two files is how it came back** — `AppModel.leftPaneWidth` is
  now the one source, so a future divergence requires typing a literal where a function call is,
  which is §8g's "a visible mistake instead of an invisible one".
- The app's name was on screen **three times in two strips**: the native titlebar
  (`WindowGroup("RGF Intro Player")` keeps it), the show's logo, and `Text("RGF INTRO PLAYER")`
  28 pt below the titlebar — which also spent ~170 pt of header width the live chips want. The
  words were made conditional on `ShowLogo.prepared == nil`, which is a real state twice over: a
  public build carries no `brand/` payload (§15), and macOS hides the titlebar in fullscreen.
  **Superseded on request** — the words are back beside the logo unconditionally. The width half
  of the argument is measured in §6e and was never close to binding: 308 pt spare at the declared
  minimum window width. An estimate ("~170 pt") carried a design decision it could not support.
- **A layout breakpoint above the default window size made the default experience the fallback.**
  `isWide` needed a 1900 pt window; `defaultSize` was 1600. So on the production 2560x1080 panel
  the app opened in the one-scroller layout, the three-column list §8c treats as the primary
  design was not what the operator saw, and the fold and edge-drag controls — which existed only
  in the wide layout — looked simply absent. Reported as two features "not working". Nothing was
  broken except the default, and no diagnostic could have caught it: it is only visible by looking
  at a running window. The breakpoint is gone entirely now (§8c), and `defaultSize` is 2000.
- **Both new controls were invisible, and that reads exactly like broken.** The fold was a bare
  5.48 pt grey `‹` with no background; the drag edge's only affordance was the cursor changing on
  hover, which nobody discovers by not hovering. §12 already records this shape for `P`, which had
  toggled Played since the native app shipped and was still reported as having no shortcut because
  nothing on screen said so — and it was missed again in the same file. The fold reads as a button
  now and the edges carry a visible grip.
- **A width assertion that compared against the constant it was testing could not fail.**
  `--foldtest`'s pane checks read `PaneLayout.floors`, so setting the floors to zero moved the
  goalposts: 52/52 green with the centre pane resolving to **0 pt**. Caught only by running the
  negative control. Third occurrence of the `Palette.audit` lesson; the fix is literals.
- **`วิธีใช้งาน-SETUP.md` had the two arrow bindings swapped**, and had since 1.6.2 moved the
  nudge off `Shift`: the guide said `Shift+←/→` nudged the marker 0.01 s and that a bare `←/→`
  panned the view, while the code did the opposite. The one document a crew machine actually
  carries, describing the two keys a setter uses most. Found only because the owner asked for
  `Shift+←/→` to be *added* — which it reads as if it already was. **A shortcut table is code's
  only user-visible contract and nothing checks it**; when a binding moves, the table moves in
  the same commit.
- **The show's logo did not appear until the app was relaunched, on a new machine only.**
  `ShowLogo.prepared` was a `static let`, i.e. a permanent memo, and `Seeding.run` is guarded on
  `AppPaths.hasRoot` — so a first run copies nothing, the header memoises "no logo", and the
  folder the operator then chooses seeds the file in with nothing left to re-read it. The comment
  above the `Seeding.run` call said "Before anything renders… nothing has touched it yet", which
  was true and not the problem: the problem was that on that run there was nowhere to copy TO.
  Invisible on this machine, where `brand/logo.png` is in place before launch — it took a fresh
  install on a second machine to see it, which is also the only place it can happen. The memo is
  dropped by `Seeding.run` itself when it actually places a file; `--logotest` asserts both halves
  (the memo holds, and `invalidate()` really re-reads), and its negative control — making
  `invalidate()` a no-op — fails exactly the one assertion that is about it.
- Symbol-only controls had **one `accessibilityLabel` in the whole app** and 20 `.help(...)`
  tooltips, which set help text and not a label — so `⋯`, `🎯`, `↺`, the trim `0` and the sheet
  closes were unnamed to VoiceOver and Full Keyboard Access. Labelled now. The decorative glyphs
  (`♪` for "no cover", `⌕`, the diff row's `→`, the strip's `📥`) are `accessibilityHidden`
  instead: **labelling furniture is worse than leaving it**, because it announces decoration as
  an action.

**Web version:**
- `selectSong` cleared `env` but **not `sqPrefix`**, which every guard downstream tests
  (`rmsRange`, `measuredRms`, `rebuildCols`). So after switching songs those guards passed on
  the *previous* song's prefix sums while `env` was null, and `rmsRange` threw on `env.length`.
  Any marker edit inside the decode window — `⤵ ดึงค่าจากรอบ`, `I`/`O`/`H` — therefore died
  inside `afterCfgChange` **after** writing the value and **before** `saveConfig`: an edit that
  looked applied and was never saved. The "not analysed yet" path those guards lead to was
  already written and simply unreachable (`measuredRms` returns `scope:null`, the panel says
  "กำลังวิเคราะห์…"). Clear the two together. Found while testing the note box.
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
  Setter → operator handover: done, §8e. Typed marker fields, `←`/`→` nudge, bounded hook
  whole-song overview strip, log-as-pane, level bar, destructive buttons behind `⋯`,
  the setter's note + tags: §8g,
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
- **The web fallback cannot EDIT the note or tags**, only show them — deliberately (§8g: one
  implementation of the caps and the commit contract, not two). Worth revisiting only if a
  setter ever has to work on a machine that is not a Mac, which is the same condition as
  porting the handover UI below.
- **The tag filter has no keyboard shortcut and is not in §11's table.** It is a menu plus an
  explicit `✕ เลิกกรอง` in the strip. `Esc` would be the natural key and was left alone: that
  cascade already has five steps (pending → diff → About → handover → log), and a sixth that
  silently widens the list is not obviously what `Esc` should mean there.
- **The filter offers one tag at a time, not a combination.** Two tags (AND/OR) needs a UI for
  the operator to say which, and nothing has asked for it. The accessor takes a single tag, so
  adding it later means changing `Library.visible` and the strip, not the wiring.
- **The SETUP tag chip opens a menu** (colour · อัตโนมัติ · remove) and still does not filter by
  itself. Two different *immediate* meanings a few pt apart on a ~60 pt chip is §12's recurring
  defect; a menu escapes it because nothing happens until you choose, which is why the colour
  picker could live there and the filter still cannot. The filter's entry point stays above the
  list.
- **A global tag rename/delete** (fixing a typo across a round) is bulk work: no cross-song undo,
  and `afterBulkChange` drops the stack. Out of scope on purpose.
- **`songsIn(_:)` and the fold: no check can prove the UI calls the right accessor.** `ColumnFold`
  and `--foldtest` cover the decision, and §8c's defence is that narrowing the handover would
  require typing `visibleSongs` somewhere it does not belong — but a fold implemented as a filter
  needs no `visibleSongs` at all, which is §13's existing item 2 in a new place. The fix is the
  same and still cheap: lift `songsIn` to `Library` where a test can reach it.
- **`AppModel` has no test harness, so three write paths are still uncovered.** `setColumnCollapsed`
  routes through a pure decision now, but `select`'s unfold, `setPlaylist`'s and `switchDataRoot`'s
  clears, and (from §13 item 1) `setNote`/`addTag`/`removeTag`'s use of `updateConfigQuiet` all
  live on an `AppModel` that no suite constructs — every one of them can be broken with the whole
  suite green. The blocker is that `AppModel.init` loads the real store, seeds and snapshots; a
  `AppModel(rawForTest:)` in the shape of `Store(rawForTest:)` is what would unlock all of them.
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
- **Coverage gaps the test-honesty audit found and that are still open.** Each was reproduced by
  injecting the real defect and watching the suite stay green, so none of these is a guess. In
  the order they are worth doing:
  1. **`setNote` / `addTag` / `removeTag` have no assertion that they use `updateConfigQuiet`.**
     Routing all three through `updateConfig` instead — §8g's named trap, which stamps
     `configured = true, auto = false` and drops the song out of the `Return`/`Tab` sweep AND out
     of the pre-flight's `stillAuto` and `hookDefault` warnings, so a round nobody reviewed
     passes the handover check — leaves `--notetest` 66/66, `--tagtest` 89/89 and `--filtertest`
     25/25 all green. `--tagtest` already asserts exactly this property for `setTagColor`
     (`"เลือกสีแล้วเพลงไม่ถูกแตะ — configured false"`), so the pattern is known; it was never
     applied to the write path it protects. Structural cause: these suites build
     `Store(rawForTest:)` and never an `AppModel`.
  2. **`songsIn(_:)` has zero assertion coverage anywhere in the project.** Putting the tag
     filter inside it — which hands a round over missing its hidden questions, scores the review
     sweep against a view, and makes `✓ ยืนยันครบทุกเพลงในรอบนี้` a lie — leaves every suite
     green. §8g is honest that no headless check can prove the UI calls the right accessor, but
     its stated defence ("narrowing the handover requires typing `visibleSongs` somewhere it does
     not belong") only covers one direction; the other needs no `visibleSongs` at all. The fix is
     cheap: `songsIn` is a one-line pure filter and can be lifted to `Library` where a test
     reaches it.
  3. **`--roottest`'s 7 resolution-order assertions are skipped in exactly the configuration §5d
     was built for.** They sit behind `if AppPaths.looksLikeLibrary(programRoot)`, so they run
     here (27) and vanish on a `/Applications` install, a fresh clone or CI (20). Injecting §5d's
     own documented defect — `breadcrumb` checked before `beside` — is invisible in that state.
     Build the stand-in library in a fixture the test creates, so the section never depends on
     ambient state.
  4. **`--tagtest`'s hash guard passes by luck, 3 runs in 10.** With FNV-1a replaced by
     `hashValue` it failed 7 times and passed 3, because the assertion compares two `Store`s
     *within one process*, where the seed is constant. §12's own rule: a check that passes by
     luck is worse than no check. Pin a golden value — `tagColors[tagKey("ยุค 90")] == <const>`
     — which tests the hash rather than two runs of it.
  5. `--handoff`'s `✓ ผ่าน` is printed **unconditionally**, and it is one of the write-y flags so
     it is the least-run of the lot.
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
INTROPLAYER_DIAG=1 $BIN --palettetest # both themes: contrast, ladder, deutan ΔE — 195 assertions
INTROPLAYER_DIAG=1 $BIN --loudtest    # + the reveal lands on target, 12 assertions — §7a5
INTROPLAYER_DIAG=1 $BIN --autodetect  # Intro End / Hook guesses with their evidence
INTROPLAYER_DIAG=1 $BIN --guesstest   # clamps vs NaN/inf/1e19 + the admission rules per song
INTROPLAYER_DIAG=1 $BIN --snapshot    # writes a real snapshot; restores nothing, deletes nothing
INTROPLAYER_DIAG=1 $BIN --guessflow   # plays a song for real; RESTORES the song it touched
INTROPLAYER_DIAG=1 $BIN --artwork     # cover source per song (offline, makes no request)
INTROPLAYER_DIAG=1 $BIN --remodetest  # marker edits mid-playback: 3 cases, none may outlive Intro End
INTROPLAYER_DIAG=1 $BIN --takes       # running order: synthetic self-check + the real log
INTROPLAYER_DIAG=1 $BIN --timefmt     # typed-field parser
INTROPLAYER_DIAG=1 $BIN --overview    # strip data matches columnPeaks; caches stay independent
INTROPLAYER_DIAG=1 $BIN --notetest    # note: 66 assertions. Writes NOTHING — Store(rawForTest:)
INTROPLAYER_DIAG=1 $BIN --tagtest     # tags: 89 assertions, the registry, the chosen colour, the handover
INTROPLAYER_DIAG=1 $BIN --filtertest  # 25: filter + search cannot reach the handover/pre-flight
INTROPLAYER_DIAG=1 $BIN --incomingtest # receive sweep + setterName: 50 assertions, read-only
INTROPLAYER_DIAG=1 $BIN --focustest   # click-outside ends editing: 8 assertions, read-only
INTROPLAYER_DIAG=1 $BIN --logotest    # the logo memo holds, and invalidate re-reads: 7, read-only
INTROPLAYER_DIAG=1 $BIN --foldtest    # fold decisions + column/pane width arithmetic: 55, pure
INTROPLAYER_DIAG=1 $BIN --preflight   # the handover checklist
INTROPLAYER_DIAG=1 $BIN --updatecheck # semver compare + the configured feed (§15)
INTROPLAYER_DIAG=1 $BIN --updatestage # the in-app chain minus the swap (needs a feed) (§15)
INTROPLAYER_DIAG=1 $BIN --roottest    # data root: 27 assertions, temp fixtures, touches no setting
$BIN --version                        # ungated
$BIN --whereami                       # ungated — program folder, data folder, which fallback won

# the release path — no project data is touched, dist/ and a temp dir only
./native/release.sh --allow-dirty --no-download   # zip + dmg, every check must pass
./native/swap-test.sh                 # 29 assertions on the in-app swap helper
./native/dmg.sh --skip-build          # the disk image on its own, 11 checks on the MOUNTED image

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

**Since the DMG migration (§5d) the program and the questions are two different places**, so a
program swap cannot reach the questions even in principle. That is a much stronger version of what
this section used to claim, and it is what let ~600 lines of installer and 123 assertions retire.

| | | |
|---|---|---|
| **program** — replaced by an update | `/Applications/RGF Intro Player.app` (`AppPaths.programRoot`) | the release's |
| **seeded once, never overwritten** | `se/`, `brand/` — copied out of the bundle's `Resources/seed/` on first run, only if absent, and only present in a `--crew` build | `Seeding.run()` |
| **never touched** | `config.json`, `log.json`, `songs/` in the questions folder (`AppPaths.root`) | the only copy of the questions |

The middle row is the one that changed shape rather than meaning. §15's `SEED[]` promise was
"copied on a fresh install, never overwritten by an update", and the installer kept it by copying
out of the release zip. With nothing sitting next to the app, the files travel inside the bundle
and `Seeding` copies them out — **under exactly the same rule**, and still absent from every public
build, because `build.sh --with-payload` is the only thing that puts them there and
`release.sh --crew` is the only thing that passes it. §15 records the day `brand` joined `SEED[]`
and the logo went into a public GitHub release before anyone noticed; baking it into every bundle
would do that permanently instead of once.

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

An app cannot replace its own running bundle, so the last step is another process. That process is
`swap-app.sh`, which **travels inside the new bundle** — the version being installed brings its own
swap logic, so a fix to that logic ships with the release that needs it rather than depending on
whatever the operator already has.

The chain, and every step can refuse:

1. **Three refusals before anything is downloaded.** Not while `player.isPlaying` — the swap ends
   in quitting, and a song may be on camera. Not when `needsNewerOS`. Not from an unzipped release
   folder or the mounted image, where there is no install to update.
2. **Confirm**, through `confirmDestructive`, so Return and Space land on Cancel (§12).
3. **Download** to a fresh dir under the system temp root, so a crash mid-way leaves nothing in the
   operator's folder. Progress throttled to ~10 updates/s.
4. **Verify, three independent ways**, before anything is swapped: the zip's SHA-256 against the
   manifest's; the bundle and its `Contents/Resources/swap-app.sh` are present and executable; and
   then **the staged binary's `--version` must equal the manifest's version**. That last one is
   what makes a one-click update defensible, and it is not hypothetical — the first test of this
   chain used a manifest claiming 9.9.9 over a 1.1.0 zip and stopped there.
5. **Hand off and quit.** `Updater.apply` launches the staged helper detached with
   `--target <installed .app> --source <staged .app> --expect <version> --wait-pid <our pid>
   --relaunch`; `store.saveNow()` flushes first, because the debounced save would otherwise still
   be pending. The helper waits for that pid (bounded 30 s, plus 0.5 s for the terminate-time
   write), swaps, and relaunches.

**`target` is the installed `.app` bundle, not the folder holding it.** Handing a folder to
something whose job is `rm -rf` plus `cp -R` is how a program swap reaches the questions, and it is
the single most important difference from the installer this replaces.

**This path has no Gatekeeper step at all.** Quarantine is applied by whatever *downloads* a file,
not by the kernel; a zip written by this app's own `URLSession` carries no flag. A `.dmg` passed
around by hand still needs right-click → Open each time.

`_settings.lastRanVersion` closes the loop: rewritten on every save, so a difference on launch means
this is the first run of a new build — the only way the operator gets told the update *worked*.

### The swap helper (`native/swap-app.sh`)

~130 lines where the installer was ~600, because the questions are no longer in the blast radius.
In order, and the order is the point — everything that can refuse runs before anything moves, for
the reason §15 records about `--github`: a check placed after the destructive step turns a refusal
into damage.

1. Both ends are real `.app` bundles with a binary inside, and are not the same directory —
   compared with `-ef` (inode + device), because §15 records a string compare letting one directory
   through under two spellings and the installer installing over its own source.
2. The target's parent is writable. A standard (non-admin) user cannot write `/Applications`, and
   saying so beats failing halfway.
3. The staged binary answers `--version`, and it matches `--expect`.
4. `--wait-pid` disappears (bounded 30 s), then nothing is still running from the target — matched
   with `grep -F` on `ps` output, never `pgrep -f`, because §12 records a folder named
   `IntroPlayer (ใหม่)` making pgrep's pattern uncompilable and the check failing **open**.
5. The old bundle moves **aside as a sibling** (`<name>.app.old-<stamp>`), which is a rename on the
   same filesystem by construction and cannot half-copy. The destination is then asserted gone
   before `cp -R`, because §15 records `cp -R src dst` copying *into* a dst that survived an `rm`
   and nesting the new bundle inside the old one while reporting success.
6. Quarantine stripped from what was installed, never from the folder around it.
7. **The installed app is asked its version before success is claimed**, and anything else rolls
   back.

```bash
./native/swap-test.sh     # 29 assertions, 6 cases, real directories, production script unmodified
```

Each refusal asserts the **reason**, not just a non-zero exit: several of these cases would exit 1
for a completely different reason — a typo in a path, a missing fixture — and the suite would still
read green. §12 records that shape twice.

### Cutting a release

```bash
./native/release.sh                    # build + package the version in ./VERSION
./native/release.sh --download <url>   # also fill in manifest.json's download field
./native/release.sh --skip-build       # package the bundle as it stands
./native/release.sh --allow-dirty      # package from a tree with uncommitted edits
./native/release.sh --crew             # build the bundle WITH the stings and the logo inside
./native/dmg.sh                        # the disk image on its own (release.sh builds it too)
```

**Two artifacts, one build, different readers.**

| | who reads it | what it holds |
|---|---|---|
| `IntroPlayer-<ver>.dmg` | a person installing for the first time | the app, a `/Applications` symlink, `อ่านก่อน.txt` |
| `IntroPlayer-<ver>.zip` | the in-app updater | the bundle, nothing else |

The zip used to carry `server.py`, `index.html`, `ตรวจสอบเครื่อง.command`, `start.command`,
`VERSION`, the installer, `se/` and `brand/`. All of that either moved inside the bundle (§5d) or
stopped being something a release has to *place*. `release.sh` builds the image with
`dmg.sh --skip-build`, from the exact bundle the zip was just verified against — never from a
rebuild, for the same byte-reproducibility reason the pre-flight ordering exists for.

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
- **It asserts the BUNDLE's own contents**, which is what the retired `SHIP[]`-vs-`PROGRAM[]`
  cross-check turned into: the swap helper is present and executable (the updater refuses a zip
  without it, and a release that cannot be installed is worse than no release), the seeded
  diagnostic is present and executable, and the payload is absent — or, under `--crew`, present.
  **Inverted rather than skipped**, so a crew artifact that LOST a sting fails as hard as a public
  one that gained it: a check that switches off is a check that stops covering the case it was
  added for. `dmg.sh` asserts the same list against the mounted image, because permissions and
  bundle structure are what survive or fail to survive the packaging — checking the folder you
  just built proves nothing about that.

### v1.5.0 ships the `.dmg` ONLY, and that is a one-release exception

**A 1.4.x machine cannot take the in-app update to 1.5.0, and left alone it would try.** Measured
on a real 1.4.2 build (`git worktree` at that commit, its own `config.json` pointing at the live
feed), not reasoned about:

1. 1.4.2's GitHub feed filters the release's assets down to `.zip` and ignores the `.dmg`;
2. so it reported `→ มีเวอร์ชั่นใหม่ 1.5.0` and offered **อัปเดตเลย**;
3. pressing it downloads 3.1 MB, verifies the checksum, unpacks, finds the bundle — and then
   1.4.2's `stage()` does `guard fm.isExecutableFile(ติดตั้ง-อัปเดต.command)`, which the 1.5.0 zip
   does not contain, and throws **"ในชุดอัปเดตไม่มีตัวติดตั้ง"**.

The working app survives (that check runs before the swap), but it is a button that dies, with a
message that sounds like the release is broken — while the release notes say to use the `.dmg`.
The banner contradicts the notes.

So the `.zip` asset was **deleted from the v1.5.0 release by hand**. With no `.zip` attached, the
old client's check *throws* (`release v1.5.0 ไม่มีไฟล์ .zip แนบมา`), `updateInfo` stays nil,
`showUpdateNotice` is therefore false, and §15's rule that a failed check never toasts on the
automatic pass means **old machines go quiet instead of offering something that fails**. Verified
on the same 1.4.2 build after the deletion.

> **Future releases must carry the `.zip` again.** 1.5.0+ clients fetch the zip — the `.dmg` is for
> people, the `.zip` is for the updater. `release.sh --github` uploads both by default and needs no
> change; v1.5.0 is special only because the asset was removed manually *after* publishing. Do not
> repeat it. Forgetting to put it back is the kind of one-off exception that silently stops every
> machine from ever updating again.

The cost, stated: **1.4.x machines migrate by hand, once** — download the `.dmg`, drag to
Applications, open. The new app finds their existing questions folder through the breadcrumb (§5d)
with nothing to answer. Accepted because the install base is a handful of machines; with more of
them, the better answer is a migration shim in the zip that the old builds would find and run.

> Measured in passing: **GitHub's unauthenticated API caches a release for roughly a minute.** The
> first re-check after deleting the asset still reported the old `.zip` URL, from GitHub rather
> than from us — `Updater` already uses `.reloadIgnoringLocalCacheData` on an `ephemeral` session.
> Not a defect (the check runs once per launch), but worth knowing before somebody goes looking for
> a caching bug that is not there.

### The installer is retired

`native/installer.command` and `native/installer-test.sh` are **deleted**. Everything they did —
backups of `config.json`/`log.json`, the checked `rm`, the full rollback, the `mkdir` lock, the
`LEGACY[]` bundle list, `valid_target`, the quarantine strip, the seeding pass — existed because
the bundle it replaced sat in the same folder as the operator's questions. With the app in
`/Applications` it cannot reach them, and the remaining job is `swap-app.sh` above.

What was load-bearing and survives, in a smaller place:

| the installer's rule | where it lives now |
|---|---|
| never swap while the app is running | `swap-app.sh` step 4, `grep -F` on `ps` |
| prove the installed app runs before claiming success | `swap-app.sh` step 7 |
| roll back on any failure | `swap-app.sh`, sibling move + asserted-gone destination |
| don't aim at a download or a release folder | `AppPaths.looksLikeLibrary` (§5d) |
| `se/` and `brand/` seeded once, never overwritten | `Seeding.run()` (§5d) |
| find the folder without asking | `AppPaths.resolveRoot`, breadcrumb step (§5d) |
| the release ships what the installer lands | the bundle-content checks in `release.sh`/`dmg.sh` |

That last row is the one to watch. The `SHIP[]`-vs-`PROGRAM[]` cross-check is gone with its other
half, and what replaced it asserts the **bundle's own contents** — the swap helper, the seeded
diagnostic, and the presence or absence of the payload. Those are now the things that can go stale
in place, and §15's lesson stands: a rule that names its subjects literally stops covering the
subject that arrives later.

> **Not solved: signing and notarization.** Unchanged by any of this, and the DMG does not make it
> worse — a `.dmg` from a browser is quarantined exactly like the zip was, so a first install needs
> right-click → Open (or Privacy & Security → "Open Anyway"). What the DMG *does* remove is the
> per-release `.command` dance, because the in-app update path has no Gatekeeper step at all.
> `อ่านก่อน.txt` on the image says all of this in Thai.

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
