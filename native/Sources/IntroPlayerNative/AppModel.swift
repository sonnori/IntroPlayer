import AVFoundation
import Combine
import SwiftUI

enum SongStatus { case correct, wrong }

@MainActor
final class AppModel: ObservableObject {
    let store = Store()
    let logStore = LogStore()
    let player = Player()

    @Published var songs: [String] = []
    @Published var currentPlaylist = ""
    @Published var activeCol = 0
    @Published var current: String?
    @Published var analysis: Analysis?
    @Published var analysing = false
    @Published var saveState = "—"
    @Published var scopeNote = ""
    @Published var showLog = false
    @Published var logAllRounds = false
    @Published var toast: String?
    /// Three columns need ~780pt of list; below that the layout falls back to one column, exactly
    /// like the web version's max-width:1500px media query.
    @Published var isWide = true
    /// Which on-screen button is flashing because its keyboard shortcut just fired.
    @Published var pulseID: String?
    private var pulseTask: Task<Void, Never>?

    // MARK: handover surfaces
    @Published var showHandover = false
    @Published var preflight: [PreflightItem] = []
    @Published var preflightScanning = false
    @Published var importPlan: ImportPlan?
    @Published var acceptedRows: Set<String> = []
    /// A `round.json` sitting in the round's folder that has not been taken in yet. Drives the
    /// receive banner, which must persist — the operator may not be looking when a toast fires.
    @Published var incoming: RoundPackage?
    @Published var incomingDismissed = false
    @Published var setterName = ""

    // MARK: two-press confirmation
    /// `I`/`O`/`H`/`E` pressed once while playback is running. The committed value is the
    /// position captured at the FIRST press — using the second press's position would let two
    /// seconds of playback drift into the marker and silently set the wrong value.
    struct PendingMark {
        let field: MarkerField
        let t: Double
    }
    @Published var pending: PendingMark?
    private var pendingTask: Task<Void, Never>?

    // MARK: fine adjustment
    /// Which marker `Shift+←/→` nudges. Follows whatever the setter last touched — a drag, an
    /// `I`/`O`/`H`, a typed value or a ± press — so the nudge always means "the one I am working
    /// on" without a mode anybody has to remember. `M` cycles it explicitly.
    @Published var focusMarker: MarkerField = .introStart
    /// One hundredth of a second: the precision markers are actually stored at. The ± buttons
    /// deliberately stay at 0.1 s — this is the step you cannot get from them or from a drag.
    static let nudgeStep: Double = 0.01
    /// 2 s is tight for someone watching the stage rather than the screen; the only cost of a
    /// longer window is a longer-lived ghost marker.
    static let pendingWindow: Double = 2.5

    /// Written from inside a layout pass (`onAppear` / `onChange(of: geo.size.width)`). Assigning
    /// a @Published there is "Modifying state during view update", and assigning the same value
    /// published a frame for nothing during a live resize.
    func setWide(_ w: Bool) {
        guard w != isWide else { return }
        Task { @MainActor in self.isWide = w }
    }

