import Combine
import AppKit
import SwiftUI

func fmtTime(_ t: Double) -> String {
    let v = t.isFinite && t > 0 ? t : 0
    return String(format: "%d:%02d", Int(v) / 60, Int(v) % 60)
}
func fmtSec(_ t: Double) -> String { String(format: "%.2fs", t) }

/// `1:23.45` — the format the typed marker fields use. The hundredths are not decoration: that is
/// the precision markers are stored at, and the precision the waveform can no longer show once the
/// view is zoomed out.
/// `+M:SS`, or `+H:MM:SS` past an hour. Time since the taping's first take — the number that
/// lines up with a camera whose timecode starts at zero.
func fmtElapsed(_ sec: Double) -> String {
    let v = Int(max(0, sec).rounded())
    let h = v / 3600, m = (v % 3600) / 60, s = v % 60
    return h > 0 ? String(format: "+%d:%02d:%02d", h, m, s) : String(format: "+%d:%02d", m, s)
}

/// "1 ชม 26 นาที" / "48 นาที" / "40 วิ" — a span in words, for the session header.
/// Days matter: the real log spans them, and "2230 ชม" is not a readable number.
func fmtSpanThai(_ sec: Double) -> String {
    let v = Int(max(0, sec).rounded())
    if v < 60 { return "\(v) วิ" }
    let d = v / 86400, h = (v % 86400) / 3600, m = (v % 3600) / 60
    if d > 0 { return h > 0 ? "\(d) วัน \(h) ชม" : "\(d) วัน" }
    if h > 0 { return m > 0 ? "\(h) ชม \(m) นาที" : "\(h) ชม" }
    return "\(m) นาที"
}

func fmtClock(_ t: Double) -> String {
    let v = max(0, t.isFinite ? t : 0)
    let cs = Int((v * 100).rounded())
    return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
}

