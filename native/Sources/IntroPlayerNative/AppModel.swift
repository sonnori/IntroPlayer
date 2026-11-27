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
    /// Which of the three list columns are folded to a rail (§8c). Asked for because the real
    /// round is **7 / 1 / 1**: `ColumnView` is `.frame(maxWidth: .infinity)` in an `HStack`, i.e.
    /// fixed thirds, so two thirds of the 898 pt pane were rendering two songs while seven shared
    /// the other third. Folding both gives `1xx` ~826 pt.
    ///
    /// **Dies with the process, and there is no `_settings` key for it on purpose** —
    /// `tagFilter`'s and `search`'s measured reason (§8g): a view state that hides questions and
    /// survives a relaunch is how an operator opens the app on a show day to a round that looks
    /// like most of its work is missing. §8c records that exact report against `lastPlaylist`.
    ///
    /// **It is a width, not a filter.** Nothing here touches `songsIn(_:)`, so the handover, the
    /// pre-flight and the `Return`/`Tab` review sweep are all untouched by a fold.
    @Published private(set) var collapsedCols: Set<Int> = []
    /// How the expanded columns divide the pane, as shares of the surplus above
    /// `ColumnLayout.minWidth` (see there — a fraction is NOT proportional to a width).
    ///
    /// Asked for as *"ลากตรงขอบเพื่อปรับขยาย"*. **Dies with the process, like the fold**, and the
    /// reason is weaker here than for the fold but goes the same way: a resized column still
    /// shows every one of its songs, so this cannot hide work the way `collapsedCols` could —
    /// `ColumnLayout.minWidth` is what guarantees that. Session-only is the conservative default
    /// and persisting it is one `_settings` key if it turns out to be wanted.
    @Published private(set) var colFractions: [Double] = ColumnLayout.evenFractions(3)
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
    /// The window's width, as the layout last reported it. Every pane width derives from this,
    /// so it replaces the old window-wide `isWide` step function: **each pane now decides its own
    /// internal layout from ITS OWN width**, which is what makes dragging the dividers work
    /// rather than merely resize things.
    @Published var windowWidth: CGFloat = 1600

    /// The width of the LEFT pane. **The song list and the log pane share that slot, so they must
    /// share this number**, and the whole point of it being a function is that they cannot drift.
    ///
    /// They were both 780 until the list was widened to 900 on request ("มัน width แคบไป") and
    /// the log pane was left behind — so `L` moved the centre pane by **120 pt**: the waveform,
    /// the playhead, every marker, the transport row and ✓ Correct / ✗ Wrong all jumped sideways,
    /// on a key the operator presses *during a take* to check the running order. §12 records that
    /// exact class three times over — the transport buttons that slid when playback started (a
    /// click aimed at Reset could land on Reveal), the conditional focus-hint line, the cover
    /// frame that appeared and disappeared — and it is the one this project keeps re-learning.
    /// Two literals in two files is how it came back.
    /// Resolved from `store.paneSplit` and the window, with `PaneLayout.floors` in force.
    ///
    /// Still **one** number for the list and the log pane, which is what the paragraph above is
    /// about: it is a computed property now instead of a function, and the two call sites read
    /// the same one.
    private var paneWidths: [CGFloat] {
        PaneLayout.widths(fractions: store.paneSplit,
                          total: windowWidth - PaneEdge.width * CGFloat(PaneLayout.count - 1))
    }
    var listWidth: CGFloat { paneWidths[0] }
    var centreWidth: CGFloat { paneWidths[1] }
    var setupWidth: CGFloat { paneWidths[2] }

    /// Three columns side by side need room; below this the list is one scroller with the groups
    /// as pinned headers. **Keyed on the LIST's width, not the window's** — that is the whole
    /// difference, and it is why dragging the list wider can now bring the columns back on a
    /// screen that could never reach the old 1900 pt window breakpoint.
    static let listColumnsFrom: CGFloat = 700
    var listShowsColumns: Bool { listWidth >= AppModel.listColumnsFrom }
    /// The centre pane's own threshold, for the waveform legend. Same principle.
    var centreIsWide: Bool { centreWidth >= 700 }

    /// Written from inside a layout pass, so it defers exactly like `setWide` did.
    func setWindowWidth(_ w: CGFloat) {
        guard abs(w - windowWidth) > 0.5 else { return }
        Task { @MainActor in self.windowWidth = w }
    }

    func dragPaneEdge(after i: Int, by dx: CGFloat) {
        guard let next = PaneLayout.drag(after: i, dx: dx, fractions: store.paneSplit,
                                         total: windowWidth
                                                - PaneEdge.width * CGFloat(PaneLayout.count - 1))
        else { return }
        store.paneSplit = next
        store.settingsChanged()
        objectWillChange.send()
    }

    func resetPaneWidths() {
        store.paneSplit = PaneLayout.defaultFractions
        store.settingsChanged()
        objectWillChange.send()
        flash("คืนความกว้างสามแผงเป็นค่าเริ่มต้น")
    }
    /// Which on-screen button is flashing because its keyboard shortcut just fired.
    @Published var pulseID: String?
    private var pulseTask: Task<Void, Never>?

    // MARK: handover surfaces
    @Published var showHandover = false
    @Published var preflight: [PreflightItem] = []
    @Published var preflightScanning = false
    @Published var importPlan: ImportPlan?
    @Published var acceptedRows: Set<String> = []
    /// EVERY round whose folder holds a `round.json` this library has not taken in yet.
    ///
    /// A list, and that is the whole fix: `detectIncoming` used to read `currentPlaylist` only,
    /// so three setters each handing a folder over raised the receive banner for whichever round
    /// happened to be selected and the other two sat unimported with nothing on screen saying
    /// so. Invisible with one setter; two thirds of the work with three.
    @Published private(set) var incomingRounds: [IncomingRound] = []
    /// Items the operator has waved off this session, keyed by `IncomingRound.id` — the folder
    /// PLUS the export time. Per item rather than one flag, because a single flag is the same
    /// defect as a single `incoming`: “ไว้ก่อน” on one round must never hide another round's
    /// arrival. Session-only on purpose; the cue that survives a relaunch AND a dismissal is the
    /// 📥 the playlist picker puts on each pending round.
    @Published private(set) var dismissedIncoming: Set<String> = []

    /// The waiting package for the round on screen. **Derived** — `pending` is the single piece
    /// of state, where the old `incoming` was assigned from four different places and cleared
    /// from three.
    var incoming: IncomingRound? { incomingRounds.first { $0.round == currentPlaylist } }
    /// What the strip shows for this round: nil once waved off.
    var incomingVisible: IncomingRound? {
        guard let i = incoming, !dismissedIncoming.contains(i.id) else { return nil }
        return i
    }
    /// Rounds waiting that are NOT the one on screen — exactly what the single-round check could
    /// not see.
    var incomingElsewhere: [IncomingRound] {
        incomingRounds.filter { $0.round != currentPlaylist && !dismissedIncoming.contains($0.id) }
    }
    /// Drives the picker's mark. Not filtered by `dismissedIncoming`: a wave-off hides the strip,
    /// not the fact that a folder is still unimported.
    func hasIncoming(_ round: String) -> Bool { incomingRounds.contains { $0.round == round } }

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
    /// Running straight off the mounted .dmg instead of from /Applications. The new shape of the
    /// same mistake `launchedFromRelease` catches: double-clicking the app in the installer
    /// window is the most natural thing in the world, and it leaves the operator editing a copy
    /// that vanishes when the disk is ejected. Nothing else in the app can tell them why.
    private(set) var launchedFromDMG = false

    // The in-app install (§15). Progress is -1 while the length is unknown.
    @Published var updateInstalling = false
    @Published var updateProgress: Double = 0
    @Published var updateStep = ""
    /// Set on the launch right after a successful update, so the operator gets told it worked.
    @Published var justUpdatedFrom: String?
    /// Live edit buffer for the name stamped into `round.json` as `by`. The durable value is
    /// `Store.setterName`; `commitSetterName()` is the only thing that moves one to the other.
    ///
    /// **Deliberately not written on every keystroke.** `Store.clampName` trims, so a
    /// write-through binding would eat the space the moment you typed it and you could not type
    /// a name with one in it. (The marker fields' commit-on-Return rule in §11 is about undo
    /// snapshots and clamps dragging the other marker — neither applies here; this is simply
    /// what a trimming clamp requires.)
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
    /// Which marker `←`/`→` nudges. Follows whatever the setter last touched — a drag, an
    /// `I`/`O`/`H`, a typed value or a ± press — so the nudge always means "the one I am working
    /// on" without a mode anybody has to remember. `M` cycles it explicitly.
    @Published var focusMarker: MarkerField = .introStart
    /// `G` pressed once while the intro is on air. Same reasoning as `pending` below: the key
    /// puts the chorus through the stage PA, and keyCode 5 sits next to `H` (4), which the setter
    /// does press mid-playback.
    /// One hundredth of a second: the precision markers are actually stored at. The ± buttons
    /// deliberately stay at 0.1 s — this is the step you cannot get from them or from a drag.
    static let nudgeStep: Double = 0.01
    /// `Shift` + `←`/`→`, on request — Unity's "hold Shift to go faster". **0.1 s, which is the
    /// number the `±` buttons already use**, so the app has two step sizes rather than three and
    /// the keyboard agrees with the buttons. 10×, which is also Unity's multiplier.
    ///
    /// It costs a property §11 used to lean on: at 0.01 s against a playhead advancing 1 s per
    /// second you could not outrun the playhead by holding the key. At 0.1 s against a ~30 ms
    /// autorepeat you can — roughly **3.3 s of marker movement per second of real time**, either
    /// direction, during playback. Nothing becomes unsafe, because that was never the protection:
    /// §10's `remode` may only ARM the intro-end guard and never disarm it, so pulling Intro End
    /// behind the playhead holds `.intro` and `beginFade`'s "already late" branch cuts at once,
    /// and `Player.boundRunsOutEarly` still commits immediately near the boundary. What changes
    /// is that the correct behaviour is now reachable in a fraction of a second.
    /// `nonisolated` so `--remodetest`, which runs off the main actor, can pin the real
    /// constant instead of a literal that would drift from it.
    nonisolated static let nudgeStepCoarse: Double = 0.1
    /// A folded column's rail. `Library.columnShort`'s widest entry measures 29.78 pt at 12 pt
    /// bold, so this is that plus padding — see there for why the label is not rotated.
    nonisolated static let collapsedColWidth: CGFloat = 36
    /// Hard ceiling on any stored time, matching `Analysis`'s own implausible-duration limit.
    ///
    /// This is not cosmetic. `Store.round2` computes `(v * 100).rounded() / 100`, which overflows
    /// to **+infinity** for any finite `v` above ~1.8e306 — and `saveNow` then fails
    /// `isValidJSONObject` on EVERY later save, so the whole session's markers stop reaching disk
    /// with nothing naming the song at fault. `isFinite` on the input is not enough, because the
    /// input is finite; the multiply is what overflows.
    // `nonisolated` for the same reason as `clampMarkers`: these are constants, and the clamp
    // has to be callable without a main actor so `--guesstest` can prove it.
    nonisolated static let maxTime: Double = Store.maxMarker   // one source, no drift
    /// 2 s is tight for someone watching the stage rather than the screen; the only cost of a
    /// longer window is a longer-lived ghost marker.
    static let pendingWindow: Double = 2.5

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

    /// One line about the launch snapshot, for About. nil when there is nothing to say.
    @Published var snapshotNote: String?

    init() {
        // **Captured FIRST, synchronously, before anything else in this initialiser can save.**
        // The value of a launch snapshot is the state as it was before this run; reading it
        // asynchronously would race `store`'s own first write and could preserve the result
        // instead of the input. Only the WRITING is moved off the main thread.
        let shot = Snapshot.capture()
        songs = Library.scan()
        let pls = playlists
        currentPlaylist = pls.contains(store.lastPlaylist) ? store.lastPlaylist : (pls.first ?? "")
        setterName = store.setterName
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
        // Before anything renders: `ShowLogo.prepared` is a lazy `static let` loaded once per
        // process (§6e), so a logo copied out after the header has drawn would not appear until
        // the next launch. Nothing has touched it yet at this point.
        Seeding.run()
        Seeding.placeScripts()
        rebuildResetCache()
        if let shot { writeSnapshot(shot) }
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
        // `programRoot`, not the data root: the question is whether the BUNDLE is sitting in
        // an unzipped release, which is a fact about where the app was launched from. Kept for
        // machines mid-migration — a classic-layout folder still has that file in it.
        launchedFromRelease = FileManager.default.fileExists(
            atPath: AppPaths.programRoot.appendingPathComponent("ติดตั้ง-อัปเดต.command").path)
        // A read-only mounted image is `/Volumes/<name>`. Checked on the real bundle path rather
        // than on a volume list, because that is the thing that actually goes away on eject.
        launchedFromDMG = AppPaths.programRoot.path.hasPrefix("/Volumes/")
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
    /// Every song in the round. **This is the round**, and it is what the header counts, the
    /// review sweep, the handover and the pre-flight must keep using — see `visibleSongs`.
    func songsIn(_ pl: String) -> [String] { songs.filter { Library.playlist(of: $0) == pl } }

    // MARK: - the tag filter (§8g)

    /// Which tag the song LIST is narrowed to. Empty = off.
    ///
    /// **Deliberately not persisted.** A filter that survives a relaunch is how an operator
    /// opens the app on a show day to a round missing two thirds of its questions, with the
    /// reason in a strip they have not learned to read yet. §8c measured that exact failure for
    /// `_settings.lastPlaylist` — the scan finds the round, the picker lists it, the app opens
    /// somewhere else, and it was reported from real use as "the app can't find my songs". A
    /// filter is the same trap with a weaker hint, so it dies with the process.
    @Published private(set) var tagFilter = ""

    /// Free-text narrowing of the song LIST by filename — "หาเพลงที่อยากเล่น". Empty = off.
    ///
    /// **Dies with the process, exactly like `tagFilter` and for the identical measured
    /// reason** (§8c): a narrowing that survives a relaunch is how an operator opens the app on
    /// a show day to a round missing most of its questions, which was reported from real use as
    /// "the app can't find my songs".
    @Published private(set) var search = ""
    /// Whether the search row is on screen. Separate from `search` being empty, because the row
    /// has to exist before anything has been typed into it.
    @Published private(set) var searching = false
    /// Whether the SEARCH field specifically holds first responder. Not `@Published` — only the
    /// key monitor reads it, and no view needs to re-render on it. It exists so Esc can close
    /// the search in one press from inside its own field while still meaning plain "blur" in
    /// every other field (the note field and the search row can be open at the same time).
    var searchFieldFocused = false
    /// A ONE-SHOT, consumed by the search row's `.onAppear`. The autofocus belongs to the ACT of
    /// opening the row, not to the row appearing — and those are not the same event.
    ///
    /// `ContentView` renders `if model.showLog { LogPanel() } else { SongListView() }`, and the
    /// two branches of a `ViewBuilder` `if` have separate view identities, so toggling the log
    /// **remounts the whole song list** and refires every `onAppear` inside it. With the focus
    /// unconditional there, `/` → type → `Return` (which drops focus on purpose) → `L` → `L`
    /// put first responder back in the search field with nobody having touched it, which turns
    /// the key monitor's `typing` branch on: `S`, `R`, `T`, `E`, `I`/`O`/`H`, `M`, `L`, `Tab`,
    /// `Return` and the arrows all stop working, with the row looking exactly as it did. §12
    /// records that a dead shortcut which cannot be told from a working one is the defect, and
    /// "search a song, open the log to check the running order, close it" is an ordinary
    /// sequence in the middle of a taping.
    var searchWantsFocus = false

    func openSearch() {
        guard !searching else { return }
        searching = true
        searchWantsFocus = true
        objectWillChange.send()
    }

    /// Closing CLEARS the term. The row and the narrowing are one thing: a hidden control still
    /// filtering the list is the §8c trap with the explanation taken away.
    func closeSearch() {
        guard searching || !search.isEmpty else { return }
        searching = false
        search = ""
        objectWillChange.send()
    }

    /// Unlike `setTagFilter`, this does **not** refuse a term that matches nothing. Every
    /// keystroke on the way to a word passes through states that match nothing, so refusing
    /// would make the field unusable; the strip says "ไม่เจอ" instead, and names the other
    /// rounds that do match.
    func setSearch(_ t: String) {
        let next = String(t.prefix(80))
        guard next != search else { return }
        search = next
        objectWillChange.send()
    }

    func matchesSearch(_ path: String) -> Bool {
        search.isEmpty || Library.matches(path, search)
    }

    /// Return in the search field: take the first match, then hand the keyboard back so ↑/↓ walk
    /// the rest. `select` sets `activeCol` from the song it opens, so the column navigation lands
    /// on the matches rather than wherever you were — and `[`/`]` already skip columns with none.
    func commitSearch() {
        guard !search.isEmpty else { closeSearch(); return }
        guard let first = visibleSongs(currentPlaylist).first else {
            let other = searchElsewhere()
            flash(other.isEmpty
                  ? "ไม่เจอ \"\(search)\" ในรอบนี้"
                  : "ไม่เจอในรอบนี้ — แต่มีใน " + other.map { "\(Library.label($0.round)) (\($0.count))" }
                        .joined(separator: ", "))
            return
        }
        // Same refusal as a log row (§8d): `select` loads a different file, which cuts the audio
        // on air. Narrowing the list is free; opening a song is not.
        guard !player.isPlaying else {
            flash("กำลังเล่นอยู่ — กด Space หยุดก่อนถ้าจะเปิดเพลงนี้")
            return
        }
        select(first)
    }

    /// Rounds OTHER than this one holding a match. An empty result that does not say "it is in
    /// EP02" is §8c's "the app can't find my songs" wearing a search box.
    func searchElsewhere() -> [(round: String, count: Int)] {
        guard !search.isEmpty else { return [] }
        let t = Library.searchTokens(search)
        guard !t.isEmpty else { return [] }
        return playlists.compactMap { r in
            guard r != currentPlaylist else { return nil }
            let n = songsIn(r).filter { Library.matches($0, tokens: t) }.count
            return n > 0 ? (r, n) : nil
        }
    }

    func setTagFilter(_ t: String) {
        let next = Store.clampTag(t) ?? ""
        guard next != tagFilter else { return }
        // Refuse a filter that would show nothing. The menu only offers tags present in this
        // round, so this is unreachable from the UI — which is exactly why it belongs here
        // rather than there: "the selection can never be hidden" should be true by
        // construction, not because one caller happens to behave.
        if !next.isEmpty,
           Library.visible(songsIn(currentPlaylist), tag: next, store: store).isEmpty {
            flash("รอบนี้ไม่มีเพลงที่ติดแท็ก \"\(next)\"")
            return
        }
        tagFilter = next
        // Keep the selection inside what is on screen, so ↑/↓ cannot walk out of the list.
        // `select` cannot undo this: `first` is visible under the filter we just set.
        if let cur = current, !next.isEmpty, !matchesTagFilter(cur),
           let first = visibleSongs(currentPlaylist).first {
            select(first)
        }
        objectWillChange.send()
    }

    func clearTagFilter() {
        guard !tagFilter.isEmpty else { return }
        tagFilter = ""
        objectWillChange.send()
    }

    func matchesTagFilter(_ path: String) -> Bool {
        tagFilter.isEmpty || !Library.visible([path], tag: tagFilter, store: store).isEmpty
    }

    /// The songs the LIST shows, which is a different question from "the songs in this round".
    ///
    /// A separate accessor, and the unfiltered column variant is **gone** rather than kept
    /// beside it, because of what the 26 `songsIn(` call sites are: only four are the list and
    /// its navigation. The rest are `Handoff.export`/`plan`/`apply`, `Preflight.fast`,
    /// `reviewRemaining`, `onsiteFieldCount`, `resetPlayed`, `usedInRound` and every header
    /// count — so filtering inside `songsIn(_:)` would have quietly handed a round over with
    /// two thirds of its questions missing. Now the only way to do that is to type
    /// `visibleSongs` somewhere it does not belong, which is a visible mistake.
    func visibleSongs(_ pl: String) -> [String] {
        Library.visible(songsIn(pl), tag: tagFilter, search: search, store: store)
    }
    func visibleSongs(column i: Int) -> [String] {
        visibleSongs(currentPlaylist).filter { Library.column(of: $0) == i }
    }
    /// How many of the round is hidden right now, by the tag filter and the search together —
    /// the number both strips show, because a narrowing that does not say what it hides is
    /// indistinguishable from missing files (§8c). One number, so the two strips cannot disagree.
    var hiddenCount: Int {
        songsIn(currentPlaylist).count - visibleSongs(currentPlaylist).count
    }
    /// Tags actually present in this round, with their counts. Only these are offered, so
    /// picking one can never produce an empty list.
    func tagCounts(inRound pl: String) -> [(tag: String, count: Int)] {
        let paths = songsIn(pl)
        return store.tagsInUse.compactMap { t in
            let n = Library.visible(paths, tag: t, store: store).count
            return n > 0 ? (t, n) : nil
        }
    }
    var showPlaylistPicker: Bool {
        let p = playlists
        return p.count > 1 || (p.count == 1 && p[0] != "")
    }

    /// Re-reads songs/ from disk. The app used to scan only at launch, so a folder dropped in
    /// while it was running simply never appeared — and there was nothing to press, unlike the
    /// web version's Cmd+R. Runs on window activation so returning from Finder is enough.
    /// `force` is for a data-root switch and nothing else. The two guards below exist because a
    /// routine rescan that comes back empty almost always means `songs/` could not be read, and
    /// keeping the old list is then right (§12). After a root switch both guards are wrong: the
    /// new library legitimately holds different songs, possibly none at all, and keeping the old
    /// round's list would leave the operator looking at songs that are no longer anywhere.
    func rescan(force: Bool = false) {
        let before = Set(playlists)
        let found = Library.scan()
        guard force || found != songs else { return }
        if !force, found.isEmpty && !songs.isEmpty {
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

    /// §5c's launch snapshot, detached. Factored out of `init` so a data-root switch can take one
    /// too — otherwise the only pre-run copy a session holds is of the library it LEFT, and the
    /// one it moved into would be edited with no snapshot until the next launch. §5c's promise is
    /// "the state before this run touched anything", and after a switch this run has not touched
    /// the new library yet, so the moment is still right.
    private func writeSnapshot(_ shot: (config: Data, log: Data?)) {
        let version = AppVersion.short, mirror = store.backupDir
        Task.detached(priority: .utility) { [weak self] in
            let r = Snapshot.write(shot, version: version, mirrorTo: mirror)
            guard let note = Snapshot.summary(r) else { return }
            let model = self
            await MainActor.run {
                // About only. §8f's rule: on a show day a backup that cannot write must not
                // produce a dialog, a toast or a retry — and a backup that DID write is not
                // news worth a banner either.
                model?.snapshotNote = note
            }
        }
    }

    /// Point the app at a different library (§5, the DMG work). Returns nil on success, or the
    /// reason in Thai.
    ///
    /// Four things in here are load-bearing, and three of them are about not losing the library
    /// you are LEAVING:
    ///
    /// - **Refused while playing.** This tears down the song list and reloads the store; doing it
    ///   under live playback is the shape §10 spends itself preventing, and the operator cannot
    ///   hear a folder change.
    /// - **The old store is flushed FIRST, to the old root.** The save is debounced 250 ms, so a
    ///   marker edited a moment ago is still pending — and after `setRoot` it would land in the
    ///   NEW folder, writing one library's markers into another. Same debounce that §12 records
    ///   losing an edit at quit.
    /// - **Guesses are cancelled.** An in-flight `AutoDetect` task finishes with a main-actor hop
    ///   that writes by PATH, and a path means a different song once the root moves (§7a4).
    /// - **Every per-path cache is dropped.** `analysisCache` and `coverCache` are keyed by the
    ///   path under `songs/`, which is not unique across libraries: `EP01/101.mp3` exists in both
    ///   and would otherwise draw one library's waveform for another's audio. §8f records the
    ///   same defect when the cover cache dropped the extension.
    @discardableResult
    func switchDataRoot(to url: URL, create: Bool = false) -> String? {
        if player.isPlaying { return "หยุดเพลงก่อนเปลี่ยนโฟลเดอร์งาน" }
        let from = AppPaths.root
        if url.standardizedFileURL == from.standardizedFileURL, AppPaths.hasRoot { return nil }
        cancelGuesses()
        cancelPending()
        // `store` is debounced; `LogStore.append` writes immediately and re-reads first, so it
        // has nothing pending — do not add a flush there that does not exist.
        store.saveNow()
        if let err = create ? AppPaths.createLibrary(url) : AppPaths.setRoot(url) { return err }
        player.pause()          // a no-op when stopped, which the guard above guarantees
        current = nil
        analysisCache.removeAll()
        coverCache.removeAll()
        tagFilter = ""
        closeSearch()
        collapsedCols.removeAll()   // a fold describes the library being left, same as the filter
        colFractions = ColumnLayout.evenFractions(Library.columnLabels.count)
        // Both describe the folder being LEFT. `IncomingRound.id` is round name + export time,
        // and round names repeat across libraries (`EP01` exists in both), so a stale list makes
        // the strip and the picker's 📥 answer for the wrong folder: a round genuinely waiting
        // here stays invisible until the next window activation, which is §8e's measured
        // "เห็น 1 จาก 3 — หาย 2 ชุด" reached through a different door. `detectIncoming` below
        // refills them from this library.
        //
        // Nothing can be written across libraries by this — `openImport` re-reads
        // `RoundPackage.url(forRound:)` under the NEW `AppPaths.root` — so the cost is what is
        // on screen, not the questions. Same family as every per-path cache above it.
        incomingRounds = []
        dismissedIncoming = []
        store.load()
        logStore.load()
        invalidateStatus()
        currentPlaylist = store.lastPlaylist
        // The buffer belongs to the library we just loaded, not the one we left — otherwise the
        // previous folder's name would be stamped into this one's next handover.
        setterName = store.setterName
        rescan(force: true)
        let pls = playlists
        if !pls.contains(currentPlaylist) { currentPlaylist = pls.first ?? "" }
        if let first = songsIn(currentPlaylist).first { select(first) }
        // Refill from THIS library rather than waiting for the next window activation. A setter
        // who switches folders to pick up a round that has just been handed to them would
        // otherwise see nothing until they clicked away and back.
        detectIncoming()
        // §5c, for the library we just moved INTO. Read after `store.load()` so it is the bytes
        // on disk rather than anything this session has done, and deduplicated by `Snapshot.write`
        // itself if an identical copy is already the newest one.
        Seeding.run()
        Seeding.placeScripts()
        if let shot = Snapshot.capture() { writeSnapshot(shot) }
        objectWillChange.send()
        flash(songs.isEmpty
              ? "เปลี่ยนโฟลเดอร์งานแล้ว — ยังไม่มีไฟล์เพลงใน songs/"
              : "เปลี่ยนโฟลเดอร์งานแล้ว — เจอ \(songs.count) เพลง")
        return nil
    }

    func setPlaylist(_ p: String) {
        cancelGuesses()        // nothing in the round you just left is worth finishing
        // The term was typed about the round you are leaving. Carrying it over is how the new
        // round opens showing two of its songs.
        closeSearch()
        // Same reasoning as the search term, and it is not hypothetical: a `2xx` that was empty
        // and folded in the round you are leaving may be the fullest column in the one you are
        // entering, and the fold would hide it.
        collapsedCols.removeAll()
        colFractions = ColumnLayout.evenFractions(Library.columnLabels.count)
        currentPlaylist = p
        store.lastPlaylist = p
        store.settingsChanged()
        // Otherwise the centre pane keeps playing a song from the round you just left, and
        // Correct/Wrong logs it under THAT round's playlist.
        if let cur = current, Library.playlist(of: cur) == p { return }
        // Prefer a song the filter actually shows; falling back to a hidden one is fine
        // because `select` then clears the filter and says why.
        if let first = visibleSongs(p).first ?? songsIn(p).first {
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
        // A filter must never be able to hide the selected song. ↑/↓ stay inside the filtered
        // list by construction, but `Tab`, `Return`'s advance, a log row, the donor jump and
        // `nextNeedingReview` all target the WHOLE round on purpose — the review sweep is about
        // the round, not about what is on screen. One guard at the one choke point, instead of
        // a filtered variant of every caller. It has to SAY so, or the filter looks like it
        // switched itself off.
        if !tagFilter.isEmpty, !matchesTagFilter(path) {
            let t = tagFilter
            tagFilter = ""
            flash("เลิกกรอง \"\(t)\" — เพลงที่เลือกไม่มีแท็กนี้")
        }
        // Same rule, same choke point, for the search term — `Tab`, `Return`'s advance, a log
        // row and `nextNeedingReview` all target the whole round on purpose.
        if !search.isEmpty, !matchesSearch(path) {
            let q = search
            closeSearch()
            flash("เลิกค้นหา \"\(q)\" — เพลงที่เลือกไม่ตรงกับคำค้น")
        }
        // A folded column may not hold the selection (§8g). The same choke point as the two
        // guards above, and for the same reason: `moveColumn`, `Tab`, `Return`'s advance, a log
        // row and `nextNeedingReview` all target the whole ROUND on purpose, so any of them can
        // land in a column that is folded. No toast — unlike the filter, which looks like it
        // switched itself off, a column visibly opening explains itself.
        collapsedCols.remove(Library.column(of: path))
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
        let list = visibleSongs(column: activeCol)
        guard !list.isEmpty else { return }
        let i = current.flatMap { list.firstIndex(of: $0) } ?? -1
        select(list[max(0, min(list.count - 1, i + d))])
    }

    func isColumnCollapsed(_ i: Int) -> Bool { collapsedCols.contains(i) }

    /// Point width per column, for the wide 3-across layout. The two edges come off the pane
    /// FIRST, or three fixed frames plus two edges overflow it and the third column's rows get
    /// clipped — and the edges are 8 pt each, not 1, because that is what makes them grabbable
    /// without an overlay reaching outside its parent.
    func columnWidths() -> [CGFloat] {
        ColumnLayout.widths(fractions: colFractions, folded: collapsedCols,
                            total: listWidth - ColumnEdge.width * 2,
                            railWidth: AppModel.collapsedColWidth,
                            columns: Library.columnLabels.count)
    }

    func canDragColumnEdge(after i: Int) -> Bool {
        ColumnLayout.handleAfter(i, folded: collapsedCols, columns: Library.columnLabels.count)
    }

    /// Drag the edge after column `i`. `nil` back from `ColumnLayout.drag` means there is nothing
    /// to drag, and must leave the fractions ALONE — a no-op write would still publish and
    /// re-render the whole list on every mouse sample.
    func dragColumnEdge(after i: Int, by dx: CGFloat) {
        guard let next = ColumnLayout.drag(after: i, dx: dx, fractions: colFractions,
                                           folded: collapsedCols,
                                           total: listWidth - ColumnEdge.width * 2,
                                           railWidth: AppModel.collapsedColWidth,
                                           columns: Library.columnLabels.count)
        else { return }
        colFractions = next
    }

    /// Double-click on an edge. Equal thirds is the only "reset" that needs no memory of what the
    /// widths were before.
    func resetColumnWidths() {
        colFractions = ColumnLayout.evenFractions(Library.columnLabels.count)
        flash("คืนความกว้างคอลัมน์เป็นสามส่วนเท่ากัน")
    }

    /// Fold or unfold a list column. It REFUSES two states rather than letting the UI make them,
    /// because both are ways for work to go missing on a show day:
    ///
    /// - the column holding the selection may not fold. §8g's rule — the selection can never be
    ///   hidden — enforced here at the one choke point instead of as a rule every caller has to
    ///   remember. `select` unfolds for the same reason from the other direction.
    /// - the last expanded column may not fold, or the list is gone entirely.
    ///
    /// Unfolding is never refused: it can only reveal.
    func setColumnCollapsed(_ i: Int, _ collapsed: Bool) {
        switch ColumnFold.decide(index: i, collapsed: collapsed, folded: collapsedCols,
                                 selectionColumn: current.map(Library.column(of:)),
                                 columns: Library.columnLabels.count) {
        case .fold:
            collapsedCols.insert(i)
            flash("พับ \(Library.columnLabels[i]) แล้ว — กดที่รางเพื่อเปิดคืน")
        case .unfold:
            collapsedCols.remove(i)
        case .refuseHoldsSelection:
            flash("พับไม่ได้ — เพลงที่เลือกอยู่ในคอลัมน์นี้")
        case .refuseLastExpanded:
            flash("พับไม่ได้ — ต้องเหลือคอลัมน์ที่เปิดอยู่อย่างน้อยหนึ่งคอลัมน์")
        case .noop:
            break
        }
    }

    func moveColumn(by d: Int) {
        for step in 1...Library.columnLabels.count {
            let i = ((activeCol + d * step) % 3 + 3) % 3
            let list = visibleSongs(column: i)
            if let first = list.first { activeCol = i; select(first); return }
        }
    }

    // MARK: - config

    func config() -> SongConfig { current.map { store.config(for: $0) } ?? SongConfig() }

    /// Shortest intro the app will accept. A zero-length range made modeForPosition return .free
    /// for everything, which silently disarmed the intro-end guard — found in a real config.
    nonisolated static let minIntro: Double = 0.5

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

    /// The setter's note for the operator (§9 `note`).
    ///
    /// Goes through `updateConfigQuiet`, which is the whole point: `updateConfig` stamps
    /// `configured = true, auto = false`, so writing a note through it would certify an
    /// unreviewed machine guess as human-reviewed — dropping the song out of the
    /// `Return`/`Tab` sweep AND out of the pre-flight's `stillAuto` and `hookDefault`
    /// warnings, so a round nobody had looked at would pass the handover check. That is the
    /// typed marker field writing on blur (§11) and `applyGuess` certifying itself (§7a4),
    /// in a third costume — and a note is exactly the thing a setter writes BEFORE deciding
    /// where the markers go.
    ///
    /// `updateConfigQuiet` and not a path of its own: it brings `pushUndo`, so `Cmd+Z` puts a
    /// note back, and it is the rule `trimDb` and `played` already use. §7a4 records what an
    /// unguarded twin of an existing write path costs.
    func setNote(_ s: String) {
        guard let p = current else { return }
        let n = Store.clampNote(s)
        // An unchanged value is not an edit: it would push an undo entry and cost the operator
        // a real one off the bottom of the 40-deep stack. Same reasoning as `MarkerTimeField`
        // refusing a no-op commit.
        guard n != store.config(for: p).note else { return }
        updateConfigQuiet { $0.note = n }
        saveState = "saving…"
    }

    /// Add a tag to the current song. Returns false when there was nothing usable to add, so
    /// the caller can say why rather than appearing to do nothing.
    ///
    /// `updateConfigQuiet` for the same reason as `setNote`: a tag is not a marker and must not
    /// certify a song as reviewed.
    @discardableResult
    func addTag(_ raw: String) -> Bool {
        guard let p = current, let t = Store.clampTag(raw) else { return false }
        let c = store.config(for: p)
        let k = Store.tagKey(t)
        if c.tags.contains(where: { Store.tagKey($0) == k }) { return false }
        guard c.tags.count < Store.tagsPerSong else {
            flash("แท็กได้สูงสุด \(Store.tagsPerSong) อันต่อเพลง — เอาอันที่ไม่ใช้ออกก่อน")
            return false
        }
        // The library-wide cap, §8g. Only a word that is NEW to the library counts against it:
        // putting a tag the round already uses onto one more song must never be refused, or the
        // cap would stop meaning "how many different tags exist" and start meaning "how much
        // tagging you may do".
        if !store.tagsInUse.contains(where: { Store.tagKey($0) == k }),
           store.tagsInUse.count >= Store.tagsMaxDistinct {
            flash("มีแท็กครบ \(Store.tagsMaxDistinct) แบบในไลบรารีแล้ว — ใช้แท็กเดิม หรือเลิกใช้อันที่ไม่ได้ใช้ก่อน")
            return false
        }
        updateConfigQuiet { $0.tags = Store.clampTags($0.tags + [t]) }
        saveState = "saving…"
        return true
    }

    func removeTag(_ t: String) {
        guard current != nil else { return }
        let k = Store.tagKey(t)
        updateConfigQuiet { $0.tags.removeAll { Store.tagKey($0) == k } }
        saveState = "saving…"
    }

    /// Which colour a tag gets, §8g. Library-wide, so it deliberately does NOT go through
    /// `updateConfig*` and does not touch the current song at all — see `Store.setTagColor`.
    ///
    /// `objectWillChange` by hand because `store` is a plain class, not a published property:
    /// every other write to it arrives here through `updateConfig*`, which does the same.
    func setTagColor(_ tag: String, _ slot: Int?) {
        objectWillChange.send()
        store.setTagColor(tag, slot)
        saveState = "saving…"
    }

    func mark(_ key: WritableKeyPath<SongConfig, Double>) {
        let t = (player.position * 100).rounded() / 100
        if let f = MarkerField.times.first(where: { $0.timeKey == key }) { focusMarker = f }
        updateConfig { $0[keyPath: key] = t }
    }

    /// Note this takes focus even when the field is not a time: pressing `E` then `←` should
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
        flash("ปรับละเอียด: \(focusMarker.label)  (←/→)")
    }

    /// `←`/`→`. Deliberately not guarded by the two-press rule: a 0.01 s step cannot put a
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
        let before = config()
        updateConfig(commit: false) { $0[keyPath: k] = max(0, (($0[keyPath: k] + d) * 100).rounded() / 100) }
        let after = config()
        // `updateConfig` clamps `introEnd >= introStart + minIntro`, so a nudge that reaches the
        // floor starts dragging the OTHER marker along. The flash prints only the focused value,
        // so without this the second marker moves invisibly — and at `nudgeStepCoarse` a held key
        // is ~3.3 s of movement per second, i.e. it gets there in about one second. §11 gives the
        // same reasoning for why the typed field does not commit per keystroke: the lone `1` on
        // the way to `1:20` would drag the other marker with it.
        var msg = String(format: "%@ %.2fs", focusMarker.label, after[keyPath: k])
        if let dragged = MarkerField.times.first(where: { f in
            guard let other = f.timeKey, other != k else { return false }
            return before[keyPath: other] != after[keyPath: other]
        }), let other = dragged.timeKey {
            msg += String(format: "  ·  ดัน %@ ไป %.2fs ด้วย", dragged.label, after[keyPath: other])
        }
        flash(msg)
        // A HELD key re-arms the debounce on every autorepeat (~30 ms), so on its own the
        // debounce NEVER fires and `remode` never runs: the node keeps the old Intro End and the
        // audio stops there while the countdown reads the new value. Commit immediately only
        // when the node is genuinely about to run out — holding the key far from the boundary
        // still coalesces into one commit on release, which is the whole point of the debounce.
        // See `Player.boundRunsOutEarly`.
        if player.boundRunsOutEarly(config: config()) { commitConfig() }
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
        // `←`/`→` was a dead key and no card showed the hint saying why.
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
    /// Keyed by path AND stamped with a monotonic id. The id is the fix for a confirmed race:
    /// neither clear used to check that the entry was still *this* task, so a stale task's
    /// main-actor hop erased a NEWER task's handle — after which that newer task was untracked
    /// and uncancellable, a further manual press found `nil` to cancel, and two full FFT passes
    /// ran concurrently on one path and both applied. The mirror case left a finished task in
    /// the slot forever, which made the automatic guess impossible for that song for the rest
    /// of the session: the feature silently not happening, which §7a4 already records once.
    private var guessTasks: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var guessSeq = 0

    /// May a guess write to this song *right now*? One rule, shared by both halves of the
    /// feature, because the two halves are two writes inside a single button press and the way
    /// they went wrong was by disagreeing: `applyGuess` had four guards and `applyAutoStart`
    /// had none of them.
    ///
    /// **`isPlaying` is the wrong question**, and this is the worst defect this feature has had.
    /// Paused-on-a-buzz is `isPlaying == false`. That is the single most dangerous moment in a
    /// taping to move Intro End, because the next Space goes through `modeForPosition`, and for
    /// a playhead now sitting PAST the new Intro End that returns `.free` — no intro bound, the
    /// whole song out on camera, from a value nobody typed. §10's "arm only, never disarm" rule
    /// cannot catch it: that protects `remode`, and a guess never reaches `remode` precisely
    /// because it only applies when stopped.
    ///
    /// So the question is whether a QUESTION is in progress, and the playhead's position is
    /// part of that. A song parked at its own Intro Start is at rest; a song stopped anywhere
    /// else is one the operator is in the middle of.
    ///
    /// This is checked at the WRITE, not at the trigger. A cancel fired when playback starts
    /// can always be raced by a task that is already inside its main-actor hop; a guard here
    /// cannot be.
    func guessAllowed(_ path: String) -> Bool {
        guard current == path else { return true }   // off-screen: nothing of it is on air
        if player.isPlaying { return false }
        return player.position <= store.config(for: path).introStart + 0.25
    }

    /// Drop every in-flight guess. Called where the thing a guess would write to has gone away
    /// or been replaced wholesale; the admission rule above is what makes the feature safe, and
    /// this just stops useless work and keeps the map from growing for the whole session.
    func cancelGuesses() {
        for (_, e) in guessTasks { e.task.cancel() }
        guessTasks.removeAll()
    }

    /// Intro End and Hook, guessed. Everything it writes stays `auto`, so the song remains in
    /// the `Return`/`Tab` review sweep and in the pre-flight warnings until a human confirms it.
    ///
    /// `manual` runs it even for a configured song, pushes an undo entry first, and tells the
    /// operator what happened. The automatic pass is silent — a toast per song while arrowing
    /// through a round is noise.
    func guessRest(_ path: String, duration: Double, manual: Bool = false) {
        if !manual && autoGuessed.contains(path) { return }
        if guessTasks[path] != nil && !manual { return }
        guessTasks[path]?.task.cancel()
        guessSeq += 1
        let myID = guessSeq
        let url = Library.url(path)
        // `introStart` is read HERE, on the main actor, so the detached task owns a plain
        // `Double` instead of reaching back into the store off-actor.
        let startFrom = store.config(for: path).introStart
        let task = Task.detached(priority: .utility) { [weak self] in
            let f = AutoDetect.extract(url: url)
            if Task.isCancelled { return }
            // **Detection runs HERE, not in the main-actor hop.** `AutoDetect.hook` is
            // O(seconds²); measured in release it is 2.1 ms for a 4-minute track and 34.5 ms
            // at the 20-minute cap, against `Player.startGuard`'s 20 ms tick — so at the top
            // of that range it skipped a guard tick outright, and it did so for a song that
            // may not even be the one on air. (In a debug build the same call is 0.24–8.2 s of
            // frozen main thread, which is what you would see while iterating.)
            let guessed: (end: Double, hook: AutoDetect.HookGuess?)? = f.map {
                let e = AutoDetect.introEnd(features: $0, from: startFrom)
                return (e, AutoDetect.hook(features: $0, after: e))
            }
            // Read the weak capture ONCE, here, rather than from inside the concurrently
            // executing closure below — which is what the Swift 6 "reference to captured var
            // 'self'" warning on this exact closure was about.
            let model = self
            await MainActor.run {
                guard let model else { return }
                // Clear only if the slot is still OURS. See `guessTasks`.
                if model.guessTasks[path]?.id == myID { model.guessTasks[path] = nil }
                // A cancel can land after `extract` returned and still let this whole hop run
                // — measured, `Task.isCancelled` is observable as true in here. Applying a
                // half-computed guess and then reporting the half it did not write is worse
                // than doing nothing.
                if Task.isCancelled { return }
                guard let f, let g = guessed else {
                    if manual { model.flash("วิเคราะห์เพลงนี้ไม่ได้") }
                    return
                }
                model.autoGuessed.insert(path)
                model.applyGuess(path, features: f, end: g.end, hook: g.hook,
                                 duration: duration, manual: manual)
            }
        }
        guessTasks[path] = (myID, task)
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
                            end: Double, hook: AutoDetect.HookGuess?,
                            duration: Double, manual: Bool) {
        guard guessAllowed(path) else {
            autoGuessed.remove(path)       // try again next time the song is selected
            if manual { flash("กำลังเล่นอยู่หรือค้างกลางเพลง — กด S แล้วลองอีกที") }
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
        // No undo entry for the AUTOMATIC pass. `mayWrite*` above means every field it can
        // touch is still exactly at its default, so the state an undo would restore is one no
        // human chose — and the stack is 40 deep with `removeFirst`, so one entry per song
        // while reviewing a round pushed the setter's own edits off the bottom. Worse, popping
        // a robot entry runs `undo()`, which can move the selection to another song. A manual
        // press is a deliberate act and keeps its undo.
        withConfig(of: path, pushUndo: manual) { c in
            if mayWriteEnd { c.introEnd = (min(duration, end) * 100).rounded() / 100 }
            if mayWriteHook, let h = hook {
                c.hook = (max(0, min(duration - 1, h.time)) * 100).rounded() / 100
            }
        }
        // **A guess is never a review, whoever asked for it.** `withConfig` stamps
        // `configured = true, auto = false` because its ordinary caller is a human edit; this
        // is not one. The old code restored `existing.configured`, which looked conservative
        // and was the hole: `applyAutoStart` runs FIRST in the same button press and used to
        // stamp `configured = true`, so by the time this read it the song had been certified
        // on the strength of a machine guess — dropping it out of the `Return`/`Tab` sweep AND
        // out of BOTH pre-flight warnings (`stillAuto`, and `hookDefault` once the hook moved
        // off 60). An unreviewed round then passed the handover check, while the toast on
        // screen said "ตรวจดูอีกที". One rule instead: anything a guess wrote needs a human.
        var after = store.config(for: path)
        after.auto = true
        after.configured = false
        store.set(after, for: path)
        invalidateStatus()

        // Only when this song is still the one on screen — and naming only the fields actually
        // written. It used to print both numbers unconditionally, so a guess that wrote Intro
        // End alone reported `Hook = 60.00`: the untouched default, announced as the thing the
        // feature had just worked out.
        if manual && current == path {
            var parts: [String] = []
            if mayWriteEnd { parts.append(String(format: "Intro End = %.2fs", after.introEnd)) }
            if mayWriteHook, hook != nil { parts.append(String(format: "Hook = %.2fs", after.hook)) }
            flash(parts.isEmpty ? "ไม่มีอะไรให้เดาเพิ่ม"
                                : "เดา " + parts.joined(separator: " · ") + " — ตรวจดูอีกที")
        }
        objectWillChange.send()
    }

    /// The marker clamp chain, as a PURE function of its inputs.
    ///
    /// Extracted from `withConfig` for the same reason `MarkerGrab.decide` is a pure function
    /// (§11): it is the last line of defence before a value reaches `config.json`, and
    /// `--guesstest` can only prove it holds for every file in the library if it can call it
    /// without a store, a player or a window. The arithmetic is unchanged.
    ///
    /// What it guarantees, and each clause is load-bearing:
    /// - **every marker is finite.** `Store.set` calls `round2`, which multiplies by 100 with
    ///   no finiteness check, and a non-finite value reaching `JSONSerialization` raises an
    ///   **Obj-C** exception that `try?` cannot catch — after which every later save fails with
    ///   nothing on screen naming the song. NaN is killed by `max(0, …)`: Swift's `max(x, y)`
    ///   is `y >= x ? y : x`, and `NaN >= 0` is false, so it returns 0. (`min(x, y)` is
    ///   `y < x ? y : x`, so `min(nan, 5)` returns **nan** — this fails closed only because
    ///   `max` runs on the inside. Do not reorder them.)
    /// - **`introEnd >= introStart + minIntro`.** `introStart == introEnd` makes
    ///   `modeForPosition` return `.free`, which disarms the intro-end stop and plays the whole
    ///   song on camera — §12 calls that the worst defect this app has had.
    /// - nothing exceeds `maxTime`, or the file's own duration when it is known.
    /// `nonisolated` because it is pure and `--guesstest` has to call it without a main actor.
    nonisolated static func clampMarkers(_ cfg: SongConfig, duration: Double?) -> SongConfig {
        var c = cfg
        c.introStart = min(max(0, c.introStart), AppModel.maxTime)
        c.introEnd = min(max(0, c.introEnd), AppModel.maxTime)
        c.hook = min(max(0, c.hook), AppModel.maxTime)
        if let d = duration, d > 0, d.isFinite {
            c.introStart = min(c.introStart, d)
            c.introEnd = min(c.introEnd, d)
            c.hook = min(c.hook, d)
        }
        c.introEnd = max(c.introEnd, c.introStart + AppModel.minIntro)
        return c
    }

    /// Duration from the analysis cache, for a path that may no longer be selected.
    private func cachedDuration(_ path: String) -> Double? {
        analysisCache.first(where: { $0.path == path })?.a.duration
    }

    /// `updateConfig`, but for a named path rather than `current`. The guess finishes seconds
    /// after it started, and the selection may have moved on in the meantime — writing to
    /// `current` would then put one song's markers on another.
    private func withConfig(of path: String, pushUndo wantUndo: Bool = true,
                            _ mutate: (inout SongConfig) -> Void) {
        if wantUndo { pushUndo(path, coalesce: false) }
        var c = store.config(for: path)
        mutate(&c)
        c = AppModel.clampMarkers(c, duration: cachedDuration(path))
        c.configured = true
        c.auto = false
        store.set(c, for: path)
        saveState = "saving…"
        if current == path {
            refreshGain()
            player.remode(config: c)
        }
    }

    /// Intro Start, guessed (§7a1) — **`applyGuess`'s twin, and it used to carry none of
    /// `applyGuess`'s four guards.** Same trigger, same selection-time callback, two of the
    /// same markers, `store.set` direct. Each guard below is here because of a specific way
    /// this function could wreck a take or a day of work:
    ///
    /// 1. **A question in progress.** It wrote both markers under live playback with no
    ///    `remode`, so the node stayed scheduled at the OLD Intro End while `tick()` read the
    ///    new one 50x a second. Select an unconfigured song, press Space before the analysis
    ///    finishes — which the old comment here explicitly anticipated — and the intro cut
    ///    dead at the old boundary while the guard strip kept counting down and the button
    ///    still read Pause. On camera that is indistinguishable from the app hanging. Via the
    ///    `Store.decode` degenerate-range repair (a real state of song 102) the move can be
    ///    ~32 s *backwards*, which cuts the audio instantly and parks the playhead behind it.
    /// 2. **A signed-off round.** Without this, an imported round whose songs are still `auto`
    ///    — which the pre-flight warns about and deliberately does not block — gets markers a
    ///    robot moved off `base`, and the setter's diff sheet accepts every row by default on
    ///    the way back. §8e's audit trail, laundered.
    /// 3. **Fill blanks only.** It overwrote `introStart` whenever `isConfigured` was false,
    ///    and `isConfigured` is false whenever `auto` is true — which does NOT mean the value
    ///    is a default. Song 102 is `auto` only because `Store.decode` repaired its range, and
    ///    its `introStart: 33.73` is a human's, with no copy anywhere. The automatic pass
    ///    destroyed it on the next selection, silently, with no undo entry.
    /// 4. **Through `withConfig`**, for the `maxTime` and `introEnd >= introStart + minIntro`
    ///    clamps. This was the one marker write still opting out — 20 lines below the comment
    ///    claiming it was the last one.
    @discardableResult
    func applyAutoStart(_ path: String, analysis a: Analysis, manual: Bool) -> Bool {
        guard guessAllowed(path) else { return false }
        let existing = store.config(for: path)
        guard existing.base == nil || manual else { return false }
        let d = SongConfig.defaults
        guard manual || (SongConfig.same(existing.introStart, d.introStart)
                         && SongConfig.same(existing.introEnd, d.introEnd)) else { return false }
        guard let t = a.detectIntroStart() else { return false }

        let span = max(AppModel.minIntro, existing.introEnd - existing.introStart)
        withConfig(of: path, pushUndo: manual) { c in
            c.introStart = (t * 100).rounded() / 100
            c.introEnd = (min(a.duration, t + span) * 100).rounded() / 100
        }
        // A guess is never a review — see `applyGuess` for the full reason. This half used to
        // stamp `configured = true` on a manual press, and because it runs FIRST in the same
        // button press, `applyGuess` then read that flag and certified three machine guesses
        // as human-placed: out of the `Return`/`Tab` sweep and out of both pre-flight warnings.
        var after = store.config(for: path)
        after.auto = true
        after.configured = false
        store.set(after, for: path)
        invalidateStatus()
        if path == current { player.seek(to: after.introStart, config: after) }
        objectWillChange.send()
        return true
    }

    /// dB of the applied gain the output limiter will take back, > 0 only when the intro has
    /// less headroom than the gain asks for. Published so the level card and the pre-flight can
    /// both read it without recomputing.
    @Published var limiterEats: Double = 0
    /// The same figure for the hook, i.e. for what Reveal puts on camera.
    @Published var revealLimiterEats: Double = 0

    func refreshGain() {
        let c = config()
        let r = player.applyGain(analysis: analysis, config: c,
                                 normalize: store.normalize, scope: store.loudnessScope)
        limiterEats = r.limiterEats
        revealLimiterEats = r.revealLimiterEats
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
        // The donor exists because a REUSED song should not start blank (§8c), and a note is a
        // fact about the song, not about the round — so it comes along. Additive, like the
        // handover merge: a donor with no note never clears one already written here.
        if !s.note.isEmpty { d.note = s.note }
        // Union, not replace: a tag already written here is not the donor's to remove.
        if !s.tags.isEmpty { d.tags = Store.clampTags(d.tags + s.tags) }
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
                                  // The installed BUNDLE, not the folder holding it: the helper
                                  // replaces one directory. Handing it a folder — least of all
                                  // the data root — is how a program swap reaches the questions.
                                  target: Bundle.main.bundleURL,
                                  version: u.version,
                                  waitPid: ProcessInfo.processInfo.processIdentifier)
                updateStep = "กำลังปิดแอป — เดี๋ยวมันจะเปิดขึ้นมาใหม่เอง"
                // Let the child reach its wait loop before we vanish.
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Close the sheet FIRST. Reported from a real update that hung here forever:
                // the message was on screen and the app never went away. `NSApp.terminate` runs
                // the normal window-closing sequence, and this call is made from inside a
                // SwiftUI `.sheet` presented on the only window — the most likely thing in the
                // way, and free to remove.
                showAbout = false
                NSApp.terminate(nil)
                // If we are still here, terminate did not take, and the old code left the
                // operator looking at "กำลังปิดแอป" with no way out and no explanation: the
                // installer waits 30 s for this pid and then exits silently, so the screen
                // stayed like that forever.
                //
                // The window is still open at this point, so quitting by hand is what finishes
                // the update — and it finishes it properly, because `saveNow()` ran before
                // `apply` and the installer is still counting.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard self.updateInstalling else { return }
                    self.updateStep = "ปิดแอปเองไม่ได้ — กด Cmd+Q เดี๋ยวนี้ (ตัวติดตั้งรออยู่อีก ~25 วินาที)"
                    self.updateState = "ถ้ากด Cmd+Q แล้วไม่ปิด ให้ Force Quit (Cmd+Option+Esc) "
                        + "— โจทย์ถูกบันทึกไปก่อนหน้านี้แล้ว ไม่หาย "
                        + "ถ้าพลาดช่วงนี้ไป เปิดแอปใหม่แล้วกดอัปเดตอีกครั้งได้เลย"
                }
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
            // Read the weak capture once, HERE, rather than from inside the concurrently
            // executing closure below — the same Swift 6 "reference to captured var 'self'"
            // warning the guess feature's task carried.
            let model = self
            await MainActor.run {
                guard let self = model else { return }
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
        Palette.clearSwatchCache()
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

    /// Persist the name. Called from the field's Return and from `doExport`, so pressing
    /// ส่งต่อ without pressing Return still saves what is on screen — the field is the only
    /// place this value is ever typed, and it only pays off on the NEXT handover.
    func commitSetterName() {
        let clean = Store.clampName(setterName)
        if clean != setterName { setterName = clean }
        guard clean != store.setterName else { return }
        store.setterName = clean
        store.settingsChanged()
    }

    func doExport() -> String {
        let paths = songsIn(currentPlaylist)
        guard !paths.isEmpty else { return "รอบนี้ไม่มีเพลง" }
        commitSetterName()
        do {
            let url = try Handoff.export(round: currentPlaylist, paths: paths,
                                         store: store, by: store.setterName)
            // The file we just wrote matches this round exactly (export stamps `base` from
            // `current`), so it is not something to take in.
            clearIncoming(currentPlaylist)
            objectWillChange.send()
            return "เขียน \(RoundPackage.fileName) แล้ว — ส่งโฟลเดอร์ \(url.deletingLastPathComponent().lastPathComponent)/ ได้เลย"
        } catch {
            return "เขียนไฟล์ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    /// Looks for a `round.json` that has not been taken in yet — in **every** round, not just
    /// the one on screen. Called on launch and on window activation, because the usual way a
    /// round arrives is somebody copying a folder in while the app is open.
    ///
    /// Sweeping all of them is the point. It used to read `currentPlaylist` alone, which is
    /// correct for one setter and loses two thirds of the work for three: drop in `EP01/`,
    /// `EP02/` and `EP03/` and only the selected round raised a strip, while the other two sat
    /// unimported with nothing anywhere saying they were waiting.
    ///
    /// Cost of the sweep: one small file read plus one in-memory `Handoff.plan` per round. This
    /// is **not** called from `body` — only from `didBecomeActiveNotification` and `onAppear` —
    /// so the file I/O is not on a per-frame path (§15's `manifestLocation` lesson).
    func detectIncoming() {
        // Prune against EVERY package on disk, not the waiting ones — a reviewed package is by
        // definition not waiting, so the waiting set would wipe the record on the first sweep.
        // `Handoff` owns both loops (§8e: the sweep must have one implementation).
        store.pruneTakenIn(to: Set(Handoff.packagesOnDisk(playlists)
            .map { Handoff.reviewKey(round: $0.round, pkg: $0.pkg) }))
        let found = Handoff.waitingRounds(playlists, store: store, songsIn: songsIn)
        // Forget wave-offs for items that are no longer waiting, so copying a folder back in
        // later raises the strip again instead of being silently swallowed by a stale dismissal.
        let live = Set(found.map(\.id))
        if !dismissedIncoming.isSubset(of: live) { dismissedIncoming.formIntersection(live) }
        // Guarded: this runs on every window activation and assigning a `@Published` publishes
        // even when the value is identical, which would re-render the whole window for nothing.
        guard found != incomingRounds else { return }
        incomingRounds = found
    }

    private func clearIncoming(_ round: String) {
        guard incomingRounds.contains(where: { $0.round == round }) else { return }
        incomingRounds.removeAll { $0.round == round }
    }

    func dismissIncoming(_ item: IncomingRound) {
        dismissedIncoming.insert(item.id)
    }

    /// Wave off every round waiting elsewhere. The strip is ONE slot on purpose — §15 measures
    /// two banners plus the save-failure bar as more height than the window's declared minimum
    /// has — so when it is standing in for several rounds, its dismiss has to cover them. What
    /// survives is the 📥 on each round in the picker.
    func dismissIncomingElsewhere() {
        dismissedIncoming.formUnion(incomingElsewhere.map(\.id))
    }

    /// Jump to a round that is waiting. Refuses while playing for the same reason a log row does
    /// (§8d): it changes the round, which loads a different song and cuts the audio — and this
    /// button sits in a strip at the top of the window, well inside slamming range.
    func goToIncoming(_ item: IncomingRound) {
        guard !player.isPlaying else {
            flash("กำลังเล่นอยู่ — กด Space หยุดก่อนถ้าจะเปลี่ยนรอบ")
            return
        }
        setPlaylist(item.round)
    }

    func openImport() {
        let url = RoundPackage.url(forRound: currentPlaylist)
        guard let pkg = RoundPackage.read(url) else { flash("ไม่พบ \(RoundPackage.fileName)"); return }
        let plan = Handoff.plan(pkg, round: currentPlaylist, paths: songsIn(currentPlaylist), store: store)
        if !plan.hasChoices {
            Handoff.apply(plan, accepted: [], store: store)
            clearIncoming(currentPlaylist)
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
        // `plan.round`, not `currentPlaylist`: the plan knows which folder it was built for, so
        // this cannot clear the wrong round's entry if the selection moved under the sheet.
        clearIncoming(plan.round)
        afterBulkChange()
        flash("รับมา \(n) รายการ — ที่ไม่รับยังเป็นค่าเดิมของเครื่องนี้")
    }

    /// After anything rewrites many songs at once: the undo stack describes a world that no
    /// longer exists, so drop it rather than let Cmd+Z restore half a round.
    private func afterBulkChange() {
        // A guess still in flight was computed against the config as it was BEFORE the import
        // replaced it wholesale. `applyGuess` would refuse it anyway (the import stamps
        // `base`), but dropping it here means the refusal is not the only thing standing
        // between an import and a robot write — and it is the same reasoning as clearing the
        // undo stack on the line below: `Cmd+Z` must not restore half a round.
        cancelGuesses()
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