    func pulse(_ id: String) {
        pulseTask?.cancel()
        pulseID = id
        pulseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { if self?.pulseID == id { self?.pulseID = nil } }
        }
    }

    // MARK: - undo

    /// Snapshots of one song's settings taken before a change. A waveform drag writes per frame,
    /// so successive snapshots of the same song inside `undoCoalesce` collapse into the first —
    /// one drag is one undo step, not sixty.
    private var undoStack: [(path: String, c: SongConfig, at: Date)] = []
    @Published private(set) var canUndo = false
    private static let undoMax = 40
    private static let undoCoalesce: TimeInterval = 0.7

    func pushUndo(_ path: String, coalesce: Bool = true) {
        let now = Date()
        if coalesce, let last = undoStack.last, last.path == path,
           now.timeIntervalSince(last.at) < AppModel.undoCoalesce {
            undoStack[undoStack.count - 1].at = now    // extend the window, keep the OLDER value
            return
        }
        undoStack.append((path, store.config(for: path), now))
        if undoStack.count > AppModel.undoMax { undoStack.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let last = undoStack.popLast() else { flash("ไม่มีอะไรให้ย้อน"); return }
        canUndo = !undoStack.isEmpty
        store.set(last.c, for: last.path)
        saveState = "saving…"
        let name = Library.title(last.path)
        // Show what was undone — but never yank the playhead mid-take.
        if current != last.path, !player.isPlaying {
            select(last.path)
        } else if current == last.path {
            refreshGain()
            player.remode(config: last.c)
            if !player.isPlaying { player.seek(to: last.c.introStart, config: last.c) }
        }
        flash("ย้อนกลับแล้ว: \(name)")
        objectWillChange.send()
    }

    /// Visible time window of the waveform.
    @Published var viewStart: Double = 0
    @Published var viewEnd: Double = 1

    private var seNodes: [AVAudioPlayer] = []
    private var bag = Set<AnyCancellable>()

    init() {
        songs = Library.scan()
        let pls = playlists
        currentPlaylist = pls.contains(store.lastPlaylist) ? store.lastPlaylist : (pls.first ?? "")
        player.configProvider = { [weak self] in
            guard let self, let c = self.current else { return SongConfig() }
            return self.store.config(for: c)
        }
        player.onAutoStop = { [weak self] in self?.objectWillChange.send() }
        player.onTick = { [weak self] in self?.followPlayhead() }
        player.onEngineFailure = { [weak self] msg in self?.flash(msg) }
        store.onSaveStateChange = { [weak self] in
            guard let self else { return }
            self.saveState = self.store.saveState
            self.objectWillChange.send()
        }
        rebuildResetCache()
        // The save is debounced 250 ms. Quitting inside that window — which is exactly what
        // happens when the GM marks a song and immediately hits Cmd+Q — dropped the edit.
        for name in [NSApplication.willTerminateNotification, NSApplication.willResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.saveNow() }
            }
        }
        player.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        if let first = songsIn(currentPlaylist).first { select(first) }
    }

    // MARK: - library

    var playlists: [String] {
        Array(Set(songs.map(Library.playlist(of:)))).sorted { $0.localizedCompare($1) == .orderedAscending }
    }
    func songsIn(_ pl: String) -> [String] { songs.filter { Library.playlist(of: $0) == pl } }
    func songsIn(column i: Int) -> [String] {
        songsIn(currentPlaylist).filter { Library.column(of: $0) == i }
    }
    var showPlaylistPicker: Bool {
        let p = playlists
        return p.count > 1 || (p.count == 1 && p[0] != "")
    }

    /// Re-reads songs/ from disk. The app used to scan only at launch, so a folder dropped in
    /// while it was running simply never appeared — and there was nothing to press, unlike the
    /// web version's Cmd+R. Runs on window activation so returning from Finder is enough.
    func rescan() {
        let before = Set(playlists)
        let found = Library.scan()
        guard found != songs else { return }
        if found.isEmpty && !songs.isEmpty {
            flash("อ่านโฟลเดอร์ songs/ ไม่ได้ — ยังใช้รายการเดิมอยู่")
            return
        }
        songs = found
        let pls = playlists
        if !pls.contains(currentPlaylist) { currentPlaylist = pls.first ?? "" }
        // Name what turned up — a new round lands behind the picker and is easy to miss.
        let fresh = pls.filter { !before.contains($0) && !$0.isEmpty }
        if !fresh.isEmpty {
            flash("เจอรอบใหม่: " + fresh.joined(separator: ", ") + " — เลือกได้จากช่องด้านบน")
        }
        objectWillChange.send()
    }

    func setPlaylist(_ p: String) {
        currentPlaylist = p
        store.lastPlaylist = p
        store.settingsChanged()
        // Otherwise the centre pane keeps playing a song from the round you just left, and
        // Correct/Wrong logs it under THAT round's playlist.
        if let cur = current, Library.playlist(of: cur) == p { return }
        if let first = songsIn(p).first { select(first) } else { current = nil; analysis = nil }
    }

    // MARK: - selection

    /// Decoded envelopes, most-recently-used last. Holding ↓ through a round used to start one
    /// full-file decode per song, all at once and none cancelled, and re-opening a song decoded it
    /// again from scratch — the web version cached per file.
    private var analysisCache: [(path: String, a: Analysis)] = []
    private var analysisTask: Task<Void, Never>?
    private static let analysisCacheMax = 4

    func select(_ path: String) {
        current = path
        activeCol = Library.column(of: path)
        analysisTask?.cancel()
        player.load(url: Library.url(path))
        let c = store.config(for: path)

        if let hit = analysisCache.first(where: { $0.path == path })?.a {
            analysis = hit
            analysing = false
            refreshGain()
            player.seek(to: c.introStart, config: c)
            zoomIntro()
            return
        }
        analysis = nil
        analysing = true
        refreshGain()      // neutral/trim-only now; the detached analysis refines it below
        player.seek(to: c.introStart, config: c)
        zoomIntro()

        let url = Library.url(path)
        analysisTask = Task.detached(priority: .userInitiated) {
            let a = try? Analysis.analyse(url: url)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.current == path else { return }
                self.analysis = a
                self.analysing = false
                if let a { self.cache(a, for: path) }
                // Songs the GM hasn't marked yet get their Intro Start guessed from where the
                // music actually begins, so nobody opens a song whose intro is 8 s of silence.
                if let a, !self.store.config(for: path).isConfigured {
                    self.applyAutoStart(path, analysis: a, manual: false)
                }
                // Deliberately NOT re-zooming here: this fires after a full-file decode, so it
                // used to wipe whatever zoom the setter had already made while waiting.
                self.refreshGain()
            }
        }
    }

    func move(by d: Int) {
        let list = songsIn(column: activeCol)
        guard !list.isEmpty else { return }
        let i = current.flatMap { list.firstIndex(of: $0) } ?? -1
        select(list[max(0, min(list.count - 1, i + d))])
    }

    func moveColumn(by d: Int) {
        for step in 1...Library.columnLabels.count {
            let i = ((activeCol + d * step) % 3 + 3) % 3
            let list = songsIn(column: i)
            if let first = list.first { activeCol = i; select(first); return }
        }
    }

    // MARK: - config

    func config() -> SongConfig { current.map { store.config(for: $0) } ?? SongConfig() }

    /// Shortest intro the app will accept. A zero-length range made modeForPosition return .free
    /// for everything, which silently disarmed the intro-end guard — found in a real config.
    static let minIntro: Double = 0.5

    /// Marker edits only — trim/played must not count as "the GM configured this".
    /// `commit` is false for the continuous part of a drag: gain must not be rewritten per frame
    /// (it steps, and it clicks), so re-levelling waits for the release.
    func updateConfig(commit: Bool = true, _ mutate: (inout SongConfig) -> Void) {
        guard let p = current else { return }
        pushUndo(p)
        var c = store.config(for: p)
        mutate(&c)
        c.introStart = max(0, c.introStart)
        c.introEnd = max(c.introEnd, c.introStart + AppModel.minIntro)
        if player.duration > 0 { c.hook = min(max(0, c.hook), player.duration) }
        c.configured = true
        c.auto = false
        store.set(c, for: p)
        saveState = "saving…"
        if commit {
            refreshGain()                  // the intro range IS the measurement window
            player.remode(config: c)       // extending Intro End mid-play must re-arm the guard
        }
        objectWillChange.send()
    }

    /// Called when a drag ends — the point at which re-levelling and re-scheduling are safe.
    func commitConfig() {
        refreshGain()
        player.remode(config: config())
        objectWillChange.send()
    }

    /// Non-marker changes (trim, played, scope) — must not set `configured`.
    func updateConfigQuiet(_ mutate: (inout SongConfig) -> Void) {
        guard let p = current else { return }
        pushUndo(p)
        var c = store.config(for: p)
        mutate(&c)
        store.set(c, for: p)
        player.remode(config: c)   // ticking Ignore Intro End mid-play must extend the schedule
        objectWillChange.send()
    }

    func mark(_ key: WritableKeyPath<SongConfig, Double>) {
        let t = (player.position * 100).rounded() / 100
        if let f = MarkerField.times.first(where: { $0.timeKey == key }) { focusMarker = f }
        updateConfig { $0[keyPath: key] = t }
    }

    /// Note this takes focus even when the field is not a time: pressing `E` then `Shift+←` should
    /// not quietly move Intro Start because that was the last *time* field touched.
    func focus(_ f: MarkerField) {
        guard focusMarker != f else { return }
        focusMarker = f
        objectWillChange.send()
    }

    /// `M` — step the nudge target through the three markers.
    func cycleFocusMarker() {
        let all = MarkerField.times
        let i = all.firstIndex(of: focusMarker) ?? 0
        focusMarker = all[(i + 1) % all.count]
        flash("ปรับละเอียด: \(focusMarker.label)  (Shift+←/→)")
        objectWillChange.send()
    }

    /// `Shift+←/→`. Deliberately not guarded by the two-press rule: a 0.01 s step cannot put a
    /// song on camera, and a confirmation per 10 ms of movement would make the feature useless.
    func nudgeFocused(by d: Double) {
        guard current != nil, let k = focusMarker.timeKey else { return }
        updateConfig { $0[keyPath: k] = max(0, (($0[keyPath: k] + d) * 100).rounded() / 100) }
        flash(String(format: "%@ %.2fs", focusMarker.label, config()[keyPath: k]))
    }

    /// A typed `mm:ss.hh` (or plain seconds) value. Rejecting rather than clamping is deliberate:
    /// the caller restores the displayed text, so a typo leaves the marker where it was.
    func setMarkerTime(_ f: MarkerField, _ t: Double) {
        guard current != nil, let k = f.timeKey else { return }
        guard t.isFinite, t >= 0 else { return }
        focus(f)
        let v = player.duration > 0 ? min(t, player.duration) : t
        updateConfig { $0[keyPath: k] = (max(0, v) * 100).rounded() / 100 }
    }

    /// `G` — audition the hook for a few seconds and stop. See `Player.previewHook`.
    func previewHook() {
        guard current != nil else { return }
        cancelPending()
        focus(.hook)
        player.previewHook(config: config())
    }

    // MARK: - two-press confirmation while playing

    /// `I`/`O`/`H`/`E` are instant, silent and (until now) irreversible, and they sit on the same
    /// keyboard as the four keys the operator hammers during a take. `E` is the worst of them:
    /// keyCode 14 is next to `R` (15) and it disarms the intro-end stop outright, which plays the
    /// whole song on camera.
    ///
    /// So: while STOPPED they stay immediate — that is the setter's normal way of working, and
    /// the playhead is parked where they chose. While PLAYING the first press only proposes.
    func requestMark(_ f: MarkerField) {
        guard current != nil else { return }
        focus(f)
        guard player.isPlaying else { pending = nil; applyMark(f, at: player.position); return }
        if let pm = pending, pm.field == f {
            pendingTask?.cancel()
            pending = nil
            applyMark(f, at: pm.t)                 // the FIRST press's position, not this one
            pulse(PulseID.mark(f.label))
            return
        }
        pendingTask?.cancel()
        pending = PendingMark(field: f, t: player.position)
        objectWillChange.send()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppModel.pendingWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.pending?.field == f else { return }
                self.pending = nil                 // expires silently; nothing was committed
                self.objectWillChange.send()
            }
        }
    }

    func cancelPending() {
        guard pending != nil else { return }
        pendingTask?.cancel()
        pending = nil
        objectWillChange.send()
    }

    private func applyMark(_ f: MarkerField, at t: Double) {
        let v = (t * 100).rounded() / 100
        switch f {
        case .introStart: updateConfig { $0.introStart = v }
        case .introEnd:   updateConfig { $0.introEnd = v }
        case .hook:       updateConfig { $0.hook = v }
        case .ignoreEnd:  updateConfigQuiet { $0.ignoreEnd.toggle() }
        case .trimDb:     break
        }
    }

    // MARK: - the review sweep

    /// A song still needs the setter's eye: never opened, or `introStart` is the app's guess.
    /// Note `updateConfig` sets `configured` as a side effect of any marker write, so before this
    /// existed there was no way to say "that guess is right" without first changing it.
    func needsReview(_ path: String) -> Bool {
        guard let c = store.songs[path] else { return true }
        return c.auto || !c.isConfigured
    }
    var reviewRemaining: Int { songsIn(currentPlaylist).filter(needsReview).count }

    /// `Return` — accept the values as they stand. The one verb the sweep was missing.
    func confirmCurrent() {
        guard let p = current else { return }
        guard needsReview(p) else { flash("เพลงนี้ยืนยันแล้ว"); return }
        pushUndo(p, coalesce: false)
        var c = store.config(for: p)
        c.configured = true
        c.auto = false
        store.set(c, for: p)
        saveState = "saving…"
        objectWillChange.send()
        let left = reviewRemaining
        flash(left > 0 ? "ยืนยันแล้ว — เหลือ \(left) เพลง" : "ยืนยันครบทุกเพลงในรอบนี้ ✓")
        nextNeedingReview()
    }

    /// `Tab` — jump to the next song that still needs review, wrapping, across columns.
    func nextNeedingReview() {
        let list = songsIn(currentPlaylist)
        guard !list.isEmpty else { return }
        let start = current.flatMap { list.firstIndex(of: $0) } ?? -1
        for step in 1...list.count {
            let cand = list[(start + step % list.count + list.count) % list.count]
            if needsReview(cand) { select(cand); return }
        }
    }

    // MARK: - on-site edits

    var onsiteSongs: [String] {
        songsIn(currentPlaylist).filter { store.config(for: $0).hasOnsiteEdits }
    }
    var onsiteFieldCount: Int {
        songsIn(currentPlaylist).reduce(0) { $0 + store.config(for: $1).onsiteEdits.count }
    }

    func revert(_ f: MarkerField) {
        guard let p = current else { return }
        pushUndo(p, coalesce: false)
        var c = store.config(for: p)
        c.revert(f)
        store.set(c, for: p)
        saveState = "saving…"
        refreshGain()
        player.remode(config: c)
        if !player.isPlaying { player.seek(to: c.introStart, config: c) }
        objectWillChange.send()
        flash("คืนค่าเดิมของ \(f.label) แล้ว")
    }

    // MARK: - the intro-end guard, as a state the UI can show

    /// Would the intro-end stop fire if Start were pressed right now? The old status chip only
    /// rendered WHILE playing, so pausing past Intro End — or ticking `E` — left the disarmed
    /// state invisible in exactly the moment the operator decides to press Space.
    var introGuardArmed: Bool {
        let c = config()
        guard !c.ignoreEnd, c.introEnd > c.introStart else { return false }
        return Player.modeForPosition(player.position, c) == .intro
    }
    /// Seconds of intro left, for the countdown. nil when the guard is not armed.
    var secondsToIntroEnd: Double? {
        guard introGuardArmed else { return nil }
        return max(0, config().introEnd - player.position)
    }

    /// A bounded hook audition stops on its own, so the "⚠ ไม่หยุดเอง" warning must not fire
    /// during one. Crying wolf on a state that is in fact safe is how a real warning gets ignored.
    var previewArmed: Bool { player.previewRemaining != nil }

    /// Seconds until playback stops by itself, whichever bound is in force. nil means nothing
    /// will stop it — which is exactly what the amber strip is for.
    var secondsToStop: Double? { player.previewRemaining ?? secondsToIntroEnd }

    @discardableResult
    func applyAutoStart(_ path: String, analysis a: Analysis, manual: Bool) -> Bool {
        guard let t = a.detectIntroStart() else { return false }
        var c = store.config(for: path)
        let span = max(0.5, c.introEnd - c.introStart)     // keep the intro's length
        c.introStart = (t * 100).rounded() / 100
        c.introEnd = (min(a.duration, t + span) * 100).rounded() / 100
        if manual { c.auto = false; c.configured = true } else { c.auto = true }
        store.set(c, for: path)
        // Don't yank the playhead if the GM already pressed Start while analysis was running.
        if path == current && !player.isPlaying { player.seek(to: c.introStart, config: c) }
        objectWillChange.send()
        return true
    }

    func refreshGain() {
        let c = config()
        let r = player.applyGain(analysis: analysis, config: c,
                                 normalize: store.normalize, scope: store.loudnessScope)
        if !store.normalize { scopeNote = "ปิดการเกลี่ยอยู่" }
        else if r.usedScope == .intro { scopeNote = "วัดจากช่วง Intro จริง" }
        else if store.loudnessScope == .intro { scopeNote = "ช่วง Intro สั้น/เงียบเกิน — ใช้ทั้งเพลงแทน" }
        else { scopeNote = "วัดจากทั้งเพลง" }
    }

    // MARK: - zoom

    var viewSpan: Double { max(1e-4, viewEnd - viewStart) }
    var isZoomed: Bool { player.duration > 0 && viewSpan < player.duration - 0.01 }

    func zoomFit() { viewStart = 0; viewEnd = max(1, player.duration) }
    func clampView() {
        let d = player.duration
        guard d > 0 else { return }
        var span = min(max(viewSpan, Analysis.minSpan), d)
        if span > d { span = d }
        var s = viewStart
        if s + span > d { s = d - span }
        if s < 0 { s = 0 }
        viewStart = s; viewEnd = s + span
    }
    func zoom(factor: Double, focus: Double) {
        let d = player.duration
        guard d > 0 else { return }
        let span = viewSpan
        let frac = max(0, min(1, (focus - viewStart) / span))
        let next = min(max(span * factor, Analysis.minSpan), d)
        viewStart = focus - frac * next
        viewEnd = viewStart + next
        clampView()
    }
    func zoomBy(_ f: Double) {
        let t = player.position
        zoom(factor: f, focus: (t >= viewStart && t <= viewEnd) ? t : (viewStart + viewEnd) / 2)
    }
    func zoomIntro() {
        let c = config()
        let a = min(c.introStart, c.introEnd), b = max(c.introStart, c.introEnd)
        let pad = max(0.5, (b - a) * 0.35)
        viewStart = a - pad; viewEnd = b + pad
        clampView()
    }
    func pan(by dt: Double) { viewStart += dt; viewEnd += dt; clampView() }

    /// Keeps the playhead on screen a page at a time rather than scrolling continuously.
    func followPlayhead() {
        guard isZoomed, player.isPlaying else { return }
        let t = player.position, span = viewSpan
        if t < viewStart || t > viewEnd - span * 0.08 {
            viewStart = t - span * 0.15
            viewEnd = viewStart + span
            clampView()
        }
    }

    // MARK: - log

    private var resetAtCache: [String: Date] = [:]
    func rebuildResetCache() {
        resetAtCache = store.resetAt.compactMapValues { LogStore.isoParse($0) }
        invalidateStatus()
    }
    func resetAtDate(_ pl: String) -> Date? { resetAtCache[pl] }

    func isCurrentSession(_ e: LogEvent) -> Bool {
        guard let since = resetAtDate(e.playlist) else { return true }
        // An event we cannot date must NOT count as current — failing open is what made a stuck
        // badge look like "reset is broken".
        guard let d = e.date else { return false }
        return d > since
    }

    /// Derived from the log, scoped to the current taping — see `resetPlayed`.
    /// Cached: the song list calls this for every visible row on every redraw, and the list
    /// redraws at the tick rate while playing. Scanning the whole event list per row per frame
    /// was the app's hottest loop.
    private var statusCache: [String: SongStatus]?
    func invalidateStatus() { statusCache = nil }

    func status(of path: String) -> SongStatus? {
        if statusCache == nil {
            var m: [String: SongStatus] = [:]
            for e in logStore.events {
                guard isCurrentSession(e) else { continue }
                if e.isCorrect { m[e.path] = .correct }
                else if e.event == "wrong", m[e.path] == nil { m[e.path] = .wrong }
            }
            statusCache = m
        }
        return statusCache?[path]
    }

    /// `isARepeat` blocks a HELD key but not two taps: two `1`s 120 ms apart overlapped two
    /// correct stings on camera and wrote two log events. Audible, irreversible actions get a
    /// lockout; everything else keeps firing as fast as the operator can press.
    private var lastScoreAt: Date?
    static let scoreLockout: TimeInterval = 0.4

    func score(_ kind: String) {
        let now = Date()
        if let t = lastScoreAt, now.timeIntervalSince(t) < AppModel.scoreLockout { return }
        lastScoreAt = now
        playSE(kind == "correct" ? "correct.mp3" : "wrong.mp3")
        guard let p = current else { return }
        updateConfigQuiet { $0.played = true }
        logStore.append(playlist: Library.playlist(of: p), path: p, event: kind)
        invalidateStatus()
        objectWillChange.send()
    }

    func playSE(_ name: String) {
        let url = AppPaths.se.appendingPathComponent(name)
        guard let a = try? AVAudioPlayer(contentsOf: url) else { return }
        a.play()
        seNodes.append(a)
        if seNodes.count > 8 { seNodes.removeFirst() }
    }

    /// "Starting a new taping" for this round. The log itself is the tape's history and survives —
    /// instead of deleting events we remember when the new taping began, and the badges only count
    /// what happened after it.
    /// How many songs in this round currently read as "used" — the number `resetPlayed` would
    /// clear. The button checks this first so it never opens a confirmation for a no-op.
    var usedInRound: Int {
        songsIn(currentPlaylist).filter { store.config(for: $0).played || status(of: $0) != nil }.count
    }

    func resetPlayed() -> String {
        let scope = songsIn(currentPlaylist)
        let n = scope.filter { store.config(for: $0).played || status(of: $0) != nil }.count
        guard n > 0 else { return "ยังไม่มีเพลงที่ใช้ไปในรอบนี้" }
        for s in scope {
            var c = store.config(for: s)
            if c.played { c.played = false; store.set(c, for: s) }
        }
        store.resetAt[currentPlaylist] = LogStore.isoNow()
        store.settingsChanged()
        rebuildResetCache()
        objectWillChange.send()
        return "ล้างสถานะ \(n) เพลงแล้ว — log ยังเก็บไว้ครบ"
    }

    func pruneOrphans() -> String {
        // An unreadable songs/ returns [] from scan(), which would mark every entry an orphan and
        // delete the whole config. Never prune against an empty library.
        guard !songs.isEmpty else { return "อ่านโฟลเดอร์ songs/ ไม่ได้ — ไม่ได้ลบอะไร" }
        let n = store.pruneOrphans(existing: Set(songs))
        objectWillChange.send()
        return n == 0 ? "ไม่มีข้อมูลค้าง — สะอาดอยู่แล้ว" : "ลบข้อมูลเพลงที่ไม่มีไฟล์แล้ว \(n) รายการ"
    }

    var orphanCount: Int {
        let existing = Set(songs)
        return store.songs.keys.filter { !existing.contains($0) }.count
    }

    /// Same filename already marked up in another round? Offer to reuse that work.
    func donor(for path: String) -> String? {
        let b = Library.baseName(path)
        return songs.first { $0 != path && Library.baseName($0) == b && store.config(for: $0).isConfigured }
    }
    func copyConfig(from src: String) {
        guard let p = current else { return }
        let s = store.config(for: src)
        var d = store.config(for: p)
        d.introStart = s.introStart; d.introEnd = s.introEnd; d.hook = s.hook
        d.ignoreEnd = s.ignoreEnd
        if s.trimDb != 0 { d.trimDb = s.trimDb }
        d.configured = true; d.auto = false        // never `played` — that is per taping
        store.set(d, for: p)
        player.seek(to: d.introStart, config: d)
        refreshGain()
        objectWillChange.send()
    }

    /// Counted, not compared: two flashes with the SAME string made the first one's timer clear
    /// the second one early.
    private var toastSeq = 0
    func flash(_ msg: String) {
        toastSeq += 1
        let mine = toastSeq
        toast = msg
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard let self, self.toastSeq == mine else { return }
            self.toast = nil
        }
    }

    // MARK: - handover

    private var preflightTask: Task<Void, Never>?

    func openHandover() {
        showHandover = true
        runPreflight()
    }

    /// The cheap checks land immediately so the sheet opens without a spinner; the ones that need
    /// a decode per song fill in behind them.
    func runPreflight() {
        let round = currentPlaylist
        let paths = songsIn(round)
        preflight = Preflight.fast(round: round, paths: paths, store: store)
        preflightTask?.cancel()
        guard !paths.isEmpty else { preflightScanning = false; return }
        preflightScanning = true
        let st = store
        preflightTask = Task.detached(priority: .utility) {
            let extra = Preflight.silentIntros(paths: paths, store: st)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.preflightScanning = false
                // The setter may have switched rounds while this decoded.
                guard self.currentPlaylist == round else { return }
                self.preflight += extra
            }
        }
    }

    func doExport() -> String {
        let paths = songsIn(currentPlaylist)
        guard !paths.isEmpty else { return "รอบนี้ไม่มีเพลง" }
        do {
            let url = try Handoff.export(round: currentPlaylist, paths: paths,
                                         store: store, by: setterName)
            incoming = nil
            objectWillChange.send()
            return "เขียน \(RoundPackage.fileName) แล้ว — ส่งโฟลเดอร์ \(url.deletingLastPathComponent().lastPathComponent)/ ได้เลย"
        } catch {
            return "เขียนไฟล์ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    /// Looks for a `round.json` the current round has not taken in yet. Called on launch, on
    /// rescan and on window activation, because the usual way a round arrives is somebody copying
    /// a folder in while the app is open.
    func detectIncoming() {
        let url = RoundPackage.url(forRound: currentPlaylist)
        guard let pkg = RoundPackage.read(url) else { incoming = nil; return }
        let paths = songsIn(currentPlaylist)
        let plan = Handoff.plan(pkg, round: currentPlaylist, paths: paths, store: store)
        // Nothing to take in: every song already matches what the package says.
        if plan.fresh.isEmpty && plan.rows.isEmpty { incoming = nil; return }
        if incoming == nil { incomingDismissed = false }
        incoming = pkg
        objectWillChange.send()
    }

    func openImport() {
        let url = RoundPackage.url(forRound: currentPlaylist)
        guard let pkg = RoundPackage.read(url) else { flash("ไม่พบ \(RoundPackage.fileName)"); return }
        let plan = Handoff.plan(pkg, round: currentPlaylist, paths: songsIn(currentPlaylist), store: store)
        if !plan.hasChoices {
            Handoff.apply(plan, accepted: [], store: store)
            incoming = nil
            afterBulkChange()
            flash("รับโจทย์แล้ว \(plan.fresh.count) เพลง")
            return
        }
        acceptedRows = Set(plan.rows.map(\.id))   // default to taking the sender's values
        importPlan = plan
        objectWillChange.send()
    }

    func applyImport() {
        guard let plan = importPlan else { return }
        Handoff.apply(plan, accepted: acceptedRows, store: store)
        let n = acceptedRows.count
        importPlan = nil
        acceptedRows = []
        incoming = nil
        afterBulkChange()
        flash("รับมา \(n) รายการ — ที่ไม่รับยังเป็นค่าเดิมของเครื่องนี้")
    }

    /// After anything rewrites many songs at once: the undo stack describes a world that no
    /// longer exists, so drop it rather than let Cmd+Z restore half a round.
    private func afterBulkChange() {
        undoStack.removeAll()
        canUndo = false
        if let p = current {
            let c = store.config(for: p)
            refreshGain()
            player.remode(config: c)
            if !player.isPlaying { player.seek(to: c.introStart, config: c) }
        }
        saveState = store.saveState
        objectWillChange.send()
    }

    private func cache(_ a: Analysis, for path: String) {
        analysisCache.removeAll { $0.path == path }
        analysisCache.append((path, a))
        if analysisCache.count > AppModel.analysisCacheMax { analysisCache.removeFirst() }
    }
}
