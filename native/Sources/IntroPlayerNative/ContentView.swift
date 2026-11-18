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
                ReceiveBanner()
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
        .preferredColorScheme(.dark)
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
            Circle().fill(Color(red: 0, green: 0.6, blue: 0.2)).frame(width: 9, height: 9)
            Text("RGF INTRO PLAYER").font(Typo.font(15, .bold)).foregroundStyle(.white)
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
                .foregroundStyle(model.store.saveFailed ? Palette.amber : .white.opacity(0.85))
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
            .background(Color(hex: 0x482B39))
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
            // Command shortcuts first — checked before the modifier bail below
            if e.modifierFlags.contains(.command) {
                switch e.keyCode {
                case 15: model.rescan(); return nil                              // Cmd+R
                case 6:  model.undo(); return nil                                // Cmd+Z
                case 14: model.openHandover(); return nil                        // Cmd+E
                default: return e
                }
            }
            if e.modifierFlags.intersection([.control, .option]).isEmpty == false { return e }

            let sheetUp = model.showHandover || model.importPlan != nil

            if NSApp.keyWindow?.firstResponder is NSTextView {
                // Typing. The marker time fields are numeric, so Space is never valid input
                // there — and a focus left in a field must never be the reason a buzz cannot be
                // stopped. Inside a sheet the setter-name field takes real text, so Space is left
                // alone there.
                if !sheetUp, e.keyCode == 49, model.player.isPlaying {
                    model.player.toggleStart(config: model.config())
                    return nil
                }
                return e
            }
            if e.keyCode == 53 {                                                 // Esc
                if model.pending != nil { model.cancelPending(); return nil }
                if model.importPlan != nil { model.importPlan = nil; return nil }
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
            case 35: model.updateConfigQuiet { $0.played.toggle() }; model.pulse(PulseID.played)
            case 36: model.confirmCurrent()                                      // Return
            case 48: model.nextNeedingReview()                                   // Tab
            // Audition the hook and stop. `R` stays unbounded — that one is on camera.
            case 5:  model.previewHook(); model.pulse(PulseID.preview)                     // G
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
                    Text("Songs (\(model.songsIn(model.currentPlaylist).count)) · เล่นแล้ว \(playedCount)")
                        .font(Typo.font(12)).foregroundStyle(Palette.muted)
                    Spacer()
                }
                // Rescan stays a button: it is the safe one and the one pressed most (a round
                // dropped in while the app is open is the commonest real complaint). The two that
                // throw work away move behind `⋯`, out of slamming range of it — they were three
                // identical 11pt pills in a row, one of which can wipe a taping's badges.
                HStack(spacing: 6) {
                    smallButton("⟳ อ่านโฟลเดอร์ใหม่") { model.rescan(); model.flash("อ่าน songs/ ใหม่แล้ว") }
                    Menu {
                        Button("↺ รีเซ็ตเล่นแล้ว — เริ่มถ่ายรอบใหม่") { resetPlayedFlow() }
                        Button("🗑 ล้างเพลงเก่า\(model.orphanCount > 0 ? " (\(model.orphanCount))" : "")") {
                            pruneFlow()
                        }
                        .disabled(model.orphanCount == 0)
                    } label: {
                        Text("⋯").font(Typo.font(13, .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 38)
                    .padding(.vertical, 2)
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
                                    ForEach(model.songsIn(column: i), id: \.self) { SongRow(path: $0) }
                                } header: {
                                    ColumnHeader(index: i, count: model.songsIn(column: i).count)
                                }
                            }
                        }
                    }
                    .onChange(of: model.current) { cur in
                        guard let cur else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(cur, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: model.isWide ? 780 : 300)
        .background(Palette.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
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
                .foregroundStyle(model.activeCol == index ? Color(red: 0.81, green: 0.88, blue: 1) : Palette.text)
            Text("(\(count))").font(Typo.font(11)).foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(model.activeCol == index ? Color(red: 0.141, green: 0.188, blue: 0.286) : Palette.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct ColumnView: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let list = model.songsIn(column: index)
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
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SongRow: View {
    @EnvironmentObject var model: AppModel
    let path: String

    var body: some View {
        let c = model.store.config(for: path)
        let st = model.status(of: path)
        let used = st != nil || c.played
        let active = model.current == path
        HStack(alignment: .top, spacing: 8) {
            // Leading edge: the trailing badge slot is already contested by ✓/✗/ตั้งค่าแล้ว.
            Text(c.hasOnsiteEdits ? "✎" : " ")
                .font(Typo.font(10)).foregroundStyle(Palette.amber)
                .frame(width: 9)
            Text(Library.trackNumber(path))
                .font(Typo.numS).foregroundStyle(Palette.dim)
                .frame(width: 26, alignment: .leading)
            Text(Library.displayTitle(path))
                .font(active ? Typo.bodyEm : Typo.body)
                .lineLimit(2)
                .strikethrough(used)
                .foregroundStyle(active ? .white : Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(badge(st, used, c))
                .font(Typo.font(10))
                .foregroundStyle(badgeColor(st, used, c))
                .fixedSize()
        }
        .opacity(used ? 0.45 : 1)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Color(red: 0.141, green: 0.188, blue: 0.286) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(path) }
        .help(Library.title(path))
        Divider().overlay(Color(red: 0.125, green: 0.141, blue: 0.176))
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