/// Accepts `83.5`, `1:23`, `1:23.4`, `1:23.45` — and nothing else. Returns nil rather than
/// guessing, so a typo leaves the marker where it was instead of moving it to 0. `1:75` is
/// rejected too: silently reading it as 2:15 is the kind of help nobody asked for.
func parseClock(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    let parts = t.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 1 {
        guard let v = Double(parts[0]), v.isFinite, v >= 0 else { return nil }
        return v
    }
    guard parts.count == 2,
          let m = Double(parts[0]), let sec = Double(parts[1]),
          m.isFinite, sec.isFinite, m >= 0, sec >= 0, sec < 60 else { return nil }
    return m * 60 + sec
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                saveFailureBar
                // Order is what the operator must act on, outward. A round waiting to be
                // accepted is work; a new version is news. Two informational banners used to sit
                // above it and push it furthest from the header.
                ReceiveBanner()
                NewsBanner()
                HStack(spacing: 0) {
                    // The log REPLACES the song list rather than covering the app. As a sheet it
                    // hid the song it was describing, which is why `1`/`2`/`I`/`O`/`H` had to be
                    // blocked while it was open and why Space had to be special-cased back in.
                    // Side by side, the transport and the current song stay visible and live, so
                    // none of that is necessary.
                    if model.showLog { LogPanel() } else { SongListView() }
                    CenterView()
                    SetupPanel()
                }
            }
            .onAppear { model.setWide(geo.size.width >= 1900) }
            .onChange(of: geo.size.width) { w in model.setWide(w >= 1900) }
        }
        .background(Palette.bg)
        // Follows the setting rather than being nailed to dark. Both halves are needed:
        // `NSApp.appearance` (set in `applyTheme`) resolves Palette's dynamic NSColors and the
        // window chrome; this drives SwiftUI's own environment. Set only one and AppKit chrome
        // and SwiftUI content can land on different themes.
        .preferredColorScheme(model.theme == .system ? nil
                              : (model.theme == .dark ? .dark : .light))
        // No view-owned Timer. `ContentView` is re-initialised on every model publish, so a
        // `Timer.publish` stored here was recreated and resubscribed each time — measured at 1 tick
        // in 2 s while the player published at 50 Hz, which left `followPlayhead()` dead exactly
        // when it is needed. The playhead now follows from `Player.tick` instead (see AppModel).
        .onAppear(perform: installKeyMonitor)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                model.rescan()
                model.detectIncoming()
            }
        // `installKeyMonitor` guards on nil, so failing to clear this left every shortcut
        // permanently dead after any disappear/reappear of the same view identity.
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
        }
        .sheet(isPresented: $model.showHandover) { HandoverPanel() }
        .sheet(isPresented: $model.showAbout) { AboutPanel() }
        .sheet(isPresented: Binding(get: { model.importPlan != nil },
                                    set: { if !$0 { model.importPlan = nil } })) { DiffPanel() }
        .onAppear { model.detectIncoming() }
        // Top, not bottom. The buttons whose results these messages report all live in the
        // header strips at the top; at the bottom of a 2560x1080 window the reply to a click
        // landed ~1200 px from the button, which read as "nothing happened".
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t).font(Typo.font(12)).foregroundStyle(Palette.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Palette.panel2).clipShape(Capsule())
                    .overlay(Capsule().stroke(Palette.line))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                    .padding(.top, 54)
                    // INSIDE the overlay closure, on the toast itself. Attached to the `.overlay`
                    // modifier instead, it disables hit testing for the ENTIRE view it modifies —
                    // i.e. the whole app: nothing anywhere was clickable.
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            // The programme's logo, when `brand/logo.png` exists. What used to sit here was a
            // hardcoded 9 pt GREEN dot with no state behind it — decoration, and a live §6d
            // violation: green has exactly one meaning in this app, "a human answered
            // correctly", and spending it on an ornament is how a palette stops meaning
            // anything. It was not even a `Palette` value. Replacing it fixes both at once.
            if let logo = ShowLogo.prepared {
                // The bitmap is already exactly `size x backingScale` pixels, so this frame is
                // 1:1 and SwiftUI has no rescaling left to do. `.interpolation(.high)` stays
                // only to cover the case where the window is dragged to a display of a
                // different scale than the one resolved at launch.
                Image(nsImage: logo.image)
                    .resizable().interpolation(.high)
                    .frame(width: logo.size.width, height: logo.size.height)
                    .accessibilityHidden(true)
            }
            // `Palette.onHeader`, not `.white`. They are the same value, but this bar is dark
            // red in BOTH themes, so what sits on it must be a FIXED-light role — §6d records
            // the save-failure text measuring 1.2:1 in light because it used a theme-flipping
            // colour here.
            Text("RGF INTRO PLAYER").font(Typo.font(15, .bold)).foregroundStyle(Palette.onHeader)
            Spacer()
            if model.reviewRemaining > 0 {
                headerChip("ยังต้องตรวจ \(model.reviewRemaining)", Palette.cyan) {
                    model.nextNeedingReview()
                }
            }
            // Clicking it opens the diff the setter would see — the operator's own audit of what
            // they changed after the handover.
            if model.onsiteFieldCount > 0 {
                headerChip("✎ แก้ที่กอง \(model.onsiteFieldCount) จุด", Palette.amber) {
                    model.flash("แก้ที่กอง \(model.onsiteSongs.count) เพลง — ดูค่าเดิมได้ที่แผงขวา")
                }
            }
            Button { model.openHandover() } label: {
                Text("📤 ส่งต่อ")
                    .font(Typo.font(12, .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(corner: 7))
            .background(Color.black.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.white)
            Button { model.showLog.toggle() } label: {
                Text("📋 Log\(logCount > 0 ? " (\(logCount))" : "")")
                    .font(Typo.font(12, .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(corner: 7))
            .background(Color.black.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.white)
            .pulseTarget(PulseID.log, corner: 7)
            // One source of truth. The header used to read `store.saveState`, which sticks on
            // "saved ✓" forever, so a read-only volume or a blocked folder looked perfectly fine.
            Text(model.saveState)
                .font(.system(size: 12, weight: model.store.saveFailed ? .bold : .regular))
                .foregroundStyle(model.store.saveFailed ? Palette.onHeaderWarn
                                 : Palette.onHeader.opacity(0.85))
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Palette.header)
    }

    /// A failed save was 12pt amber text in the header — the same colour as "played" and the
    /// disarmed state, at the smallest size in the app, for the one condition that silently
    /// loses a whole day of markers. It should be impossible to be in the room and miss it.
    @ViewBuilder private var saveFailureBar: some View {
        if model.store.saveFailed {
            HStack(spacing: 12) {
                Text("⚠ บันทึกไม่สำเร็จ").font(Typo.subhead).foregroundStyle(Palette.red)
                    .fixedSize()
                Text(model.store.saveState).font(Typo.caption).foregroundStyle(Palette.text)
                Text("— เครื่องนี้อาจเขียนไฟล์ไม่ได้ (ดิสก์เต็ม / สิทธิ์โฟลเดอร์) marker ที่แก้ไว้จะหายตอนปิดแอป")
                    .font(Typo.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button { model.store.saveNow() } label: {
                    Text("ลองบันทึกอีกครั้ง").font(Typo.label)
                        .padding(.horizontal, 12).frame(minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 7))
                .background(Palette.red.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(Palette.text)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            // A FIXED dark plum under theme-aware text measured 1.25:1 in light — the
            // explanation and the retry button both unreadable, on the one condition that
            // silently loses a day of markers. Same mistake as the header bar, one screen over.
            .background(Palette.tintBad)
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.red).frame(height: 1).allowsHitTesting(false)
            }
        }
    }

    private func headerChip(_ t: String, _ c: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(12, .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 7))
        .background(c.opacity(0.26))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(c.opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(.white)
    }

    private var logCount: Int {
        model.logStore.events.filter {
            (model.logAllRounds || $0.playlist == model.currentPlaylist) && model.isCurrentSession($0)
        }.count
    }

    /// Physical key codes, not characters. The web version silently lost every letter shortcut
    /// whenever the Thai input source was active; `keyCode` is layout-independent.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
            let sheetUp = model.showHandover || model.importPlan != nil || model.showAbout

            // Command shortcuts first — checked before the modifier bail below
            if e.modifierFlags.contains(.command) {
                // A focused text field owns its own Cmd+Z, and this branch used to sit above
                // EVERY guard — the text-view check, `sheetUp`, and `isARepeat`. So "undo my
                // paste" in a text field ran `model.undo()` instead: it pops a MARKER snapshot,
                // can call `select()` and change the loaded song under a full-window sheet, and
                // re-applies gain mid-playback. Its only feedback is a toast, which a sheet
                // covers — so nothing appeared to happen, and the natural response (hold the
                // keys) walked the entire 40-deep undo stack in about a second.
                if typing { return e }
                if e.isARepeat { return nil }
                switch e.keyCode {
                case 15: model.rescan(); return nil                              // Cmd+R
                case 6:  model.undo(); return nil                                // Cmd+Z
                // SwiftUI presents one sheet per view, so firing this with a sheet already up
                // set `showHandover` true with nothing on screen — and `sheetUp` then stayed
                // true, keeping 1/2/I/O/H blocked until the Esc cascade was walked twice.
                case 14: if !sheetUp { model.openHandover() }; return nil         // Cmd+E
                default: return e
                }
            }
            if e.modifierFlags.intersection([.control, .option]).isEmpty == false { return e }

            if typing {
                // Typing. But "a text field holds focus in the MAIN window" is a state the typed
                // marker fields introduced, and in it the take must still be driveable: nobody
                // types a time while a question is on air, so while playback is running the
                // numeric fields do not get to own these keys.
                //
                // Space, because a focus left in a field must never be why a buzz cannot be
                // stopped. `1`/`2`, because a buzz that cannot be SCORED is the same failure —
                // no sting, and no log event, which is the one file the edit room works from
                // (§8d).
                //
                // This is NOT gated on `sheetUp` any more. §11 used to exempt sheets on the
                // grounds that the setter-name field takes real text — written when every sheet
                // field was a name. The About sheet's feed field broke it: one click on the
                // version label mid-take, one click into the field, and Space typed a space
                // while a contestant buzzed. That is §12's log-pane defect restored through
                // another door. A space character that does not arrive is recoverable; a take is
                // not, and a stray log event has `↩ ยกเลิกรายการล่าสุด`.
                if model.player.isPlaying {
                    switch e.keyCode {
                    case 49:
                        model.player.toggleStart(config: model.config())
                        return nil
                    case 18, 83:
                        model.score("correct"); model.pulse(PulseID.correct); return nil
                    case 19, 84:
                        model.score("wrong"); model.pulse(PulseID.wrong); return nil
                    default: break
                    }
                }
                // Esc hands the keyboard back to the app, always, from any field.
                //
                // It used to fall through to `return e` here, so the only documented way out of
                // a field was the mouse: Return commits and releases, but there was nothing for
                // "I clicked in here and now every letter I press is text". On a shoot the
                // keyboard IS the instrument — S, R, P, I/O/H, L all die while a field holds
                // focus, and the note field is the first one in the window that makes typing
                // letters look like it is working.
                //
                // Resigning fires each field's `onChange(of: focused)`, which is where blur
                // cancels uncommitted text (§11) — so Esc keeps exactly the meaning it has
                // everywhere else here: discard, do not write.
                if e.keyCode == 53 {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return e
            }
            if e.keyCode == 53 {                                                 // Esc
                if model.pending != nil { model.cancelPending(); return nil }
                if model.importPlan != nil { model.importPlan = nil; return nil }
                if model.showAbout { model.showAbout = false; return nil }
                if model.showHandover { model.showHandover = false; return nil }
                if model.showLog { model.showLog = false; return nil }   // pane, not a sheet
                return e
            }
            // With the handover or diff sheet up, `1`/`2` would play an SE and append a REAL log
            // event, and I/O/H would move markers on a song nobody can see. Space still passes
            // through as PAUSE only: a contestant can buzz at any moment, and being unable to stop
            // the audio is worse than any of the above.
            //
            // The log is NOT in this set any more — it is a pane beside the song, so every key
            // keeps its normal meaning while it is open.
            if sheetUp {
                if e.keyCode == 49, model.player.isPlaying {
                    model.player.toggleStart(config: model.config())
                    return nil
                }
                return e
            }
            if e.isARepeat { return nil }
            let c = model.config()
            // every shortcut flashes the button it maps to, so a key press looks like a click
            switch e.keyCode {
            case 49: model.player.toggleStart(config: c); model.pulse(PulseID.start)
            // Reveal does NOT mark the song used — the GM hammers it while hunting for the hook
            // during setup. Only Correct/Wrong count as "this question aired".
            case 15: model.cancelPending(); model.player.reveal(config: c); model.pulse(PulseID.reveal)
            case 1:  model.cancelPending(); model.player.reset(config: c); model.pulse(PulseID.reset)  // S
            case 37: model.showLog.toggle(); model.pulse(PulseID.log)                      // L
            case 18, 83: model.score("correct"); model.pulse(PulseID.correct)              // 1
            case 19, 84: model.score("wrong"); model.pulse(PulseID.wrong)                  // 2
            // Instant while stopped, confirm-on-second-press while playing — see requestMark.
            case 34: model.requestMark(.introStart)                                        // I
            case 31: model.requestMark(.introEnd)                                          // O
            case 4:  model.requestMark(.hook)                                              // H
            // `E` is the most consequential key in the app: it disarms the intro-end stop, and
            // keyCode 14 sits next to `R` (15).
            case 14: model.requestMark(.ignoreEnd); model.pulse(PulseID.ignoreEnd)
            // `T` is a second binding for Played, asked for because `P` was not discoverable:
            // the SETUP button showed no key and the transport button read "Mark Played" in
            // English among Thai labels. Both keys stay — `P` is mnemonic and is what any
            // existing muscle memory uses.
            //
            // **`T` is keyCode 17, one key from `R` (15), which puts the chorus on camera.** It
            // is bound anyway, and the two-press rule (§11) is deliberately NOT applied, because
            // it would not help: the mis-press that costs something is reaching for T and
            // hitting R, and guarding T only guards the harmless direction. Toggling Played
            // writes no log event, airs nothing and is undone by pressing the key again — so the
            // key itself needs no guard, and the adjacency is a thing to know rather than a
            // thing to fix here. If this ever bites, move Played off the QWERTY row; do not
            // guard `R`, which §11 explains at length.
            case 35, 17: model.updateConfigQuiet { $0.played.toggle() }; model.pulse(PulseID.played)
            case 36: model.confirmCurrent()                                      // Return
            case 48: model.nextNeedingReview()                                   // Tab
            case 46: model.cycleFocusMarker()                                              // M
            case 6:  model.zoomIntro(); model.pulse(PulseID.zoomIntro)                     // Z
            case 27, 78: model.zoomBy(1.6); model.pulse(PulseID.zoomOut)                   // -
            case 24, 69: model.zoomBy(1 / 1.6); model.pulse(PulseID.zoomIn)                // =
            case 29, 82: model.zoomFit(); model.pulse(PulseID.zoomFit)                     // 0
            case 125: model.cancelPending(); model.move(by: 1)                 // down
            case 126: model.cancelPending(); model.move(by: -1)                // up
            case 33: model.cancelPending(); model.moveColumn(by: -1)           // [
            case 30: model.cancelPending(); model.moveColumn(by: 1)            // ]
            // Shift turns the pan keys into a 0.01 s nudge of the focused marker — the precision
            // neither the ± buttons (0.1 s) nor a drag at a readable zoom can reach.
            case 123:
                if e.modifierFlags.contains(.shift) { model.nudgeFocused(by: -AppModel.nudgeStep) }
                else { model.pan(by: -model.viewSpan * 0.25) }
            case 124:
                if e.modifierFlags.contains(.shift) { model.nudgeFocused(by: AppModel.nudgeStep) }
                else { model.pan(by: model.viewSpan * 0.25) }
            default: return e
            }
            return nil
        }
    }
}

// MARK: - song list

struct SongListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                if model.showPlaylistPicker {
                    Picker("", selection: Binding(
                        get: { model.currentPlaylist },
                        set: { model.setPlaylist($0) })) {
                        ForEach(model.playlists, id: \.self) { p in
                            let n = model.songsIn(p).count
                            Text("\(p.isEmpty ? Library.rootLabel : p)  (\(n))").tag(p)
                        }
                    }
                    .labelsHidden().font(Typo.font(12))
                }
                HStack {
                    // The counts describe the ROUND and stay unfiltered on purpose — the strip
                    // below is what reconciles them with the rows (§8g).
                    Text("Songs (\(model.songsIn(model.currentPlaylist).count)) · เล่นแล้ว \(playedCount)")
                        .font(Typo.font(12)).foregroundStyle(Palette.muted)
                    Spacer()
                    tagFilterMenu
                }
                // Rescan stays a button: it is the safe one and the one pressed most (a round
                // dropped in while the app is open is the commonest real complaint). The two that
                // throw work away move behind `⋯`, out of slamming range of it — they were three
                // identical 11pt pills in a row, one of which can wipe a taping's badges.
                HStack(spacing: 6) {
                    smallButton("⟳ อ่านโฟลเดอร์ใหม่") { model.rescan(); model.flash("อ่าน songs/ ใหม่แล้ว") }
                    // The version lives where support calls start: "which one are you on" is
                    // the first question for any report from the field, and an operator has to
                    // be able to answer it without being walked through a menu. Clickable,
                    // because the next question is always "which folder".
                    //
                    // LEFT of the Spacer, not right of it: this is the string read aloud on the
                    // phone, so it should be where the docs can describe it simply — and it puts
                    // the whole pane width between it and the `⋯` that holds the two actions
                    // which throw work away (they were 6 pt apart, ~2 mm at 81 PPI).
                    Button { model.showAbout = true } label: {
                        Text(AppVersion.display)
                            .font(Typo.font(11, latinOnly: true))
                            // `muted` (8.06:1) at rest, not `dim` (4.80:1). The moment somebody
                            // squints at this number is the support call — i.e. the resting
                            // state — so the dimmest tier in the app was exactly backwards.
                            .foregroundStyle(model.updateInfo != nil ? Palette.cyan : Palette.muted)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(corner: 5))
                    .help("เวอร์ชั่น / โฟลเดอร์ข้อมูล / อัปเดต")
                    Spacer(minLength: 0)
                    // One tap = the other theme. Deliberately NOT a three-way cycle through
                    // "ตามระบบ": a display setting that can change by itself is the last thing
                    // an operator needs mid-taping, so following the system is opt-in from
                    // About. The glyph shows what you would GET, not what you have — the same
                    // way every OS does it, because a button that shows the current state reads
                    // as a status light and gets ignored.
                    Button { model.toggleTheme() } label: {
                        Text(model.effectiveDark ? "☀" : "☾")
                            .font(Typo.font(13, latinOnly: true))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(corner: 5))
                    .help(model.effectiveDark ? "สลับเป็นธีมสว่าง" : "สลับเป็นธีมมืด")
                    Menu {
                        Button("↺ รีเซ็ตเล่นแล้ว — เริ่มถ่ายรอบใหม่") { resetPlayedFlow() }
                        Button("🗑 ล้างเพลงเก่า\(model.orphanCount > 0 ? " (\(model.orphanCount))" : "")") {
                            pruneFlow()
                        }
                        .disabled(model.orphanCount == 0)
                        Divider()
                        // Needs the internet, so it lives with the other deliberate actions
                        // rather than on the toolbar: on a show day nothing in this app should
                        // touch the network by accident (§1).
                        // While it runs the item becomes the way to STOP it: a round of 60
                        // with no embedded art is over three minutes of requests.
                        Button(model.coverFetching
                               ? "■ หยุดดึงปก (\(model.coverProgress))"
                               : "🖼 ดึงปกเพลงของรอบนี้ (ต้องต่อเน็ต)") {
                            if model.coverFetching { model.cancelCoverFetch() }
                            else { model.fetchCoversForRound() }
                        }
                        Divider()
                        Button("ℹ เกี่ยวกับ / เวอร์ชั่น \(AppVersion.short)") { model.showAbout = true }
                    } label: {
                        // Sized INSIDE the label: an outer `.frame` leaves the Menu's own control
                        // at its intrinsic ~14pt glyph width, centred in a dead 38pt pill (§6c).
                        Text("⋯").font(Typo.font(13, .semibold))
                            .frame(width: 38, height: 26)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .background(Palette.panel2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line)
                        .allowsHitTesting(false))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help("รีเซ็ตสถานะเล่นแล้ว / ล้างข้อมูลเพลงที่ไม่มีไฟล์")
                }
            }
            .padding(10)
            .background(Palette.panel)
            Divider().overlay(Palette.line)

            tagFilterStrip

            if model.isWide {
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        ColumnView(index: i)
                        if i < 2 { Divider().overlay(Palette.line) }
                    }
                }
            } else {
                // Narrow: one scroller for the whole list, columns become section headers.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(0..<3, id: \.self) { i in
                                Section {
                                    ForEach(model.visibleSongs(column: i), id: \.self) {
                                        SongRow(path: $0)
                                    }
                                } header: {
                                    ColumnHeader(index: i, count: model.visibleSongs(column: i).count)
                                }
                            }
                        }
                    }
                    .onChange(of: model.current) { cur in
                        guard let cur else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(cur, anchor: .center) }
                    }
                    // The log PANE unmounts this list, so its scroll offset is gone when it comes
                    // back while `current` has not changed — closing the log left a 60-song round
                    // showing track 1 with the selection off-screen. A sheet unmounted nothing.
                    .onAppear { if let c = model.current { proxy.scrollTo(c, anchor: .center) } }
                }
            }
        }
        .frame(width: model.isWide ? 780 : 300)
        .background(Palette.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
    }

    /// Picking the tag to narrow to. A `Menu`, so it costs no height in a pane whose scroller is
    /// the flexible child — and it sits in the counts row, the width of the pane away from the
    /// `⋯` that holds the two actions which throw work away (§12).
    ///
    /// Only tags present in THIS round are offered, so a pick can never produce an empty list.
    @ViewBuilder
    private var tagFilterMenu: some View {
        let counts = model.tagCounts(inRound: model.currentPlaylist)
        if !counts.isEmpty {
            Menu {
                Button("ทุกเพลงในรอบนี้") { model.clearTagFilter() }
                Divider()
                ForEach(counts, id: \.tag) { c in
                    Button("\(Store.tagKey(c.tag) == Store.tagKey(model.tagFilter) ? "✓ " : "")"
                           + "\(c.tag)  (\(c.count))") {
                        model.setTagFilter(c.tag)
                    }
                }
            } label: {
                // Spelled out rather than "⌕ แท็ก". The menu only exists once the round HAS a
                // tag, so the first person to use tags has never seen this control before and
                // the shortest possible label is the worst possible one.
                Text(model.tagFilter.isEmpty ? "⌕ กรองตามแท็ก" : "⌕ \(model.tagFilter)")
                    .font(Typo.font(11))
                    .foregroundStyle(model.tagFilter.isEmpty ? Palette.muted : Palette.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(model.tagFilter.isEmpty ? Palette.panel2 : Palette.tintSelect)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line)
                .allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help("กรองรายการตามแท็ก — ไม่กรองตัวเลขหัวข้อ การส่งต่อ หรือรอบตรวจ")
        }
    }

    /// **A filter that does not say what it is hiding is indistinguishable from missing files.**
    /// That is not hypothetical: §8c records "the app can't find my songs", reported from real
    /// use, for a round that was merely not the remembered one. So this strip states the tag, the
    /// count it hides, and carries its own way out.
    ///
    /// It takes real height — unlike the note box, that is safe here: this pane's flexible child
    /// is the song scroller, which simply gets shorter. `CenterView`'s is the waveform, with a
    /// floor (§15).
    ///
    /// `tintSelect`, which is the selection emphasis already used by the active column header,
    /// not a hue. §6d gives every hue one meaning and "the list is narrowed" is not one of them
    /// — amber in particular means the intro-end stop is not armed, and nothing else.
    @ViewBuilder
    private var tagFilterStrip: some View {
        if !model.tagFilter.isEmpty {
            HStack(spacing: 8) {
                Text("⌕ กรอง: \(model.tagFilter)")
                    .font(Typo.font(12, .semibold)).foregroundStyle(Palette.tintSelectText)
                Text("เห็น \(model.visibleSongs(model.currentPlaylist).count) "
                     + "จาก \(model.songsIn(model.currentPlaylist).count) · ซ่อนอยู่ \(model.tagFilterHidden)")
                    .font(Typo.font(11)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button { model.clearTagFilter() } label: {
                    Text("✕ เลิกกรอง").font(Typo.font(11))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 6))
                .foregroundStyle(Palette.text)
                .background(Palette.panel2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line)
                    .allowsHitTesting(false))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Palette.tintSelect)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
    }

    private func resetPlayedFlow() {
        let used = model.usedInRound
        guard used > 0 else {
            model.flash("ยังไม่มีเพลงที่ใช้ไปในรอบนี้ — ไม่มีอะไรต้องล้าง")
            return
        }
        guard confirmDestructive(
            title: "เริ่มถ่ายรอบใหม่?",
            body: "จะล้างสถานะ \"เล่นแล้ว\" และป้าย ✓/✗ ของ \(used) เพลง "
                + "ในรอบ \(Library.label(model.currentPlaylist)) "
                + "(log เก่ายังเก็บไว้ครบ ไม่ได้ลบ)",
            ok: "เริ่มรอบใหม่") else { return }
        model.flash(model.resetPlayed())
    }

    private func pruneFlow() {
        guard model.orphanCount > 0 else { model.flash(model.pruneOrphans()); return }
        guard confirmDestructive(
            title: "ลบข้อมูลเพลงที่ไม่มีไฟล์แล้ว?",
            body: "จะลบ \(model.orphanCount) รายการที่หาไฟล์ใน songs/ ไม่เจอ — "
                + "ถ้าเพลงพวกนั้นแค่ถูกย้ายโฟลเดอร์ มาร์กเกอร์จะหายถาวร",
            ok: "ลบ") else { return }
        model.flash(model.pruneOrphans())
    }

    private var playedCount: Int {
        model.songsIn(model.currentPlaylist)
            .filter { model.store.config(for: $0).played || model.status(of: $0) != nil }.count
    }

    private func smallButton(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(11)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                // .plain hit-tests the glyphs only — without this the padding is dead space
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ColumnHeader: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(Library.columnLabels[index]).font(Typo.font(12, .bold))
                .foregroundStyle(model.activeCol == index ? Palette.tintSelectText : Palette.text)
            Text("(\(count))").font(Typo.font(11)).foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(model.activeCol == index ? Palette.tintSelect : Palette.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct ColumnView: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let list = model.visibleSongs(column: index)
        VStack(spacing: 0) {
            ColumnHeader(index: index, count: list.count)

            // ScrollViewReader: ↑/↓ move the selection without scrolling, so past ~20 songs the
            // GM was navigating blind — the highlighted row was off-screen.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if list.isEmpty {
                            Text("—").font(Typo.font(11)).foregroundStyle(Palette.muted)
                                .padding(.vertical, 18)
                        }
                        ForEach(list, id: \.self) { s in SongRow(path: s) }
                    }
                }
                .onChange(of: model.current) { cur in
                    guard let cur, list.contains(cur) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(cur, anchor: .center) }
                }
                // See the narrow layout's note: the log pane unmounts the list.
                .onAppear {
                    if let c = model.current, list.contains(c) { proxy.scrollTo(c, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stops the window from opening with the keyboard pointed at a text field.
///
/// When a window is first placed on screen AppKit gives first responder to
/// `initialFirstResponder`, and when that is nil it selects the first view in the key-view
/// loop instead. In this window that is now the SETUP panel's note field, so the app opened
/// with every letter shortcut — S, R, P, I/O/H, L, Z, M — typing instead of acting. The note
/// is the first field here where typing letters LOOKS like it is working, so nothing on
/// screen said the transport was dead; reported from the first real install, by someone who
/// had clicked nothing.
///
/// The fix is at the window, not in the field: the field must stay focusable by a click or
/// §11's contract (Return commits, blur cancels) has nothing to hang on. Pointing
/// `initialFirstResponder` at a view that refuses first responder is what makes AppKit leave
/// the window itself holding it.
///
/// `makeNSView` runs once per identity, so this cannot steal focus from someone who is typing
/// — which a per-update version would, since `ContentView` is re-initialised on every model
/// publish (§6c).
struct DropInitialFocus: NSViewRepresentable {
    final class Blocker: NSView {
        override var acceptsFirstResponder: Bool { false }
    }
    func makeNSView(context: Context) -> NSView {
        let v = Blocker(frame: .zero)
        DispatchQueue.main.async { [weak v] in
            guard let v, let w = v.window else { return }
            w.initialFirstResponder = v
            if w.firstResponder is NSTextView { w.makeFirstResponder(nil) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SongRow: View {
    @EnvironmentObject var model: AppModel
    let path: String

    var body: some View {
        let c = model.store.config(for: path)
        let st = model.status(of: path)
        let orders = model.takeOrders(of: path)
        let used = st != nil || c.played
        let active = model.current == path
        // Cached behind `tagsInUse`, so this is one lookup per row rather than a walk.
        let showTags = !model.store.tagsInUse.isEmpty
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
            // Leading edge: the trailing badge slot is already contested by ✓/✗/ตั้งค่าแล้ว.
            Text(c.hasOnsiteEdits ? "✎" : " ")
                .font(Typo.font(10)).foregroundStyle(Palette.amber)
                .frame(width: 9)
            // The setter's note (§8g). Until this, nothing in the list said WHERE the
            // annotations were, so a setter scanning a round had to open every song to find out.
            //
            // A SECOND reserved slot, not a share of the one above: a song edited on set can
            // also carry a note, and one slot would have to hide one of the two. Reserved,
            // because a slot that appears only when filled moves the title under the cursor —
            // this row's recurring defect (§12: the transport buttons, the focus hint).
            //
            // `※` was measured, not picked by eye. Every other mark here is spoken for (`✎`
            // on-site, `✓`/`✗` outcome, `○` never opened, `🎯` guessed, `#` take order), and of
            // the unspoken candidates it is the only one that fits: 7.01 pt at the 12 pt this
            // renders at (`Typo.font(10)` clamps to `thaiFloor`), against a 9 pt slot — the `✎`
            // beside it is 10.93 and has always overflowed its own by ~1 pt a side. It also
            // carries real ink at 1× rather than an all-antialiased stroke, and its radial shape
            // cannot be read as the pencil's diagonal at this size. `--notetest` pins both.
            //
            // Grey, never a hue: §6d gives every hue one meaning and "there is a note" is not
            // one of them — least of all amber, which means the intro-end stop is not armed.
            //
            // NOTE ONLY, never tags. The filter above the list answers "which songs carry tag
            // X" better than a glyph can, and a mark meaning "note or tags" would answer
            // neither question. Absence here means "no note", which is worth being able to rely
            // on.
            Text(c.note.isEmpty ? " " : "※")
                .font(Typo.font(10)).foregroundStyle(Palette.muted)
                .frame(width: 9)
            Text(Library.trackNumber(path))
                .font(Typo.numS).foregroundStyle(Palette.dim)
                .frame(width: 26, alignment: .leading)
            Text(Library.displayTitle(path))
                .font(active ? Typo.bodyEm : Typo.body)
                .lineLimit(2)
                .strikethrough(used)
                // NOT `.white`: the selected row's background is `tintSelect`, which is pale
                // lavender in light mode — white on it measures 1.40:1, i.e. the title of the
                // song you are working on disappears. `tintSelectText` is the partner value.
                .foregroundStyle(active ? Palette.tintSelectText : Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Where it sat in the running order. Songs are never played in list order, so without
            // this the list cannot answer "what did we open first" at all — you had to open the
            // log. A comma-separated pair means the song was revisited (a retake).
            if !orders.isEmpty {
                Text("#" + orders.map(String.init).joined(separator: ","))
                    .font(Typo.font(10, .semibold, mono: true, latinOnly: true))
                    .foregroundStyle(Palette.dim)
                    .fixedSize()
            }
            Text(badge(st, used, c))
                .font(Typo.font(10))
                .foregroundStyle(badgeColor(st, used, c))
                .fixedSize()
            }
            // The tags, under the title (§8g). Asked for after the feature shipped, because a
            // setter scanning a round could not see which song carried what without opening it.
            //
            // The line is RESERVED for every row as soon as the library has any tag at all,
            // rather than appearing only on tagged songs. §8c's reason for clamping titles to
            // two lines applies here with more force: uniform row heights are what make a
            // column scannable under pressure, and rows that grow only where a tag happens to
            // be is the worst of both — it moves every row below it and it still does not line
            // anything up. A library with no tags keeps exactly the row it had.
            if showTags {
                HStack(spacing: 4) {
                    // Three, then a count. A fourth chip pushes the row past the title's own
                    // width at the 3-column layout this list is sized for.
                    ForEach(c.tags.prefix(3), id: \.self) { TagChip(tag: $0, compact: true) }
                    if c.tags.count > 3 {
                        Text("+\(c.tags.count - 3)")
                            .font(Typo.font(10, mono: true, latinOnly: true))
                            .foregroundStyle(Palette.dim)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 52)       // past the two glyph slots and the track number
                .frame(height: 18)
            }
        }
        .opacity(used ? 0.45 : 1)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Palette.tintSelect : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(path) }
        .help(rowHelp(c))
        Divider().overlay(Palette.hair)
    }

    /// The full filename first — that is this tooltip's documented job, because the title is
    /// clamped to two lines (§8c) — and then whatever the setter wrote.
    ///
    /// Tags come along here even though the `※` glyph is note-only: a hover is asked for, so it
    /// can afford to be complete where a 9 pt slot cannot.
    private func rowHelp(_ c: SongConfig) -> String {
        let written = CenterView.plainNoteText(c)
        return written.isEmpty ? Library.title(path) : Library.title(path) + "\n" + written
    }

    /// Three setup states, not two. "Never opened" and "the app guessed it" used to render the
    /// same empty badge, and they are completely different things to the setter.
    private func badge(_ st: SongStatus?, _ used: Bool, _ c: SongConfig) -> String {
        if st == .correct { return "✓ ตอบถูก" }
        if st == .wrong { return "✗ ไม่มีคนตอบ" }
        if used { return "✓ เล่นแล้ว" }
        if model.store.songs[path] == nil { return "○ ยังไม่เปิด" }
        if c.auto || !c.isConfigured { return "🎯 เดาไว้" }
        return "✓ ตั้งค่าแล้ว"
    }
    private func badgeColor(_ st: SongStatus?, _ used: Bool, _ c: SongConfig) -> Color {
        if st == .correct { return Palette.green }
        // Amber is reserved for "the auto-stop is disarmed" now; a burned question is red.
        if st == .wrong { return Palette.red }
        if used { return Palette.muted }
        if model.store.songs[path] == nil { return Palette.muted }
        if c.auto || !c.isConfigured { return Palette.cyan }
        return Palette.green
    }
}
