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
    /// Which way the log reads. Running order is the default because that is the question people
    /// actually bring to it afterwards ("what did we open first?"); the raw event stream is for
    /// working out what happened when a row looks wrong.
    enum LogView { case running, events }
    @Published var logView: LogView = .running
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

    // MARK: - update state (§15)
    @Published var showAbout = false
    /// Set only when a feed named a build NEWER than this one. nil is the ordinary state.
    @Published var updateInfo: UpdateInfo?
    /// What the About sheet says under the version: progress, "up to date", or why it failed.
    @Published var updateState = ""
    @Published var updateChecking = false
    /// Cleared for the session when the operator waves the notice off. The durable half is
    /// `Store.dismissedUpdate` — see `dismissUpdateNotice()`.
    @Published var updateDismissed = false
    /// Latest-wins token. Without it, a check still in flight against the OLD feed could land
    /// after `setUpdateFeed` and publish a result — banner included — for a feed that is no
    /// longer configured. Same class as the web version's `loadWaveform` token (§12).
    private var updateTask: Task<Void, Never>?
    /// True when this bundle was launched from an unzipped RELEASE folder rather than an install.
    /// Computed once at startup, never from `body` — see `Updater.manifestLocation`.
    private(set) var launchedFromRelease = false

    // The in-app install (§15). Progress is -1 while the length is unknown.
    @Published var updateInstalling = false
    @Published var updateProgress: Double = 0
    @Published var updateStep = ""
    /// Set on the launch right after a successful update, so the operator gets told it worked.
    @Published var justUpdatedFrom: String?
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
    /// `G` pressed once while the intro is on air. Same reasoning as `pending` below: the key
    /// puts the chorus through the stage PA, and keyCode 5 sits next to `H` (4), which the setter
    /// does press mid-playback.
    /// One hundredth of a second: the precision markers are actually stored at. The ± buttons
    /// deliberately stay at 0.1 s — this is the step you cannot get from them or from a drag.
    static let nudgeStep: Double = 0.01
    /// Hard ceiling on any stored time, matching `Analysis`'s own implausible-duration limit.
    ///
    /// This is not cosmetic. `Store.round2` computes `(v * 100).rounded() / 100`, which overflows
    /// to **+infinity** for any finite `v` above ~1.8e306 — and `saveNow` then fails
    /// `isValidJSONObject` on EVERY later save, so the whole session's markers stop reaching disk
    /// with nothing naming the song at fault. `isFinite` on the input is not enough, because the
    /// input is finite; the multiply is what overflows.
    static let maxTime: Double = 4 * 3600
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
        // Launching the bundle straight out of an unzipped release is a natural thing to do
        // ("let me see if the new one works") and it has one cause and one fix, but it LOOKS
        // like §8c's "the app can't find my songs". Detected once, here, never from `body`.
        launchedFromRelease = FileManager.default.fileExists(
            atPath: AppPaths.root.appendingPathComponent("ติดตั้ง-อัปเดต.command").path)
        // The other half of the update loop. `lastRanVersion` is rewritten on every save, so a
        // difference here means this launch is the first on a new build.
        let seen = store.lastRanVersion
        if !seen.isEmpty, seen != AppVersion.short {
            justUpdatedFrom = seen
            // Clear the wave-off so a notice for the version we are now ON cannot linger.
            if store.dismissedUpdate == AppVersion.short {
                store.dismissedUpdate = ""
            }
            store.settingsChanged()
        }
        // So the installer can find this folder without asking the operator to navigate to it.
        InstallLocation.record()
        checkForUpdateOnLaunch()
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
        if let first = songsIn(p).first {
            select(first)
        } else {
            // An EMPTY round (a setter making `songs/EP06/` before copying files into it —
            // §8c says the app rescans on activation and names new rounds). Dropping `current`
            // while the player runs leaves `configProvider` answering with a DEFAULT config,
            // so the live guard silently switches to `introEnd: 15, ignoreEnd: false`: a song
            // deliberately set to ignore the stop gets cut at 15 s, and one whose playhead is
            // already past 15 takes `beginFade`'s "already late" branch — an instant cut and
            // the playhead jumping backwards. Stop first; nothing should be playing from a
            // round that no longer has a selected song.
            player.pause()
            current = nil
            analysis = nil
        }
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
            // Re-selecting a cached song must still be able to finish a guess that an earlier
            // visit did not. This branch used to `return` before reaching the guess at all, so
            // once a song had been looked at and arrowed past, nothing could ever guess it.
            if !c.isConfigured { guessRest(path, duration: hit.duration) }
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
                    // …and the rest of the guess behind it. Intro End and Hook need an FFT over
                    // the whole file, which is far too slow to do on every selection — holding
                    // ↓ through a round would start one per song — so it runs as its own task,
                    // only for songs nobody has set up, and only once (`autoGuessed`).
                    self.guessRest(path, duration: a.duration)
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
        // Upper bounds first, so the minIntro nudge below cannot push introEnd back over them.
        // `introEnd` had no upper bound at all before: setting introStart to the end of the song
        // sent introEnd to `duration + 0.5`, i.e. past the file.
        c.introStart = min(max(0, c.introStart), AppModel.maxTime)
        c.introEnd = min(max(0, c.introEnd), AppModel.maxTime)
        c.hook = min(max(0, c.hook), AppModel.maxTime)
        if player.duration > 0 {
            c.introStart = min(c.introStart, player.duration)
            c.introEnd = min(c.introEnd, player.duration)
            c.hook = min(c.hook, player.duration)
        }
        c.introEnd = max(c.introEnd, c.introStart + AppModel.minIntro)
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
        focusMarker = f      // @Published; an explicit objectWillChange here fires AFTER the write
    }

    /// `M` — step the nudge target through the three markers.
    func cycleFocusMarker() {
        let all = MarkerField.times
        // When focus sits on a non-time field (after `E`), start at the first marker rather than
        // stepping off a `?? 0` and silently skipping it.
        if let i = all.firstIndex(of: focusMarker) {
            focusMarker = all[(i + 1) % all.count]
        } else {
            focusMarker = all[0]
        }
        flash("ปรับละเอียด: \(focusMarker.label)  (Shift+←/→)")
    }

    /// `Shift+←/→`. Deliberately not guarded by the two-press rule: a 0.01 s step cannot put a
    /// song on camera, and a confirmation per 10 ms of movement would make the feature useless.
    func nudgeFocused(by d: Double) {
        guard current != nil else { return }
        guard let k = focusMarker.timeKey else {
            flash("ยังไม่ได้เลือก marker ที่จะขยับ — กด M เพื่อเลือก")
            return
        }
        // A pending `I`/`O`/`H` proposal holds the position of its FIRST press for 2.5 s, so
        // confirming it after a nudge would write that old value and silently discard the nudge.
        cancelPending()
        // `commit: false`, like the waveform drag: committing calls `player.remode`, which
        // re-schedules the node once the accumulated move passes 0.05 s — i.e. an audible dropout
        // every sixth keypress, during the one task this key exists for (listening to the cut).
        // The drag defers to `commitConfig()` on mouse-up; a key has no mouse-up, so it debounces.
        updateConfig(commit: false) { $0[keyPath: k] = max(0, (($0[keyPath: k] + d) * 100).rounded() / 100) }
        flash(String(format: "%@ %.2fs", focusMarker.label, config()[keyPath: k]))
        scheduleNudgeCommit()
    }

    private var nudgeCommitTask: Task<Void, Never>?
    /// Settle the level and the scheduled segment once the operator stops nudging.
    private func scheduleNudgeCommit() {
        nudgeCommitTask?.cancel()
        nudgeCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.commitConfig() }
        }
    }

    /// A typed `mm:ss.hh` (or plain seconds) value. Rejecting rather than clamping is deliberate:
    /// the caller restores the displayed text, so a typo leaves the marker where it was.
    func setMarkerTime(_ f: MarkerField, _ t: Double) {
        guard current != nil, let k = f.timeKey else { return }
        guard t.isFinite, t >= 0 else { return }
        // No duration means `AVAudioFile` could not open the file (Player.load) — reachable right
        // after a handover if audio was left behind. Refuse rather than write a time we cannot
        // check against anything; `round2` turns a big enough finite value into +infinity, after
        // which EVERY later save fails `isValidJSONObject` with nothing naming the song at fault.
        guard player.duration > 0 else {
            flash("ยังอ่านไฟล์เพลงนี้ไม่ได้ — ตั้งเวลาไม่ได้")
            return
        }
        focus(f)
        cancelPending()
        let ceiling = min(player.duration, AppModel.maxTime)
        updateConfig { $0[keyPath: k] = (min(max(0, t), ceiling) * 100).rounded() / 100 }
    }

    ///
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
        // Only a POSITION can be the nudge target. `E` used to set it to `ignoreEnd`, after which
        // `Shift+←/→` was a dead key and no card showed the hint saying why.
        if f.timeKey != nil { focus(f) }
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

    /// Seconds until playback stops by itself. nil means nothing will stop it — which is exactly
    /// what the amber strip is for.
    var secondsToStop: Double? { secondsToIntroEnd }

    /// Paths a full guess has already been attempted for this session, so arrowing back and
    /// forth does not re-run an FFT per visit. Recorded only once the work has actually
    /// FINISHED — marking before it starts, with a single shared task slot, meant holding ↓
    /// through a round marked every song done while cancelling all but the last, so Intro End
    /// and Hook were never guessed for any song except the one you stopped on. That is the
    /// entire point of the feature, silently not happening.
    private var autoGuessed = Set<String>()
    /// One task PER PATH, so arrowing on does not cancel a guess that is nearly finished.
    ///
    /// Cost is ~0.25 s per song in RELEASE. Be careful measuring this: the same pass takes
    /// ~5 s in a debug build, and `build.sh debug` is what sits in the tree while iterating —
    /// a figure read off a debug diagnostic is 20x out and would argue for a design this
    /// does not need.
    private var guessTasks: [String: Task<Void, Never>] = [:]

    /// Intro End and Hook, guessed. Everything it writes stays `auto`, so the song remains in
    /// the `Return`/`Tab` review sweep and in the pre-flight warnings until a human confirms it.
    ///
    /// `manual` runs it even for a configured song, pushes an undo entry first, and tells the
    /// operator what happened. The automatic pass is silent — a toast per song while arrowing
    /// through a round is noise.
    func guessRest(_ path: String, duration: Double, manual: Bool = false) {
        if !manual && autoGuessed.contains(path) { return }
        if guessTasks[path] != nil && !manual { return }
        guessTasks[path]?.cancel()
        let url = Library.url(path)
        guessTasks[path] = Task.detached(priority: .utility) { [weak self] in
            let f = AutoDetect.extract(url: url)
            if Task.isCancelled { return }
            guard let f else {
                await MainActor.run {
                    self?.guessTasks[path] = nil
                    if manual { self?.flash("วิเคราะห์เพลงนี้ไม่ได้") }
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.guessTasks[path] = nil
                self.autoGuessed.insert(path)
                self.applyGuess(path, features: f, duration: duration, manual: manual)
            }
        }
    }

    /// The write half, on the main actor.
    ///
    /// **It refuses while that song is on air.** This is the one rule here that is not a
    /// nicety: a background task moving Intro End under live playback is §10's forbidden
    /// shape. Measured on the real library, song 102's guess is 11.0 s against a stored 15.0 —
    /// so a guess landing ~5 s into a question would have cut the audio instantly and parked
    /// the playhead backwards (if it moved inward), or let the node run to the OLD boundary
    /// while the countdown read the new one (if it moved outward). Either way nobody pressed
    /// anything. A guess is a convenience; there is never a reason to apply one mid-question.
    private func applyGuess(_ path: String, features f: AutoDetect.Features,
                            duration: Double, manual: Bool) {
        if player.isPlaying && current == path {
            autoGuessed.remove(path)       // try again next time the song is selected
            if manual { flash("กำลังเล่นอยู่ — หยุดก่อนแล้วกด 🎯 อีกที") }
            return
        }
        // The song may have been set up while the FFT ran. Re-read, and re-check, HERE.
        let existing = store.config(for: path)
        guard !existing.isConfigured || manual else { return }

        // A round that has been signed off is past the point where guessing is anybody's job.
        // Without this, an imported round whose songs are still `auto` (the pre-flight warns
        // about that and deliberately does not block) gets its markers moved off `base` by a
        // robot — producing magenta "แก้ที่กอง" badges for edits nobody made, which the return
        // path then exports as the operator's decisions and the setter's diff sheet accepts by
        // default. §8e's whole audit trail, laundered.
        guard existing.base == nil || manual else { return }

        let end = AutoDetect.introEnd(features: f, from: existing.introStart)
        let hook = AutoDetect.hook(features: f, after: end)

        // **Fill blanks only.** `isConfigured` returns false whenever `auto` is true, which is
        // right for the green badge and WRONG as a licence to overwrite: the live config has
        // song 102 at `auto: true` with `hook: 62.03` — a number no default produces, so a
        // human put it there. It is `auto` only because `Store.decode` repaired its degenerate
        // intro range and demoted it. Overwriting that hook would have destroyed the one copy
        // of it in existence. So an automatic guess may only write a field that is still
        // exactly at its default; a manual 🎯 may write anything, but asks first (SetupPanel).
        let d = SongConfig.defaults
        let mayWriteEnd = manual || SongConfig.same(existing.introEnd, d.introEnd)
        let mayWriteHook = manual || SongConfig.same(existing.hook, d.hook)
        guard mayWriteEnd || mayWriteHook else { return }

        // Routed through the ordinary edit path so it inherits the clamps that keep
        // `introEnd >= introStart + minIntro` (§12: `introStart == introEnd` makes
        // `modeForPosition` return `.free` — the whole song on camera), the undo snapshot, and
        // `remode`. `store.set` direct was the only marker write in the app that skipped all
        // three.
        let wasConfigured = existing.configured
        withConfig(of: path) { c in
            if mayWriteEnd { c.introEnd = (min(duration, end) * 100).rounded() / 100 }
            if mayWriteHook, let h = hook {
                c.hook = (max(0, min(duration - 1, h.time)) * 100).rounded() / 100
            }
        }
        // `updateConfig` stamps `configured = true, auto = false` because a human edited. This
        // is not a human. Restore the truth: a guess leaves the song needing review — and for
        // a MANUAL run on an already-reviewed song, it must not silently un-review it either.
        var after = store.config(for: path)
        after.auto = !wasConfigured
        after.configured = wasConfigured
        store.set(after, for: path)
        invalidateStatus()

        // Only when this song is still the one on screen: the pass takes ~5.4 s, so a toast
        // naming times is otherwise read as describing whatever is in front of the operator now.
        if manual && current == path {
            flash(String(format: "เดา Intro End = %.2fs · Hook = %.2fs — ตรวจดูอีกที",
                         after.introEnd, after.hook))
        }
        objectWillChange.send()
    }

    /// Duration from the analysis cache, for a path that may no longer be selected.
    private func cachedDuration(_ path: String) -> Double? {
        analysisCache.first(where: { $0.path == path })?.a.duration
    }

    /// `updateConfig`, but for a named path rather than `current`. The guess finishes seconds
    /// after it started, and the selection may have moved on in the meantime — writing to
    /// `current` would then put one song's markers on another.
    private func withConfig(of path: String, _ mutate: (inout SongConfig) -> Void) {
        pushUndo(path, coalesce: false)
        var c = store.config(for: path)
        mutate(&c)
        c.introStart = min(max(0, c.introStart), AppModel.maxTime)
        c.introEnd = min(max(0, c.introEnd), AppModel.maxTime)
        c.hook = min(max(0, c.hook), AppModel.maxTime)
        if let d = cachedDuration(path), d > 0 {
            c.introStart = min(c.introStart, d)
            c.introEnd = min(c.introEnd, d)
            c.hook = min(c.hook, d)
        }
        c.introEnd = max(c.introEnd, c.introStart + AppModel.minIntro)
        c.configured = true
        c.auto = false
        store.set(c, for: path)
        saveState = "saving…"
        if current == path {
            refreshGain()
            player.remode(config: c)
        }
    }

    @discardableResult
    func applyAutoStart(_ path: String, analysis a: Analysis, manual: Bool) -> Bool {
        guard let t = a.detectIntroStart() else { return false }
        // §12 records `copyConfig(from:)` overwriting signed-off fields "in one click with no
        // undo entry" as a defect. This writes two markers; a manual run can write them over a
        // reviewed song, and 🎯 sits 8 pt from the `−`/`+` nudges.
        if manual { pushUndo(path, coalesce: false) }
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

    /// dB of the applied gain the output limiter will take back, > 0 only when the intro has
    /// less headroom than the gain asks for. Published so the level card and the pre-flight can
    /// both read it without recomputing.
    @Published var limiterEats: Double = 0

    func refreshGain() {
        let c = config()
        let r = player.applyGain(analysis: analysis, config: c,
                                 normalize: store.normalize, scope: store.loudnessScope)
        limiterEats = r.limiterEats
        if !store.normalize { scopeNote = "ปิดการเกลี่ยอยู่" }
        else if r.usedScope == .intro { scopeNote = "วัดจากช่วง Intro จริง (LUFS)" }
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
    private var takeCache: [Take]?
    private var orderCache: [String: [Int]]?
    func invalidateStatus() { statusCache = nil; takeCache = nil; orderCache = nil }

    /// The current taping's running order, scoped like the rest of the log panel.
    /// Cached for the same reason `status(of:)` is: the song list asks per row per frame.
    func takes() -> [Take] {
        if takeCache == nil {
            let evs = logStore.events.filter {
                (logAllRounds || $0.playlist == currentPlaylist) && isCurrentSession($0)
            }
            takeCache = Takes.build(evs)
        }
        return takeCache ?? []
    }

    /// Which positions in the running order this song occupied. More than one means it was
    /// revisited — a retake, which the old path-grouped summary silently hid.
    func takeOrders(of path: String) -> [Int] {
        if orderCache == nil {
            var m: [String: [Int]] = [:]
            for t in takes() { m[t.path, default: []].append(t.order) }
            orderCache = m
        }
        return orderCache?[path] ?? []
    }

    /// Jump to a song from a log row. Refuses while playing: the log is a pane now and can be
    /// open during a take, and `select()` loads a new file, which would cut the audio on air.
    func selectFromLog(_ path: String) {
        guard songs.contains(path) else {
            flash("ไม่พบไฟล์เพลงนี้ใน songs/ แล้ว")
            return
        }
        guard !player.isPlaying else {
            flash("กำลังเล่นอยู่ — กด Space หยุดก่อนถ้าจะเปิดเพลงนี้")
            return
        }
        if Library.playlist(of: path) != currentPlaylist { setPlaylist(Library.playlist(of: path)) }
        select(path)
    }

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

    func setLogAllRounds(_ v: Bool) {
        guard logAllRounds != v else { return }
        logAllRounds = v
        invalidateStatus()      // the take numbering is scoped to this filter
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
        // Overwrites five signed-off fields in one click and had no undo entry at all.
        pushUndo(p, coalesce: false)
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
    // MARK: - update (§15)

    /// Checks on launch, once, and only when a feed is configured.
    ///
    /// Deliberately not on a timer and never while playing: the only machine this runs on is a
    /// taping machine, and a network call is not something to be doing between a buzz and a
    /// pause. A manual check is in the About sheet for when the operator actually wants one.
    func checkForUpdateOnLaunch() {
        guard !store.updateFeed.isEmpty else { return }
        checkForUpdate(manual: false)
    }

    func checkForUpdate(manual: Bool) {
        let feed = store.updateFeed
        guard !feed.isEmpty else {
            updateState = "ยังไม่ได้ตั้งที่อยู่สำหรับเช็กเวอร์ชั่นใหม่"
            return
        }
        guard !updateChecking else { return }
        updateChecking = true
        updateState = "กำลังเช็ก…"
        updateTask?.cancel()
        updateTask = Task { @MainActor in
            defer { if !Task.isCancelled { updateChecking = false } }
            do {
                let info = try await Updater.check(feed: feed)
                // The feed may have been changed, or this check superseded, while we waited.
                guard !Task.isCancelled, feed == store.updateFeed else { return }
                if let info {
                    // A fresh find un-dismisses: waving off 1.2.0 must not hide 1.3.0.
                    if info.version != store.dismissedUpdate { updateDismissed = false }
                    updateInfo = info
                    updateState = info.needsNewerOS
                        ? "มีเวอร์ชั่นใหม่ \(info.version) — แต่เครื่องนี้ใช้ไม่ได้"
                        : "มีเวอร์ชั่นใหม่ \(info.version)"
                    if manual { flash(updateState) }
                } else {
                    updateInfo = nil
                    updateState = "ใช้เวอร์ชั่นล่าสุดอยู่แล้ว (\(AppVersion.short))"
                    if manual { flash("ใช้เวอร์ชั่นล่าสุดอยู่แล้ว") }
                }
            } catch {
                guard !Task.isCancelled, feed == store.updateFeed else { return }
                // Never a modal and never a toast on the automatic pass: a crew machine is
                // offline on set by design, so a failed check is the EXPECTED state there and
                // must not look like something went wrong with the app.
                updateState = "เช็กไม่ได้ — \(error.localizedDescription)"
                if manual { flash("เช็กเวอร์ชั่นไม่ได้") }
            }
        }
    }

    /// Download → verify → hand the swap to the installer → quit. It relaunches us.
    ///
    /// Three refusals before anything is downloaded, in order of how bad they are:
    /// **never while playing** (the swap ends in quitting the app, and a song is on camera),
    /// never onto a macOS the build cannot run on, and never from an unzipped release folder —
    /// there is no install there to update.
    func installUpdate() {
        guard let u = updateInfo, !updateInstalling else { return }
        if player.isPlaying {
            updateState = "หยุดเพลงก่อน แล้วค่อยกดอัปเดต — การอัปเดตต้องปิดแอป"
            return
        }
        if u.needsNewerOS {
            updateState = "เวอร์ชั่นนี้ต้องใช้ macOS \(u.minMacOS) — เครื่องนี้ใช้ไม่ได้"
            return
        }
        if launchedFromRelease {
            updateState = "แอปนี้เปิดจากโฟลเดอร์ที่แตก zip — ปิดแล้วรัน ติดตั้ง-อัปเดต.command แทน"
            return
        }
        guard u.openable != nil else {
            updateState = "ชุดอัปเดตนี้ไม่ได้บอกที่อยู่ไฟล์ — แจ้งคนดูแล"
            return
        }
        // Return/Space land on Cancel (§12). This one quits the app, so it earns the guard even
        // though the operator pressed the button that opened it.
        guard confirmDestructive(
            title: "อัปเดตเป็นเวอร์ชั่น \(u.version)?",
            body: "แอปจะโหลดไฟล์ ตรวจไฟล์ แล้ว **ปิดตัวเองเพื่อสลับตัวโปรแกรม** "
                + "และเปิดขึ้นมาใหม่ให้เอง\n\n"
                + "โจทย์ที่ตั้งไว้ · log การถ่าย · ไฟล์เพลง ไม่ถูกแตะ "
                + "และจะสำรองไว้ใน backups/ ก่อนเสมอ\n\n"
                + "อย่าทำตอนกำลังถ่าย",
            ok: "ปิดแอปแล้วอัปเดต") else { return }

        updateInstalling = true
        updateProgress = 0
        updateStep = "กำลังโหลดไฟล์…"
        updateState = ""
        Task { @MainActor in
            var scratch: URL?
            do {
                let dir = try Updater.scratch()
                scratch = dir
                // The callback arrives on the download's executor, not main, so hop
                // explicitly. Throttled to ~10/s inside fetchZip, so this is ~10 tasks a second.
                // No `[weak self]`: the enclosing Task already holds self strongly, and mixing
                // the two is what the ImplicitStrongCapture warning is about.
                let zip = try await Updater.fetchZip(u, into: dir) { f in
                    Task { @MainActor in self.updateProgress = f }
                }
                updateStep = "กำลังตรวจไฟล์ที่โหลดมา…"
                updateProgress = -1
                // Off the main actor: ditto on a 2 MB bundle plus running the staged binary is
                // ~1 s of synchronous work, and the window must not freeze during it.
                let staged = try await Task.detached(priority: .userInitiated) {
                    try Updater.stage(zip: zip, in: dir, expecting: u)
                }.value
                updateStep = "กำลังสลับตัวโปรแกรม…"
                // Flush before handing over. The installer waits for this process to exit, but
                // the debounced save would otherwise still be pending when it does.
                store.saveNow()
                try Updater.apply(staged: staged,
                                  target: AppPaths.root,
                                  waitPid: ProcessInfo.processInfo.processIdentifier)
                updateStep = "กำลังปิดแอป — เดี๋ยวมันจะเปิดขึ้นมาใหม่เอง"
                // Let the child reach its wait loop before we vanish.
                try? await Task.sleep(nanoseconds: 500_000_000)
                NSApp.terminate(nil)
            } catch {
                if let d = scratch { try? FileManager.default.removeItem(at: d) }
                updateInstalling = false
                updateProgress = 0
                updateStep = ""
                // Reported in the sheet, never as a toast: the toast is an overlay on the window
                // content, which a sheet covers.
                updateState = "อัปเดตไม่สำเร็จ — \(error.localizedDescription)"
            }
        }
    }

    /// Opens the installer's log. The only report an unattended failure can leave.
    func openUpdateLog() {
        let f = Updater.installLog
        if FileManager.default.fileExists(atPath: f.path) {
            NSWorkspace.shared.open(f)
        } else {
            updateState = "ยังไม่มี log การอัปเดต"
        }
    }

    // MARK: - cover art

    @Published var coverFetching = false
    @Published var coverProgress = ""
    /// Memoised disk reads. A `NSImage(contentsOf:)` per render would hit the filesystem at the
    /// player's tick rate; `.some(nil)` records "looked, not there" so a missing cover is not
    /// re-probed every frame either.
    private var coverCache: [String: NSImage?] = [:]

    private var coverLoading = Set<String>()

    /// Non-blocking. Reading embedded artwork opens an `AVURLAsset`, which is cheap but not
    /// free, and this is called from `body` — which re-renders at the player's tick rate. So a
    /// miss starts a background resolve and publishes when it lands; `.some(nil)` then records
    /// "looked, not there" so a song with no art is not re-probed every frame either.
    func cover(for path: String) -> NSImage? {
        if let hit = coverCache[path] { return hit }
        guard !coverLoading.contains(path) else { return nil }
        coverLoading.insert(path)
        Task.detached(priority: .utility) { [weak self] in
            let img = Artwork.resolve(for: path)
            await MainActor.run {
                guard let self else { return }
                self.coverLoading.remove(path)
                self.coverCache[path] = img
                self.trimCoverCache()
                if img != nil { self.objectWillChange.send() }
            }
        }
        return nil
    }

    private func forgetCover(_ path: String) {
        coverCache.removeValue(forKey: path)
    }

    /// One full-size `NSImage` per song ever selected adds up; `analysisCache` is capped at 4
    /// for the same reason. Keyed misses (`.some(nil)`) are cheap, so only images are counted.
    private static let coverCacheMax = 40
    private func trimCoverCache() {
        guard coverCache.count > AppModel.coverCacheMax else { return }
        // Cheap and good enough: drop the misses first, then clear. The next render re-resolves
        // whatever is on screen, which is one or two songs.
        coverCache = coverCache.filter { $0.value != nil }
        if coverCache.count > AppModel.coverCacheMax { coverCache.removeAll() }
    }

    /// Fetch covers for everything in the current round that has none.
    ///
    /// Explicitly a setter's action, never automatic: §1 says the app needs no internet, and a
    /// background fetch would make that false without anybody choosing it. Songs that already
    /// have a cover are skipped, so pressing it again after adding a few songs costs only those.
    private var coverTask: Task<Void, Never>?

    /// Stop a fetch in progress. A round of 60 with no embedded art is over three minutes of
    /// requests at `Artwork.gapSeconds`, and there was no way to abort it.
    func cancelCoverFetch() {
        coverTask?.cancel()
        coverTask = nil
        coverFetching = false
        coverProgress = ""
        objectWillChange.send()
    }

    func fetchCoversForRound() {
        guard !coverFetching else { return }
        // Never while a question is on air. §1 calls this machine offline by design, and the
        // installer's own in-app update refuses for the same reason.
        guard !player.isPlaying else { flash("กำลังเล่นอยู่ — หยุดก่อนแล้วค่อยดึงปก"); return }
        let round = currentPlaylist
        let candidates = songsIn(round)
        coverFetching = true
        coverProgress = "…"
        coverTask = Task { [weak self] in
            // `hasCover` opens an AVURLAsset and decodes an image to answer a Bool, so running
            // it for a whole round on the main actor beachballed the menu click. Off-main.
            let paths = await Task.detached(priority: .utility) {
                candidates.filter { !Artwork.hasCover($0) }
            }.value
            if Task.isCancelled { await MainActor.run { self?.cancelCoverFetch() }; return }
            guard !paths.isEmpty else {
                await MainActor.run {
                    self?.cancelCoverFetch()
                    self?.flash("มีปกครบทุกเพลงในรอบนี้แล้ว")
                }
                return
            }
            var done = 0, failed = 0
            var writeProblem: String?
            for p in paths {
                if Task.isCancelled { break }
                do { _ = try await Artwork.fetch(for: p); done += 1 }
                catch let e as Artwork.Failure {
                    failed += 1
                    // A failed WRITE is not a failed lookup. Reporting "หาไม่เจอ" for a
                    // read-only volume or a full disk is §12's `saveNow() -> "saved ✓"` again:
                    // the cheapest early signal that the folder holding config.json's siblings
                    // cannot be written, caught and relabelled. Stop rather than repeat it 60x.
                    if case .write = e { writeProblem = e.localizedDescription }
                } catch { failed += 1 }
                if writeProblem != nil { break }
                await MainActor.run {
                    guard let self else { return }
                    self.forgetCover(p)
                    self.coverProgress = "\(done + failed)/\(paths.count)"
                    self.objectWillChange.send()
                }
                // Spaced out on purpose — see `Artwork.gapSeconds`.
                try? await Task.sleep(nanoseconds: UInt64(Artwork.gapSeconds * 1_000_000_000))
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                self.coverTask = nil
                self.coverFetching = false
                self.coverProgress = ""
                if let w = writeProblem { self.flash("เขียนไฟล์ปกไม่ได้ — \(w)") }
                else if cancelled { self.flash("หยุดดึงปกแล้ว (ได้ \(done) เพลง)") }
                // Only when the operator is still looking at the round this was about.
                else if self.currentPlaylist == round {
                    self.flash(failed == 0 ? "ได้ปกเพลงครบ \(done) เพลง"
                                           : "ได้ปก \(done) เพลง · หาไม่เจอ \(failed) เพลง")
                }
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - theme

    var theme: AppTheme { store.theme }

    /// The appearance actually in force, for the header button's own glyph.
    var effectiveDark: Bool {
        switch store.theme {
        case .dark:  return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    func setTheme(_ t: AppTheme) {
        guard store.theme != t else { return }
        store.theme = t
        store.settingsChanged()
        applyTheme()
        objectWillChange.send()
    }

    /// One explicit tap: whatever is on screen now, give me the other one. The three-way choice
    /// (including "ตามระบบ") lives in About — a studio does not want a display setting that can
    /// change by itself behind one button.
    func toggleTheme() {
        setTheme(effectiveDark ? .light : .dark)
        flash("ธีม: \(store.theme.label)")
    }

    /// `NSApp.appearance` is what resolves the dynamic colours in `Palette`, and nil hands the
    /// decision back to the system. `ContentView` additionally sets `.preferredColorScheme` so
    /// SwiftUI's own environment agrees — without both, AppKit chrome and SwiftUI content can
    /// end up on different themes.
    func applyTheme() {
        switch store.theme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setUpdateFeed(_ s: String) {
        // Cancel first: an in-flight check against the previous feed must not be able to publish
        // its result — nor to leave `updateChecking` true, which disabled the very button the
        // operator needs to test the feed they just saved.
        updateTask?.cancel()
        updateTask = nil
        updateChecking = false
        store.updateFeed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settingsChanged()
        updateInfo = nil
        updateState = store.updateFeed.isEmpty ? "ปิดการเช็กเวอร์ชั่น" : ""
        objectWillChange.send()
    }

    /// Waving off a notice has to outlive the launch, because the condition does. See
    /// `Store.dismissedUpdate`.
    func dismissUpdateNotice() {
        updateDismissed = true
        if let v = updateInfo?.version { store.dismissedUpdate = v; store.settingsChanged() }
    }
    func dismissSchemaNotice() {
        store.dismissedSchema = store.schemaOnDisk
        store.settingsChanged()
        objectWillChange.send()
    }
    /// Is there anything in the news strip? Order is "what the operator must act on" first.
    var showUpdateNotice: Bool {
        guard let u = updateInfo else { return false }
        return !updateDismissed && u.version != store.dismissedUpdate
    }
    var showSchemaNotice: Bool {
        store.schemaAhead && store.dismissedSchema < store.schemaOnDisk
    }

    /// Opens the download in the browser, or reveals it in Finder when the feed is a synced
    /// folder and the zip is already on disk. Restricted to http/https/file by `UpdateInfo`.
    /// Returns nil on success, or a message to show INSIDE the sheet.
    ///
    /// It used to `flash()`, and the toast is an overlay on `ContentView` at `.top` — i.e. behind
    /// a sheet. So the one report for "the synced folder hasn't got the zip yet", which is the
    /// expected state on a crew machine, appeared nowhere and the button looked broken.
    @discardableResult
    func openUpdateDownload() -> String? {
        guard let u = updateInfo?.openable else {
            return "ที่อยู่ไฟล์ในชุดอัปเดตใช้ไม่ได้ — แจ้งคนดูแล"
        }
        if u.isFileURL {
            guard FileManager.default.fileExists(atPath: u.path) else {
                return "ยังไม่มีไฟล์ \(u.lastPathComponent) ในโฟลเดอร์นั้น — รอ Drive sync ให้เสร็จก่อน"
            }
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else {
            NSWorkspace.shared.open(u)
        }
        return nil
    }

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
