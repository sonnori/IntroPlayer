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
    /// Click-outside ends editing — see `FocusRelease`. A local NSEvent monitor rather than a
    /// background `.onTapGesture`, because the views most likely to be clicked when you are done
    /// typing (the waveform, every button) consume their own gestures and a root tap would never
    /// see them.
    @State private var mouseMonitor: Any?

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
                    // The two draggable boundaries the owner asked for. §6c refused exactly this
                    // and was not wrong; see `PaneLayout` for what carries the risk instead.
                    PaneEdge(index: 0)
                    CenterView()
                    PaneEdge(index: 1)
                    SetupPanel()
                }
            }
            .onAppear { model.setWindowWidth(geo.size.width) }
            .onChange(of: geo.size.width) { w in model.setWindowWidth(w) }
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
        .onAppear(perform: installMouseMonitor)
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
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
            mouseMonitor = nil
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
            //
            // The logo and the wordmark are ONE lockup, so they sit in their own `HStack` at a
            // tighter 10 pt than the 14 pt that separates the bar's independent items.
            HStack(spacing: 10) {
                if let logo = ShowLogo.prepared {
                    // The bitmap is already exactly `size x backingScale` pixels, so this frame
                    // is 1:1 and SwiftUI has no rescaling left to do. `.interpolation(.high)`
                    // stays only to cover the case where the window is dragged to a display of a
                    // different scale than the one resolved at launch.
                    //
                    // `accessibilityHidden`, because the `Text` beside it says the same thing:
                    // labelling both would announce the name twice.
                    Image(nsImage: logo.image)
                        .resizable().interpolation(.high)
                        .frame(width: logo.size.width, height: logo.size.height)
                        .accessibilityHidden(true)
                }
                // ALWAYS, beside the logo — `{logo} RGF INTRO PLAYER`, on request.
                //
                // Superseded, and the reasoning is kept because it was not wrong, it just did
                // not bind. A native-design audit removed these words: `WindowGroup("RGF Intro
                // Player")` keeps the titlebar, which carries the name 28 pt above this bar, so
                // with the logo up the app's name was on screen three times in two strips, and
                // the words also spent ~170 pt of header width the live chips want.
                //
                // The width half is now measured instead of asserted. At `App.swift`'s declared
                // `minWidth: 1100`, with BOTH chips up, both buttons, the save state, and the
                // logo at its full 90 pt cap, the bar needs 792 pt — **308 pt spare**; the real
                // 44 pt logo leaves 354. The words cost 156 pt of that. So the objection was
                // real and never close to binding, and the duplication is the owner's call.
                //
                // Still correct when there is no logo at all, which is a real state twice over:
                // a public build carries no `brand/` payload (§15), and macOS hides the titlebar
                // in fullscreen — either way the bar must say what it is.
                //
                // `Palette.onHeader`, not `.white`. They are the same value, but this bar is dark
                // red in BOTH themes, so what sits on it must be a FIXED-light role — §6d records
                // the save-failure text measuring 1.2:1 in light because it used a theme-flipping
                // colour here.
                Text("RGF INTRO PLAYER").font(Typo.font(15, .bold))
                    .foregroundStyle(Palette.onHeader)
                    .fixedSize()
            }
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
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
            guard let win = e.window else { return e }
            let hit = win.contentView?.hitTest(e.locationInWindow)
            if FocusRelease.shouldRelease(firstResponder: win.firstResponder, hit: hit) {
                // Resigning fires each field's `onChange(of: focused)`, which is where blur
                // CANCELS uncommitted text (§11) — so clicking away means exactly what Esc
                // means: discard, do not write. It must not commit; §11 lists three ways a
                // committing blur destroyed a signed-off marker.
                win.makeFirstResponder(nil)
            }
            // Never swallowed: the click still does whatever it was going to do.
            return e
        }
    }

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
            // `⌥` + `←`/`→` pans the view. `Shift` + that pair used to, and 1.6.4 gave Shift to
            // the coarse marker nudge on request (Unity's idiom) — pan has three other entry
            // points, a drag on empty canvas, shift-wheel / horizontal wheel and the overview
            // strip (§8b), while a coarse keyboard step had none.
            //
            // It must sit ABOVE the bail below, which hands every Control/Option event straight
            // back to the system. `typing` and `sheetUp` are therefore re-checked here rather
            // than inherited from the branches further down: in a text field `⌥←` is word-left
            // and has to stay that way, and with a sheet up the arrows belong to the sheet.
            // Autorepeat is deliberately allowed, like every other arrow — holding it to pan is
            // the point, and the `isARepeat` guard below is also further down.
            if !typing, !sheetUp, e.modifierFlags.contains(.option),
               e.keyCode == 123 || e.keyCode == 124 {
                model.pan(by: (e.keyCode == 123 ? -1 : 1) * model.viewSpan * 0.25)
                return nil
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
                    // From inside the SEARCH box specifically, Esc closes the search outright
                    // rather than merely blurring: closing clears the term, which IS "discard,
                    // do not write", and leaving a narrowed list behind an unfocused box is the
                    // §8c trap with the explanation taken away. Gated on which field has focus
                    // because the note field and the search row can be open at the same time.
                    if model.searchFieldFocused { model.closeSearch() }
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return e
            }
            if e.keyCode == 53 {                                                 // Esc
                if model.pending != nil { model.cancelPending(); return nil }
                if model.searching { model.closeSearch(); return nil }
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
            // Autorepeat is suppressed app-wide because two taps of `1` 120 ms apart once
            // overlapped two stings on camera (§12) — but the arrows are the one pair where a
            // HELD key is the point: 0.01 s a press is 100 presses per second of audio. Safe
            // for the same reason §11 gives for the typed field, which has no limit either:
            // §10's `remode` may only ARM the intro-end guard, never disarm it, and the nudge
            // commits through a 350 ms debounce so a held key cannot thrash the node.
            if e.isARepeat, e.keyCode != 123, e.keyCode != 124 { return nil }
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
            // Played is `T` ALONE. It used to be `P` as well, bound because `P` was not
            // discoverable (nothing on screen named it) — but two keys for one toggle is two
            // things to remember and one more key that does something while a take is running.
            // Dropped by product decision; both buttons name `T` now, which is the fix the
            // discoverability problem actually needed.
            //
            // **`T` is keyCode 17, one key from `R` (15), which puts the chorus on camera.** It
            // is bound anyway, and the two-press rule (§11) is deliberately NOT applied, because
            // it would not help: the mis-press that costs something is reaching for T and
            // hitting R, and guarding T only guards the harmless direction. Toggling Played
            // writes no log event, airs nothing and is undone by pressing the key again — so the
            // key itself needs no guard, and the adjacency is a thing to know rather than a
            // thing to fix here. If this ever bites, move Played off the QWERTY row; do not
            // guard `R`, which §11 explains at length.
            case 17: model.updateConfigQuiet { $0.played.toggle() }; model.pulse(PulseID.played)
            case 36: model.confirmCurrent()                                      // Return
            case 48: model.nextNeedingReview()                                   // Tab
            case 46: model.cycleFocusMarker()                                              // M
            // `/` (keyCode 44, layout-independent — §11). Free: nothing else in the table uses
            // it, and it is the search key everywhere else on this machine.
            case 44: model.openSearch()
            case 6:  model.zoomIntro(); model.pulse(PulseID.zoomIntro)                     // Z
            case 27, 78: model.zoomBy(1.6); model.pulse(PulseID.zoomOut)                   // -
            case 24, 69: model.zoomBy(1 / 1.6); model.pulse(PulseID.zoomIn)                // =
            case 29, 82: model.zoomFit(); model.pulse(PulseID.zoomFit)                     // 0
            case 125: model.cancelPending(); model.move(by: 1)                 // down
            case 126: model.cancelPending(); model.move(by: -1)                // up
            case 33: model.cancelPending(); model.moveColumn(by: -1)           // [
            case 30: model.cancelPending(); model.moveColumn(by: 1)            // ]
            // PLAIN ←/→ nudge the focused marker; SHIFT pans the view. Swapped round on
            // request — "กดปุ่มซ้ายหรือขวาเพื่อขยับ marker" — and nothing is lost, the pan just
            // moves onto the modifier. The arrows are the precision neither the ± buttons
            // (0.1 s) nor a drag at a readable zoom can reach, and they are also what a hand
            // reaches for right after `I`/`O` without thinking.
            // `Shift` = 10× (the `±` buttons' own 0.1 s). Pan moved to `⌥`, handled above.
            case 123:
                model.nudgeFocused(by: e.modifierFlags.contains(.shift)
                                   ? -AppModel.nudgeStepCoarse : -AppModel.nudgeStep)
            case 124:
                model.nudgeFocused(by: e.modifierFlags.contains(.shift)
                                   ? AppModel.nudgeStepCoarse : AppModel.nudgeStep)
            default: return e
            }
            return nil
        }
    }
}

// MARK: - song list

struct SongListView: View {
    @EnvironmentObject var model: AppModel
    /// Owns the search field's first responder. The model mirrors it in `searchFieldFocused`
    /// so the key monitor can tell "Esc in the SEARCH box" from "Esc in any other box".
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                if model.showPlaylistPicker {
                    Picker("", selection: Binding(
                        get: { model.currentPlaylist },
                        set: { model.setPlaylist($0) })) {
                        ForEach(model.playlists, id: \.self) { p in
                            let n = model.songsIn(p).count
                            // The inbox tray marks a round holding a round.json nobody has taken
                            // in yet. This is the DURABLE half of the receive strip: the strip is
                            // one slot and can be waved off, this cannot, so "which folders are
                            // still waiting" stays answerable after a dismissal and after a
                            // relaunch — which is the whole point once three setters are each
                            // handing a folder over.
                            Text("\(model.hasIncoming(p) ? "📥 " : "")\(p.isEmpty ? Library.rootLabel : p)  (\(n))")
                                .tag(p)
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
                    // A visible entry point, not just the `/` key. §11 records the same defect
                    // for Played: `P` had worked since the native app shipped and was reported
                    // as "no shortcut", because nothing on screen named it. The label carries
                    // the key for that reason.
                    searchButton
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
                    .accessibilityLabel("คำสั่งอื่น")
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

            searchRow
            tagFilterStrip

            if model.listShowsColumns {
                let colW = model.columnWidths()
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        ColumnView(index: i)
                            .frame(width: colW.indices.contains(i) ? colW[i] : nil)
                        // The boundary stays between every pair, folded or not: a rail with no
                        // divider reads as part of its neighbour's scroller.
                        if i < 2 { ColumnEdge(index: i) }
                    }
                }
            } else {
                // Narrow: one scroller for the whole list, columns become section headers.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(0..<3, id: \.self) { i in
                                Section {
                                    // The SAME `collapsedCols`, rendered the other way round: in
                                    // one scroller a folded group hides its rows instead of
                                    // narrowing to a rail. One state, two layouts — so both
                                    // refusals in `ColumnFold.decide` (the group holding the
                                    // selection, and the last expanded one) apply here for free,
                                    // and `select` unfolds from either side.
                                    //
                                    // This layout is not a fallback to be ignored: a window under
                                    // 1900 pt gets it, which includes any laptop whose screen
                                    // cannot reach that — and §6c keeps the macOS 13 target
                                    // precisely so older crew Macs still run this.
                                    if !model.isColumnCollapsed(i) {
                                        ForEach(model.visibleSongs(column: i), id: \.self) {
                                            SongRow(path: $0)
                                        }
                                    }
                                } header: {
                                    ColumnHeader(index: i, count: model.visibleSongs(column: i).count,
                                                 foldable: .vertical)
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
        // 780 → 900 on request ("มัน width แคบไป"). Three columns share it, so each row gains
        // ~40 pt — which is what decides whether a 2-line clamped title still tells two songs
        // apart (§8c). The pane is draggable now, so this is the resolved width rather than a
        // well clear of the 378 pt that made §12 raise that breakpoint in the first place.
        //
        // Through `AppModel.listWidth` because `LogPanel` occupies this same slot and has to be
        // the same number — see that property for what 120 pt of difference did.
        .frame(width: model.listWidth)
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
    private var searchButton: some View {
        Button { model.openSearch() } label: {
            Text(model.search.isEmpty ? "⌕ ค้นหาเพลง  /" : "⌕ \(model.search)")
                .font(Typo.font(11))
                .foregroundStyle(model.search.isEmpty ? Palette.muted : Palette.text)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 6))
        .fixedSize()
        .background(model.search.isEmpty ? Palette.panel2 : Palette.tintSelect)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("ค้นหาเพลงในรอบนี้จากชื่อไฟล์ — ไม่กระทบการส่งต่อหรือรอบตรวจ")
    }

    /// Free-text narrowing by filename — opened with `/`, closed with Esc or ✕.
    ///
    /// A row that appears rather than a box that always sits there, for the reason §12 keeps
    /// coming back to: a field with first responder turns the key monitor's `typing` branch on,
    /// and in it `S`, `R`, `P`, `I`/`O`/`H`, `L` all stop working. Only `Space`, `1` and `2` are
    /// carved out, and only while playback runs — so a buzz can still be stopped and scored, but
    /// nothing else can. A permanently-focusable search box over the song list would mean the
    /// transport is one stray click from being dead with nothing on screen saying so (§8g
    /// records the note field hitting exactly this). It opens on a deliberate key, Return hands
    /// the keyboard straight back, and Esc closes it.
    @ViewBuilder private var searchRow: some View {
        if model.searching {
            let shown = model.visibleSongs(model.currentPlaylist).count
            let total = model.songsIn(model.currentPlaylist).count
            let other = shown == 0 && !model.search.isEmpty ? model.searchElsewhere() : []
            HStack(spacing: 8) {
                Text("⌕").font(Typo.font(13, latinOnly: true)).foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                TextField("ชื่อไฟล์เพลง — Enter เลือกเพลงแรก, Esc ปิด", text: Binding(
                    get: { model.search }, set: { model.setSearch($0) }))
                    .textFieldStyle(.plain)
                    .font(Typo.font(12))
                    .focused($searchFocused)
                    .onSubmit { model.commitSearch(); searchFocused = false }
                if model.search.isEmpty {
                    Text("พิมพ์ส่วนไหนของชื่อก็ได้").font(Typo.font(11))
                        .foregroundStyle(Palette.dim).lineLimit(1)
                } else if shown == 0 {
                    // Never a bare "ไม่เจอ": an empty list that does not say where the song IS
                    // is §8c's "the app can't find my songs" with a search box on top.
                    Text(other.isEmpty
                         ? "ไม่เจอในรอบนี้"
                         : "ไม่เจอในรอบนี้ · มีใน " + other.map {
                               "\(Library.label($0.round)) (\($0.count))" }.joined(separator: ", "))
                        .font(Typo.font(11)).foregroundStyle(Palette.amber).lineLimit(1)
                } else {
                    Text("เห็น \(shown) จาก \(total)").font(Typo.font(11))
                        .foregroundStyle(Palette.muted)
                }
                Button { model.closeSearch() } label: {
                    Text("✕ เลิกค้นหา").font(Typo.font(11))
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
            // `tintSelect` — the emphasis the active column header uses, never a hue. §6d gives
            // each hue exactly one meaning and amber in particular means the intro-end stop is
            // not armed.
            .background(Palette.tintSelect)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
            // One runloop hop. Setting `@FocusState` directly inside `onAppear` lands before
            // the field is in the responder chain and is unreliable on macOS — and a search box
            // that opens without focus means the first thing you type goes to the key monitor
            // instead, where letters are shortcuts: `S` resets, `R` reveals on camera.
            //
            // Gated on the one-shot, NOT unconditional: toggling the log remounts this whole
            // pane (`if showLog { LogPanel() } else { SongListView() }` — separate view
            // identities), so an unconditional focus here stole first responder on every
            // `L`/`L` and silently killed the transport. See `AppModel.searchWantsFocus`.
            // The hop is also where the `@Published` write belongs — §6c: never write one
            // from inside a layout pass.
            .onAppear {
                DispatchQueue.main.async {
                    guard model.searchWantsFocus else { return }
                    model.searchWantsFocus = false
                    searchFocused = true
                }
            }
            .onDisappear { model.searchFieldFocused = false }
            .onChange(of: searchFocused) { f in model.searchFieldFocused = f }
        }
    }

    @ViewBuilder
    private var tagFilterStrip: some View {
        if !model.tagFilter.isEmpty {
            HStack(spacing: 8) {
                Text("⌕ กรอง: \(model.tagFilter)")
                    .font(Typo.font(12, .semibold)).foregroundStyle(Palette.tintSelectText)
                Text("เห็น \(model.visibleSongs(model.currentPlaylist).count) "
                     + "จาก \(model.songsIn(model.currentPlaylist).count) · ซ่อนอยู่ \(model.hiddenCount)")
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

/// The boundary between two PANES, and the handle that drags it.
///
/// `ColumnEdge`'s sibling, and the one §6c actually refused: *"a split view's divider is
/// user-draggable by design — which adds a way to resize the waveform mid-take by brushing the
/// mouse"*. The owner asked for it directly, so `PaneLayout` carries that risk instead of the
/// feature being declined — read it before changing anything here.
///
/// `minimumDistance: 4`, double `ColumnEdge`'s 2, is the part that answers §6c on its own terms:
/// a brush is not a drag. Everything else is the same construction, for the same reasons.
struct PaneEdge: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    /// Taken off the window before any pane is sized — see `AppModel.paneWidths`.
    static let width: CGFloat = 8
    @State private var cursorPushed = false
    @State private var dragged: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle().fill(.clear)
            Rectangle().fill(Palette.line).frame(width: 1)
            // Visible at rest. The in-list version of this shipped with the cursor change as its
            // only affordance and was reported as the feature not working at all — §12's
            // `P`-had-no-shortcut lesson, where a control nobody can find is indistinguishable
            // from a broken one. A structural divider has to announce itself even more than that
            // one did, because nothing else in the window looks draggable.
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule().fill(Palette.dim).frame(width: 2, height: 12)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: PaneEdge.width)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, !cursorPushed {
                NSCursor.resizeLeftRight.push(); cursorPushed = true
            } else if !inside, cursorPushed {
                NSCursor.pop(); cursorPushed = false
            }
        }
        .gesture(
            // **`.global`, and this is the whole fix for the judder.** A `DragGesture` defaults
            // to `.local`, which measures translation against the view's own coordinate space —
            // and this view MOVES as a direct result of the drag. So each sample was measured
            // from an origin the previous sample had just shifted, a feedback loop with gain
            // about 1, which oscillates. Measured on the screen recording: the boundary swung
            // **40–80 px back and forth between consecutive frames** while the mouse moved
            // steadily one way. Oscillation, not lag.
            //
            // A global space does not move, so the translation is what the mouse actually did.
            // `ColumnEdge` has the identical bug and the identical fix.
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { g in
                    let d = g.translation.width - dragged
                    dragged = g.translation.width
                    model.dragPaneEdge(after: index, by: d)
                }
                // Persist ONCE, on release. `dragPaneEdge` used to call `settingsChanged()`,
                // which is `writeSettings()` + `scheduleSave()` — so every mouse sample rebuilt
                // the whole `_settings` dictionary, guards and all, at 60 Hz for a value only
                // the last one of them could matter to.
                .onEnded { _ in dragged = 0; model.commitPaneWidths() }
        )
        .onTapGesture(count: 2) { model.resetPaneWidths() }
        .help("ลากเพื่อปรับความกว้างแผง · ดับเบิลคลิกเพื่อคืนค่าเริ่มต้น")
        .accessibilityLabel(index == 0 ? "ปรับความกว้างระหว่างรายการเพลงกับแผงกลาง"
                                       : "ปรับความกว้างระหว่างแผงกลางกับแผงขวา")
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
    }
}

/// The 1 pt boundary between two song columns, plus the handle that drags it.
///
/// **§6c's refusal of a draggable divider is about a different divider.** That section rejects
/// `NavigationSplitView` partly because its divider would let the operator resize the WAVEFORM by
/// brushing the mouse mid-take, and §12's recurring defect is a control that moves under the
/// cursor. This one is inside the left pane, whose own width the operator sets: it
/// moves the boundary between two columns of song rows and cannot touch the centre pane. The
/// waveform, the markers, the transport and ✓/✗ all hold still.
///
/// What it still has to get right is the §11 marker-grab lesson: **a press that moves nothing
/// must change nothing.** `DragGesture(minimumDistance: 2)` is what does that here — a click on
/// the boundary is not a 0 pt drag, it never starts. And the handle is its own view sitting ON
/// the divider, so it cannot swallow a click meant for a song row: the rows end where it begins.
struct ColumnEdge: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    /// 8 pt — the divider is 1 pt, which is not a mouse target. Taken from the gap between the
    /// columns' own padding, so no row loses width to it.
    /// 8 pt. A 1 pt divider is not a mouse target, and the edge is **itself** this wide with the
    /// hairline drawn down its middle — rather than an 8 pt overlay on a 1 pt parent, which would
    /// depend on hit-testing outside the parent's bounds. `AppModel.columnWidths` takes these off
    /// the pane, so the columns know they are there.
    static let width: CGFloat = 8
    @State private var cursorPushed = false
    @State private var dragged: CGFloat = 0

    var body: some View {
        let live = model.canDragColumnEdge(after: index)
        ZStack {
            Rectangle().fill(.clear)
            Rectangle().fill(Palette.line).frame(width: 1)
            // A grip, visible at rest. Without it the only thing saying this 8 pt strip can be
            // dragged was the cursor changing on hover, which nobody discovers by not hovering —
            // and the first version of this feature was reported as simply not working. §12's
            // `P`-had-no-shortcut lesson: a control nobody can find reads as a broken one.
            //
            // Three 10 pt segments centred vertically, `dim` so it does not compete with the
            // hairline it sits on. Only where the edge is actually live, so a dead boundary does
            // not advertise a gesture that will not happen.
            if live {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Palette.dim).frame(width: 2, height: 10)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: ColumnEdge.width)
        .contentShape(Rectangle())
        .onHover { inside in
            guard live else { return }
            // Balanced by the flag, not by trusting the pair of callbacks: an unmatched `push`
            // leaves the resize cursor over the whole app, and an unmatched `pop` takes somebody
            // else's off the stack.
            if inside, !cursorPushed {
                NSCursor.resizeLeftRight.push(); cursorPushed = true
            } else if !inside, cursorPushed {
                NSCursor.pop(); cursorPushed = false
            }
        }
        .gesture(
            // `.global` for the reason spelled out in `PaneEdge`: this view moves as a result
            // of the drag, so a `.local` translation feeds back on itself and oscillates.
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { g in
                    guard live else { return }
                    // The gesture reports total translation from the press, so feed the model the
                    // DELTA since the last sample or the drag accelerates away from the mouse.
                    let d = g.translation.width - dragged
                    dragged = g.translation.width
                    model.dragColumnEdge(after: index, by: d)
                }
                .onEnded { _ in dragged = 0 }
        )
        .onTapGesture(count: 2) { if live { model.resetColumnWidths() } }
        .help(live ? "ลากเพื่อปรับความกว้าง · ดับเบิลคลิกเพื่อคืนเป็นสามส่วนเท่ากัน" : "")
        .accessibilityHidden(!live)
        .accessibilityLabel("ปรับความกว้างคอลัมน์")
        // The log pane unmounts this list (§12), so a pushed cursor has to come back off here.
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
    }
}

struct ColumnHeader: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let count: Int
    /// Which idiom this header's fold control uses, or `.none` where there is no control.
    ///
    /// Both drive the same `AppModel.collapsedCols`; only the rendering and the glyph differ —
    /// sideways to a rail in the 3-across layout, a disclosure of the section's rows in the one
    /// scroller. Keeping it one state is what makes the two refusals in `ColumnFold.decide` and
    /// `select`'s unfold apply in both without being written twice.
    enum Fold { case none, sideways, vertical }
    var foldable: Fold = .none

    var body: some View {
        HStack(spacing: 6) {
            Text(Library.columnLabels[index]).font(Typo.font(12, .bold))
                .foregroundStyle(model.activeCol == index ? Palette.tintSelectText : Palette.text)
            Text("(\(count))").font(Typo.font(11)).foregroundStyle(Palette.muted)
            Spacer()
            // A small glyph at the trailing edge, and NOT the whole header strip, which was the
            // obvious way to build this and the wrong one. The header sits directly above row 1
            // and `select()` has no playing guard — it calls `player.load(url:)` at once — so a
            // whole-strip toggle would put "reflow every row sideways" one slip above "cut the
            // audio on camera". §12 records that class four times: the transport buttons that
            // slid when playback started (a click meant for Reset could land on Reveal), the
            // conditional focus-hint line, the cover frame that came and went, and `L` moving the
            // centre pane 120 pt.
            //
            // `‹` measured 5.48 pt at 12 pt bold and lands in `.SFNS-Bold`, not in CoreText's
            // LastResort — §12's glyph lesson, where the honest test is which FONT the laid-out
            // run resolves to, because LastResort supplies a glyph for every codepoint in
            // Unicode and "the glyph exists" therefore never fails.
            // It has to LOOK like a button. The first version was a bare 5.48 pt grey `‹` with
            // no background, and it was reported as the feature not working at all — §12 records
            // the same shape for `P`, which had toggled Played since the native app shipped and
            // was still reported as having no shortcut because nothing on screen said so. A
            // control nobody can find is indistinguishable from one that is broken.
            if foldable != .none {
                let folded = model.isColumnCollapsed(index)
                Button { model.setColumnCollapsed(index, !folded) } label: {
                    Text(foldable == .sideways ? "\u{2039}" : (folded ? "\u{25B8}" : "\u{25BE}"))
                        .font(Typo.font(13, .semibold, latinOnly: true))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 5))
                .foregroundStyle(Palette.text)
                .background(Palette.panel2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line)
                    .allowsHitTesting(false))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel((folded ? "เปิดกลุ่ม " : "พับกลุ่ม ") + Library.columnLabels[index])
                .help(foldable == .sideways
                      ? "พับคอลัมน์นี้ให้เหลือราง เพื่อให้คอลัมน์อื่นกว้างขึ้น"
                      : (folded ? "เปิดกลุ่มนี้คืน" : "พับกลุ่มนี้ให้ซ่อนรายการเพลง"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(model.activeCol == index ? Palette.tintSelect : Palette.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct ColumnView: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    @ViewBuilder
    var body: some View {
        if model.isColumnCollapsed(index) { rail } else { expanded }
    }

    /// Folded: a rail that still says which column it is and how many songs are in it. **Never
    /// hidden** — §8g measured a view state that hides questions as §8c's "the app can't find my
    /// songs", which was reported from real use once already.
    ///
    /// The WHOLE rail is the unfold button, which is safe exactly where a whole-header fold
    /// button is not: a folded column has no song rows in it, so a click anywhere in it can only
    /// mean one thing. See `ColumnHeader` for the other direction.
    private var rail: some View {
        let n = model.visibleSongs(column: index).count
        let on = model.activeCol == index
        return Button { model.setColumnCollapsed(index, false) } label: {
            VStack(spacing: 6) {
                Text("\u{203A}").font(Typo.font(12, .bold)).foregroundStyle(Palette.muted)
                Text(Library.columnShort[index])
                    .font(Typo.font(12, .bold))
                    .foregroundStyle(on ? Palette.tintSelectText : Palette.text)
                Text("(\(n))").font(Typo.font(11, .regular, latinOnly: true))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            .padding(.top, 7)
            .frame(width: AppModel.collapsedColWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 0))
        .background(on ? Palette.tintSelect : Palette.panel2)
        .accessibilityLabel("เปิดคอลัมน์ \(Library.columnLabels[index]) ที่พับไว้ — \(n) เพลง")
        .help("เปิดคอลัมน์ \(Library.columnLabels[index]) คืน")
    }

    private var expanded: some View {
        let list = model.visibleSongs(column: index)
        return VStack(spacing: 0) {
            ColumnHeader(index: index, count: list.count, foldable: .sideways)

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
        let showNote = model.store.anyNote
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
            // The note itself, under the row — asked for as "ให้โน้ตคนรันแสดงใน list เพลงด้วย
            // ข้างล่างตรง ก็ได้". The `※` above says only THAT there is one; a setter scanning a
            // round for "which question did I flag" still had to open each song.
            //
            // RESERVED for every row as soon as any song in the library carries a note, exactly
            // like the tag line and for the same measured reason: §8c clamps titles to two lines
            // because uniform row heights are what make a column scannable under pressure, and a
            // line that appears only where a note happens to be moves every row below it while
            // lining nothing up. A library with no notes keeps the row it had — `anyNote` is
            // cached beside `tagsInUse`, one lookup per row, not a scan.
            //
            // ONE line, truncated. The column is ~299 pt at equal thirds and a note is up to 120
            // clusters, so most will clip; the row's tooltip already carries it in full and the
            // centre pane shows two lines of it the moment the song is opened. A second line
            // here would cost another ~16 pt on every row in the round to finish a sentence that
            // is about to be on screen in full anyway.
            //
            // `muted`, never a hue (§6d), and never the `※`'s own grey either — this is content,
            // the glyph is a marker.
            if showNote {
                Text(c.note.isEmpty ? " " : c.note)
                    .font(Typo.font(11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 52)
                    .frame(height: 16, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
