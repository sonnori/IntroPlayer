import Foundation

/// The five values that make up "the question": what the setter hands over, and the only fields
/// tracked for on-site edits. `played`/`configured`/`auto` are deliberately absent — they are
/// session state, not part of the deliverable (see CLAUDE.md "Handover").
struct SongBase: Equatable {
    var introStart: Double = 0
    var introEnd: Double = 15
    var hook: Double = 60
    var trimDb: Double = 0
    var ignoreEnd: Bool = false
}

/// One editable field of the question, for the on-site-edit indicators and the diff table.
enum MarkerField: String, CaseIterable {
    case introStart, introEnd, hook, trimDb, ignoreEnd
    var label: String {
        switch self {
        case .introStart: return "Intro Start"
        case .introEnd:   return "Intro End"
        case .hook:       return "Hook"
        case .trimDb:     return "Trim"
        case .ignoreEnd:  return "ข้าม Intro End"
        }
    }
    /// The field's value on a whole config, for "what it is now" next to a pending proposal.
    static func text(_ f: MarkerField, _ c: SongConfig) -> String { f.text(c.current) }

    /// The three fields that are a time on the waveform, in the order the setup panel shows them.
    static let times: [MarkerField] = [.introStart, .introEnd, .hook]

    /// The keyPath this field writes, so a nudge or a typed value does not need a switch at every
    /// call site. nil for the two fields that are not a position in the song.
    var timeKey: WritableKeyPath<SongConfig, Double>? {
        switch self {
        case .introStart: return \.introStart
        case .introEnd:   return \.introEnd
        case .hook:       return \.hook
        case .trimDb, .ignoreEnd: return nil
        }
    }

    /// The physical key that marks this field, for on-screen hints.
    var hotKey: String {
        switch self {
        case .introStart: return "I"
        case .introEnd:   return "O"
        case .hook:       return "H"
        case .ignoreEnd:  return "E"
        case .trimDb:     return "—"
        }
    }

    /// Formatted for display — seconds for the markers, dB for trim, a word for the flag.
    func text(_ b: SongBase) -> String {
        switch self {
        case .introStart: return String(format: "%.2f", b.introStart)
        case .introEnd:   return String(format: "%.2f", b.introEnd)
        case .hook:       return String(format: "%.2f", b.hook)
        case .trimDb:     return String(format: "%+.1f dB", b.trimDb)
        case .ignoreEnd:  return b.ignoreEnd ? "เปิด" : "ปิด"
        }
    }
}

/// Per-song settings. Field names and defaults match the web version's `config.json` exactly.
struct SongConfig {
    var introStart: Double = 0
    var introEnd: Double = 15
    var hook: Double = 60
    var ignoreEnd: Bool = false
    var trimDb: Double = 0
    var played: Bool = false
    var configured: Bool = false
    var auto: Bool = false          // introStart was guessed, not placed by the GM
    /// Free text the setter writes for the OPERATOR to read in the moment they open the question
    /// — "ฝั่งซ้ายน่าจะได้เปรียบ", "คนรุ่น 40+ รู้แน่".
    ///
    /// Deliberately NOT part of `SongBase` and NOT a `MarkerField` case. It changes nothing that
    /// goes to air, so it has no `base`, no `revert` and no on-site badge — and adding a
    /// text-valued case to a `CaseIterable` that drives `onsiteEdits`, `revert`, the setup
    /// panel's field cards and `--handoff` would force every one of those switches to answer
    /// "what does reverting a sentence mean". The handover carries it through `DiffField.note`
    /// instead, where it is only ever a label and two strings.
    ///
    /// It must also never stamp `configured` — see `AppModel.setNote`.
    var note: String = ""
    /// Short reusable labels, for the facts that repeat across songs where the note is a
    /// sentence that does not — "ยุค 90", "ผู้หญิงร้อง", "คนรุ่น 40+".
    ///
    /// **Stored as the strings themselves, not as ids into a registry.** Ids look tidier and
    /// are wrong here for two reasons that both bite at the handover: two machines each minting
    /// `t4` collide, so a merge would have to reconcile two registries instead of taking a set
    /// union; and an id is unreadable in a file people hand-edit and that the web fallback
    /// round-trips without understanding. The registry is therefore DERIVED from use
    /// (`Store.tagsInUse`), never stored — the same reasoning as `onsiteEdits` deriving from
    /// `base` rather than from a flag (§8e): a stored index can go stale, a derived one cannot.
    ///
    /// Carries no colour. A user-colourable chip would hand §6d's mechanism — one meaning per
    /// hue — to someone with no reason to know it exists, and an amber chip beside the
    /// "unreviewed guess" badge or a green one beside "✓ ตอบถูก" is how the one warning
    /// that must never be ignored gets diluted.
    var tags: [String] = []
    /// The values the setter signed off at handover. Written ONLY by export/import — never by an
    /// ordinary marker edit — so anything differing from it is an edit made after the handover.
    /// nil means this song has never been through a handover, so there is nothing to compare to.
    var base: SongBase?

    static let defaults = SongConfig()

    /// The question as it stands now, in the shape `base` is stored in.
    var current: SongBase {
        SongBase(introStart: introStart, introEnd: introEnd, hook: hook,
                 trimDb: trimDb, ignoreEnd: ignoreEnd)
    }

    /// Fields changed since the handover. Empty when there was no handover, so a round that was
    /// never handed over never shows on-site badges.
    var onsiteEdits: [MarkerField] {
        guard let b = base else { return [] }
        let c = current
        return MarkerField.allCases.filter { f in
            switch f {
            case .introStart: return !SongConfig.same(c.introStart, b.introStart)
            case .introEnd:   return !SongConfig.same(c.introEnd, b.introEnd)
            case .hook:       return !SongConfig.same(c.hook, b.hook)
            case .trimDb:     return !SongConfig.same(c.trimDb, b.trimDb)
            case .ignoreEnd:  return c.ignoreEnd != b.ignoreEnd
            }
        }
    }
    var hasOnsiteEdits: Bool { !onsiteEdits.isEmpty }

    /// Markers are stored rounded to 0.01, so an exact compare is right — but a value that came
    /// back through JSON can be 15.000000000000002. Compare at half the stored precision.
    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }

    /// Restore one field to what the setter signed off.
    mutating func revert(_ f: MarkerField) {
        guard let b = base else { return }
        switch f {
        case .introStart: introStart = b.introStart
        case .introEnd:   introEnd = b.introEnd
        case .hook:       hook = b.hook
        case .trimDb:     trimDb = b.trimDb
        case .ignoreEnd:  ignoreEnd = b.ignoreEnd
        }
    }

    /// The GM actually placed markers. `auto` must be checked *before* the value comparison:
    /// a guessed start moves introStart/introEnd off their defaults, which would otherwise read
    /// as "configured" and light up the green badge. Same trap as the web version.
    var isConfigured: Bool {
        if configured { return true }
        if auto { return false }
        return introStart != SongConfig.defaults.introStart
            || introEnd != SongConfig.defaults.introEnd
            || hook != SongConfig.defaults.hook
            || ignoreEnd
    }
}

struct LogEvent: Identifiable {
    var t: String          // ISO8601 with offset, as written by the Python server
    var playlist: String
    var path: String
    var event: String      // "correct" | "wrong"
    /// Disambiguates genuinely identical events — two Wrongs on the same song inside one second is
    /// rare but possible, and duplicate ids break ForEach. It counts occurrences, not positions,
    /// so removing an unrelated row never renumbers anything.
    var dup: Int = 0
    /// Parsed once at load/append. This used to be a computed property that re-parsed the string
    /// on every access — ~25 us each, called thousands of times a second by the badge logic.
    let date: Date?
    var isCorrect: Bool { event == "correct" }
    /// A stable identity. The log panel used `ForEach(Array(evs.enumerated()), id: \.offset)`, so
    /// after an undo the rows shifted and SwiftUI reused them against the wrong event — the
    /// "new taping" divider and the dimming landed on the wrong row.
    var id: String { "\(t)\u{1}\(path)\u{1}\(event)\u{1}\(dup)" }
}

/// One question as it was actually run on set.
///
/// The running order IS the record: questions are never played in list order, so "what was opened
/// first, then what" is the only index the edit room can use against the tape. A take is a
/// **consecutive run** of log events on one song — grouping by path across the whole session (what
/// the log summary used to do) folds a song that was revisited later back into its first
/// appearance, and the order is precisely what that destroys. Going back to a song is a new take.
struct Take: Identifiable {
    /// 1-based position in the running order. This is the number people will say out loud.
    var order: Int
    var path: String
    var playlist: String
    var events: [LogEvent]
    /// Somebody answered it. A take with no correct is burned: it aired and cannot be reused.
    var correct: Bool
    var wrongs: Int
    var startISO: String
    var endISO: String
    var start: Date?
    var id: String { "\(order)\u{1}\(path)\u{1}\(startISO)" }
}

enum Takes {
    /// Events must arrive in the order they were logged. Deliberately NOT sorted by timestamp:
    /// file order is the running order even if a clock jumped, and a clock jump must not be able
    /// to reorder the tape index.
    static func build(_ evs: [LogEvent]) -> [Take] {
        var out: [Take] = []
        for e in evs {
            if let last = out.last, last.path == e.path {
                var t = last
                t.events.append(e)
                if e.isCorrect { t.correct = true } else { t.wrongs += 1 }
                t.endISO = e.t
                out[out.count - 1] = t
            } else {
                out.append(Take(order: out.count + 1, path: e.path, playlist: e.playlist,
                                events: [e], correct: e.isCorrect, wrongs: e.isCorrect ? 0 : 1,
                                startISO: e.t, endISO: e.t, start: e.date))
            }
        }
        return out
    }

    /// Wall-clock span of a run of takes, for matching against a camera's timecode.
    static func span(_ takes: [Take]) -> (first: Date, last: Date)? {
        let ds = takes.compactMap(\.start)
        guard let a = ds.min(), let b = ds.max() else { return nil }
        return (a, b)
    }

    /// A gap longer than this is not a pause between questions — it is a different day.
    static let sittingGap: TimeInterval = 4 * 3600

    /// Split a running order into sittings.
    ///
    /// Needed because `resetAt` is pressed by a human, so one "session" in the log really can span
    /// months — the real `log.json` does. Without this the "from the start" column read
    /// **`+2230:24:30`** and two takes 93 days apart sat next to each other as though they were
    /// consecutive. Each sitting gets its own elapsed baseline and its own date heading.
    static func sittings(_ takes: [Take]) -> [[Take]] {
        var out: [[Take]] = []
        for t in takes {
            let continues: Bool
            if let prev = out.last?.last, let a = prev.start, let b = t.start {
                let d = b.timeIntervalSince(a)
                continues = d >= 0 && d < sittingGap      // a clock that ran backwards also splits
            } else {
                continues = !out.isEmpty                  // undatable rows stay where they sit
            }
            if continues { out[out.count - 1].append(t) } else { out.append([t]) }
        }
        return out
    }
}

enum LoudnessScope: String { case intro, song }

/// Light / dark. Defaults to `dark`, which is not a style preference: the operator's position is
/// a dim corner of a studio and a white 2560x1080 panel at arm's length is a light source
/// pointed at the person who has to watch the stage. `light` is for the setter at a desk.
enum AppTheme: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return "ตามระบบ"
        case .light:  return "สว่าง"
        case .dark:   return "มืด"
        }
    }
}

/// Reads and writes the same two files the web app uses, preserving any keys it doesn't know
/// about. That is what lets both versions run against one folder — and lets the operator fall
/// back to the web app mid-taping without losing a thing.
final class Store {
    private(set) var raw: [String: Any] = [:]      // untouched backing store
    private(set) var songs: [String: SongConfig] = [:]

    // _settings
    var normalize = true
    var loudnessScope: LoudnessScope = .intro
    var theme: AppTheme = .dark
    var lastPlaylist = ""
    var resetAt: [String: String] = [:]
    /// Where to look for a newer build. Empty = the check is off, which is the default and the
    /// only state that needs no network at all. See §15.
    var updateFeed = ""
    /// Where launch snapshots of the questions are ALSO copied. Empty = local only, which is
    /// the default. Point it at a synced folder (Drive, Dropbox, iCloud) and `Snapshot` closes
    /// the half of §13's data gap that a copy inside this folder cannot: losing the folder or
    /// the disk. Empty by default because where an operator's questions are allowed to travel
    /// is their decision — see `Snapshot`.
    var backupDir = ""
    /// The format number this build writes. Absent in a file means 1, so every config written
    /// before this field existed reads as current and raises nothing.
    ///
    /// It exists for one case: once the folder is in other people's hands, two builds can open
    /// the same `config.json`. `set(_:for:)` already merges into `raw`, so unknown keys written
    /// by a NEWER build survive an older one — this number is how the older build can *say* that
    /// it is the older one, instead of looking fine while writing a format it doesn't understand.
    static let schema = 1
    /// What was in the file when we opened it. Greater than `schema` means a newer build wrote it.
    private(set) var schemaOnDisk = 1
    /// Version string of the build that last saved this folder, for diagnosing a handover.
    private(set) var openedBy = ""
    /// Fail VISIBLE, not shut: an operator mid-taping must not be locked out of their own
    /// questions, so this only raises a notice. The merge in `set(_:for:)` is what actually
    /// protects the newer build's fields.
    var schemaAhead: Bool { schemaOnDisk > Store.schema }
    /// Dismissals persist, because the conditions do.
    ///
    /// Session-only dismissal meant the notice came back on every launch — and once two crew
    /// machines are on different builds, which is the *normal* state of a rollout, `schemaAhead`
    /// is true forever. A notice that is always there is a notice nobody reads.
    var dismissedUpdate = ""      // version string the operator has already waved off
    var dismissedSchema = 0       // schema number they have already seen
    /// The version that last ran in this folder. If it differs from this build on launch, the
    /// update worked — and saying so is the other half of the loop: without it the only evidence
    /// is a number that did NOT appear, which is not something an operator can check.
    var lastRanVersion = ""

    /// A store that can never write. Set only by `init(rawForTest:)`.
    ///
    /// Not test scaffolding — a safety property. The headless checks run in the operator's own
    /// folder against their real `config.json`, and several of the things worth checking here
    /// (`set`'s read-it-before-you-delete-it guards, `Handoff.apply`, which ends in `saveNow()`)
    /// only mean anything if you can put a controlled value in front of them. This makes that
    /// possible without the diagnostic being able to touch the file at all.
    private let readOnly: Bool

    init() { readOnly = false; load() }

    /// Only for the headless self-checks. The store cannot write.
    init(rawForTest r: [String: Any]) { readOnly = true; apply(raw: r) }

    func load() {
        apply(raw: (try? Data(contentsOf: AppPaths.config))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
    }

    private func apply(raw incoming: [String: Any]) {
        raw = incoming
        songs.removeAll()
        clearTagCaches()
        for (k, v) in raw where k != "_settings" {
            guard let d = v as? [String: Any] else { continue }
            songs[k] = Store.decode(d)
        }
        let s = raw["_settings"] as? [String: Any] ?? [:]
        normalize = (s["normalize"] as? Bool) ?? true
        loudnessScope = LoudnessScope(rawValue: (s["loudnessScope"] as? String) ?? "") ?? .intro
        // An unreadable or unknown value falls back to dark rather than to the system, so a
        // garbled settings file can never put a white screen in front of the operator mid-taping.
        theme = AppTheme(rawValue: (s["theme"] as? String) ?? "") ?? .dark
        lastPlaylist = (s["lastPlaylist"] as? String) ?? ""
        // Per-key: one bad value used to fail the whole cast, and writeSettings would then erase
        // every reset stamp in the file.
        resetAt = ((s["resetAt"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
        updateFeed = (s["updateFeed"] as? String) ?? ""
        backupDir = String(((s["backupDir"] as? String) ?? "").prefix(500))
        // A non-numeric or missing value reads as the current schema rather than 0, so a garbled
        // field cannot make every launch claim the file is from the future.
        schemaOnDisk = (s["schema"] as? Int) ?? Store.schema
        // Capped: written by another machine's build, and it goes into a notice in the main
        // window. Everything that crosses a machine boundary gets a bound.
        openedBy = String(((s["writtenBy"] as? String) ?? "").prefix(24))
        dismissedUpdate = String(((s["dismissedUpdate"] as? String) ?? "").prefix(24))
        dismissedSchema = (s["dismissedSchema"] as? Int) ?? 0
        lastRanVersion = String(((s["lastRanVersion"] as? String) ?? "").prefix(24))
    }

    /// Upper bound for any marker on the way IN, equal to `AppModel.maxTime`.
    ///
    /// Decode used to guard `isFinite` and `max(0, v)` with **no upper bound**, and every
    /// in-app edit path clamps to this — so a hand-edited, foreign-written or corrupted file
    /// was the only way past it. That was enough for two separate failures:
    ///
    /// - `AutoDetect.introEnd` does `Int(start.rounded())`, and `Int(_: Double)` **traps** for
    ///   anything >= 2^63. `{"introStart": 1e19}` therefore killed the process — SIGTRAP,
    ///   exit 133 — the moment that song was selected. Verified.
    /// - `round2` multiplies by 100, so any finite value >= ~1.8e306 becomes `+infinity`, and
    ///   `JSONSerialization.isValidJSONObject` rejects that — after which **every** later save
    ///   fails with nothing on screen naming the song, and a relaunch re-poisons it.
    ///
    /// Clamping here fixes both for every reader at once, which is strictly better than a
    /// guard in each one. `AppModel.maxTime` reads this value so the two cannot drift.
    static let maxMarker: Double = 4 * 3600
    static func clampMarker(_ v: Double) -> Double {
        v.isFinite ? min(max(0, v), maxMarker) : 0
    }

    /// How long a note may be, counted in grapheme clusters.
    ///
    /// This is a LAYOUT constant, not a preference. The note is displayed in `CenterView`'s
    /// title row, inside the horizontal slack that row already has beside a 52 pt cover frame —
    /// which is what makes it cost zero height, and the reason that matters is §15: the only
    /// flexible child of that pane is the waveform, it has a hard `minHeight: 160` floor, and
    /// past the floor content that overruns the window centres and clips BOTH ends. The song
    /// title goes off the top and ✓ Correct / ✗ Wrong go off the bottom, with no scroller.
    ///
    /// Two things do that job and they are not interchangeable. `CenterView`'s `.lineLimit(2)`
    /// is the HEIGHT GUARANTEE — structural, true for any content, including a line of Latin
    /// capitals that are far wider than Thai. This cap is the READABILITY bound: tuned so that
    /// ordinary Thai prose fits those two lines and truncation stays the backstop rather than
    /// the normal case. `--notetest` measures the fit instead of trusting it.
    ///
    /// Capping the length is better than relying on the ellipsis: this is read while a question
    /// is going out, hover is not available then, and a note too long to take in at a glance has
    /// already failed at its job.
    static let noteMax = 120

    /// Everything a note has to survive on the way in: a hand-edit, another build, a paste.
    static func clampNote(_ s: String) -> String {
        // Flattened to one line. A pasted newline is the one input that can defeat the height
        // argument above, and the field that writes this is single-line so it cannot produce one.
        var n = s
        for bad in ["\r\n", "\n", "\r", "\t", "\u{2028}", "\u{2029}"] {
            n = n.replacingOccurrences(of: bad, with: " ")
        }
        // NFC. Two visually identical Thai strings compare unequal otherwise, and the handover
        // diff would then offer the setter a row where nothing had changed — same family as
        // §8f's grapheme-cluster floor.
        n = n.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.count > noteMax { n = String(n.prefix(noteMax)) }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tag is a LABEL, so it is bounded much harder than a note. Both numbers are about the
    /// same 2-line box in `CenterView`: six tags of 24 and a 120-character note cannot all fit,
    /// and `.lineLimit(2)` is what decides what you see — which is why the note comes FIRST
    /// there and the tags are what truncate. A tag long enough to be a sentence is a note.
    static let tagMax = 24
    static let tagsPerSong = 6
    /// How many DISTINCT tags a library may hold, §8g.
    ///
    /// It is exactly the number of colours in `Palette.tagFill`, and that is the whole reason
    /// it exists: the owner asked for "แต่ละ tag คนละสี", and a cap equal to the palette is what
    /// makes that true rather than nearly true. Past it, `addTag` refuses a NEW word and says
    /// so — it never silently reuses a colour, and it never blocks a tag already in the round.
    static let tagsMaxDistinct = 8

    /// nil for anything that is not a usable tag.
    static func clampTag(_ s: String) -> String? {
        var n = s
        for bad in ["\r\n", "\n", "\r", "\t", "\u{2028}", "\u{2029}"] {
            n = n.replacingOccurrences(of: bad, with: " ")
        }
        // The separator the centre pane joins tags with. A tag containing it would read as two
        // tags there and as one everywhere else.
        n = n.replacingOccurrences(of: " · ", with: " ")
            .replacingOccurrences(of: "·", with: " ")
        while n.contains("  ") { n = n.replacingOccurrences(of: "  ", with: " ") }
        n = n.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.count > tagMax { n = String(n.prefix(tagMax)) }
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// The dedup key. Thai has no case, but "Pop" and "pop" on one song are one tag by any
    /// reading, and two spellings in the registry make its suggestions useless.
    ///
    /// Which spelling survives is decided differently in the two places it matters, and both
    /// rules have to be DETERMINISTIC. Here the input is an ordered array, so first-seen is a
    /// real rule and nothing rewrites what somebody typed. `tagsInUse` reads a Dictionary,
    /// where first-seen is not a rule at all — see the note there.
    static func tagKey(_ s: String) -> String { s.localizedLowercase }

    static func clampTags(_ raw: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for t in raw {
            guard let c = clampTag(t), seen.insert(tagKey(c)).inserted else { continue }
            out.append(c)
            if out.count >= tagsPerSong { break }
        }
        return out
    }

    private static func decode(_ d: [String: Any]) -> SongConfig {
        var c = SongConfig()
        // NaN/Infinity would crash saveNow(): JSONSerialization raises an Obj-C exception that
        // `try?` cannot catch, and the bad value is already on disk so it recurs every launch.
        if let v = d["introStart"] as? Double { c.introStart = clampMarker(v) }
        if let v = d["introEnd"] as? Double { c.introEnd = clampMarker(v) }
        if let v = d["hook"] as? Double { c.hook = clampMarker(v) }
        if let v = d["ignoreEnd"] as? Bool { c.ignoreEnd = v }
        if let v = d["trimDb"] as? Double, v.isFinite { c.trimDb = min(12, max(-12, v)) }
        if let v = d["played"] as? Bool { c.played = v }
        if let v = d["configured"] as? Bool { c.configured = v }
        if let v = d["auto"] as? Bool { c.auto = v }
        if let v = d["note"] as? String { c.note = clampNote(v) }
        if let v = d["tags"] as? [Any] { c.tags = clampTags(v.compactMap { $0 as? String }) }
        if let bd = d["base"] as? [String: Any] {
            var b = SongBase()
            if let v = bd["introStart"] as? Double { b.introStart = clampMarker(v) }
            if let v = bd["introEnd"] as? Double { b.introEnd = clampMarker(v) }
            if let v = bd["hook"] as? Double { b.hook = clampMarker(v) }
            if let v = bd["trimDb"] as? Double, v.isFinite { b.trimDb = min(12, max(-12, v)) }
            if let v = bd["ignoreEnd"] as? Bool { b.ignoreEnd = v }
            c.base = b
        }
        // A zero-length (or inverted) intro range is not a harmless oddity: modeForPosition reads
        // it as `.free`, which disarms the intro-end guard and lets the whole song play out on
        // camera. The live config.json had song 102 at introStart == introEnd == 33.73.
        //
        // Repair it to a default-length intro and demote it to a GUESS — clearing `configured`
        // drops the green "set" badge, so the song shows up as still needing the GM's attention
        // instead of silently claiming to be ready.
        if c.introEnd <= c.introStart {
            c.introEnd = c.introStart + SongConfig.defaults.introEnd
            c.configured = false
            c.auto = true
        }
        return c
    }

    /// Every tag in use anywhere, most-used first then alphabetical — the registry, DERIVED.
    ///
    /// Cached because `SetupPanel` reads it from `body`, which re-renders at the player's tick
    /// rate (§8f's memoised-cover lesson). The cache is cleared in the four places `songs`
    /// changes and nowhere else, which is a completeness you can check by reading this file
    /// rather than by remembering to add a call — unlike `invalidateStatus()`, which the caller
    /// has to get right.
    private var tagCache: [String]?
    private var tagColorCache: [String: Int]?
    /// Clearing the two together, in one call, so "the caches are cleared in exactly these four
    /// places" stays a property you can check by reading this file rather than by remembering.
    func clearTagCaches() { tagCache = nil; tagColorCache = nil }

    /// Which colour slot each tag gets (§8g).
    ///
    /// From a HASH of the word, never from its position in `tagsInUse`: that list is ordered by
    /// how often each tag is used, so position-based colours would repaint tags nobody touched
    /// every time a song gained or lost one.
    ///
    /// FNV-1a over the UTF-8 of `tagKey`, NOT Swift's `hashValue`, which is seeded per process —
    /// the identical defect `tagsInUse` already recorded once, where the surviving spelling of a
    /// tag changed at random between launches. Being a pure function of the word also means the
    /// setter and the operator see the same colour for the same tag without anything travelling
    /// in `round.json`.
    ///
    /// Collisions take the next free slot, walking the keys in sorted order so the result does
    /// not depend on dictionary iteration either. With no more than `tagsMaxDistinct` tags every
    /// one ends up with a colour of its own.
    var tagColors: [String: Int] {
        if let c = tagColorCache { return c }
        let n = max(1, Palette.tagSlots)
        var taken = [Bool](repeating: false, count: n)
        var out: [String: Int] = [:]
        var keys = Set<String>()
        for c in songs.values { for t in c.tags { keys.insert(Store.tagKey(t)) } }
        for key in keys.sorted() {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x1000_0000_01b3 }
            var slot = Int(h % UInt64(n)), steps = 0
            while taken[slot] && steps < n { slot = (slot + 1) % n; steps += 1 }
            taken[slot] = true
            out[key] = slot
        }
        tagColorCache = out
        return out
    }
    func tagColor(_ tag: String) -> Int { tagColors[Store.tagKey(tag)] ?? 0 }
    var tagsInUse: [String] {
        if let c = tagCache { return c }
        // Counted per EXACT spelling, then the most-used spelling represents the key, ties
        // broken lexicographically.
        //
        // The obvious rule — "the first spelling we see wins" — is not a rule here, because
        // this walks `songs.values`, and Dictionary iteration order is not stable across
        // launches: Swift seeds its hashing per process. So "Rock" and "rock" in one library
        // would have relabelled the suggestion chip at random on each launch, and `--tagtest`
        // caught it by failing on one run after passing on the previous one. A check that
        // passes by luck is worse than no check.
        var perSpelling: [String: Int] = [:]
        for c in songs.values { for t in c.tags { perSpelling[t, default: 0] += 1 } }
        var total: [String: Int] = [:]
        var best: [String: String] = [:]
        for (t, n) in perSpelling.sorted(by: { $0.key < $1.key }) {   // stable input order
            let k = Store.tagKey(t)
            total[k, default: 0] += n
            if let cur = best[k] {
                if n > perSpelling[cur]! { best[k] = t }               // ties keep the earlier
            } else {
                best[k] = t
            }
        }
        let out = total.keys
            .sorted { a, b in
                total[a]! != total[b]! ? total[a]! > total[b]! : (best[a]! < best[b]!)
            }
            .compactMap { best[$0] }
        tagCache = out
        return out
    }
    func songsTagged(_ tag: String) -> [String] {
        let k = Store.tagKey(tag)
        return songs.filter { $0.value.tags.contains { Store.tagKey($0) == k } }.map(\.key)
    }

    func config(for path: String) -> SongConfig { songs[path] ?? SongConfig() }

    func set(_ c: SongConfig, for path: String) {
        songs[path] = c
        // merge into the raw dict so unknown keys written by the web app survive
        var d = (raw[path] as? [String: Any]) ?? [:]
        d["introStart"] = round2(c.introStart)
        d["introEnd"] = round2(c.introEnd)
        d["hook"] = round2(c.hook)
        d["ignoreEnd"] = c.ignoreEnd
        if c.trimDb != 0 { d["trimDb"] = c.trimDb } else { d.removeValue(forKey: "trimDb") }
        if c.played { d["played"] = true } else { d.removeValue(forKey: "played") }
        if c.configured { d["configured"] = true } else { d.removeValue(forKey: "configured") }
        if c.auto { d["auto"] = true } else { d.removeValue(forKey: "auto") }
        // Read-it-before-you-delete-it, the same rule `writeSettings` applies to `updateFeed`
        // and `resetAt`: only remove a key we successfully READ as empty. If a newer build ever
        // stores the note as something other than a bare string, this build decodes `""` — and
        // `set` runs on every marker edit, so an unguarded `removeValue` here would delete the
        // newer build's field on the first drag.
        if !c.note.isEmpty { d["note"] = c.note }
        else if d["note"] is String { d.removeValue(forKey: "note") }
        // Same guard, same reason. `[Any]` and not `[String]`: a newer build could write a list
        // of objects, and the point is to recognise "a list we did not understand" rather than
        // to delete it.
        if !c.tags.isEmpty { d["tags"] = c.tags }
        else if d["tags"] is [Any] { d.removeValue(forKey: "tags") }
        clearTagCaches()
        if let b = c.base {
            d["base"] = ["introStart": round2(b.introStart), "introEnd": round2(b.introEnd),
                         "hook": round2(b.hook), "trimDb": b.trimDb, "ignoreEnd": b.ignoreEnd]
        } else {
            d.removeValue(forKey: "base")
        }
        raw[path] = d
        scheduleSave()
    }

    func removeConfig(for path: String) {
        songs.removeValue(forKey: path)
        raw.removeValue(forKey: path)
        clearTagCaches()
        scheduleSave()
    }

    func pruneOrphans(existing: Set<String>) -> Int {
        let gone = songs.keys.filter { !existing.contains($0) }
        for k in gone { songs.removeValue(forKey: k); raw.removeValue(forKey: k) }
        if !gone.isEmpty { clearTagCaches(); scheduleSave() }
        return gone.count
    }

    /// Internal and static so `--guesstest` can prove that what the clamps produce is still
    /// serialisable after this multiply. The multiply is the point: any finite input above
    /// ~1.8e306 comes out of here as +infinity, which `isValidJSONObject` rejects.
    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func round2(_ v: Double) -> Double { Store.round2(v) }

    private func writeSettings() {
        var s = (raw["_settings"] as? [String: Any]) ?? [:]
        s["normalize"] = normalize
        s["loudnessScope"] = loudnessScope.rawValue
        // Guarded like `updateFeed` and `schema`, not written blind. The rule exists because
        // overwriting a `_settings` key this build failed to READ is how every `resetAt` stamp
        // was wiped once: if a newer build ever stores the theme as something other than a bare
        // string, this build would decode `""` → `.dark` and overwrite it on the next save —
        // and `writeSettings` runs on every marker edit.
        if s["theme"] == nil || s["theme"] is String { s["theme"] = theme.rawValue }
        s["lastPlaylist"] = lastPlaylist
        if !resetAt.isEmpty { s["resetAt"] = resetAt }   // never delete stamps we merely failed to read
        // Same rule as `resetAt`, one line above: only delete a key we successfully READ as
        // empty. A newer build storing the feed as anything but a bare String reads as "" here,
        // and deleting it then would be the exact failure `resetAt` was fixed for.
        if !updateFeed.isEmpty {
            s["updateFeed"] = updateFeed
        } else if s["updateFeed"] is String {
            s.removeValue(forKey: "updateFeed")
        }
        // Never write a number LOWER than the file already carries: that would tell the build
        // that actually understands the format that it is the stale one. And if the value is not
        // an Int at all, leave it entirely alone — we cannot know what it means to the build that
        // wrote it, and overwriting it IS the downgrade this guard exists to prevent.
        if s["schema"] == nil || s["schema"] is Int {
            s["schema"] = max(Store.schema, schemaOnDisk)
        }
        // Same read-it-before-you-delete-it rule as `updateFeed` and `resetAt` above.
        if !backupDir.isEmpty {
            s["backupDir"] = backupDir
        } else if s["backupDir"] is String {
            s.removeValue(forKey: "backupDir")
        }
        s["writtenBy"] = AppVersion.short
        if !dismissedUpdate.isEmpty { s["dismissedUpdate"] = dismissedUpdate }
        if dismissedSchema > 0 { s["dismissedSchema"] = dismissedSchema }
        s["lastRanVersion"] = AppVersion.short
        raw["_settings"] = s
    }

    func settingsChanged() { writeSettings(); scheduleSave() }

    // Debounced like the web version's 250 ms save, so dragging a marker doesn't hammer the disk.
    private var saveWork: DispatchWorkItem?
    private(set) var saveState = "—"
    private(set) var saveFailed = false
    /// Store is a plain class, so a write that happens 250 ms after the click has no way to reach
    /// the UI. Without this the label sat on "saving…" forever and a failed write was invisible.
    var onSaveStateChange: (() -> Void)?

    func scheduleSave() {
        guard !readOnly else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func saveNow() {
        guard !readOnly else { return }
        writeSettings()
        guard JSONSerialization.isValidJSONObject(raw) else {
            saveFailed = true; saveState = "บันทึกไม่ได้ (ข้อมูลเสีย)"; onSaveStateChange?(); return
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: raw,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: AppPaths.config, options: .atomic)
            saveFailed = false
            saveState = "saved ✓"
            onSaveStateChange?()
        } catch {
            // A read-only volume, a full disk or a TCC-blocked folder used to show "saved ✓" all
            // day and lose every marker at quit.
            saveFailed = true
            saveState = "บันทึกไม่สำเร็จ!"
            onSaveStateChange?()
        }
    }
}

/// Append-only taping log. The web app kept this server-side so two windows couldn't clobber it;
/// a single native process gets that for free, but the file format is unchanged.
final class LogStore {
    private(set) var events: [LogEvent] = []
    private(set) var saveFailed = false

    init() { load() }

    func load() {
        events = []
        guard let data = try? Data(contentsOf: AppPaths.log),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["events"] as? [[String: Any]] else { return }
        var seen: [String: Int] = [:]
        events = arr.compactMap {
            guard let t = $0["t"] as? String, let e = $0["event"] as? String else { return nil }
            let path = ($0["path"] as? String) ?? ""
            let k = "\(t)\u{1}\(path)\u{1}\(e)"
            let d = seen[k] ?? 0
            seen[k] = d + 1
            return LogEvent(t: t,
                            playlist: ($0["playlist"] as? String) ?? "",
                            path: path,
                            event: e,
                            dup: d,
                            date: LogStore.isoParse(t))
        }
    }

    func append(playlist: String, path: String, event: String) {
        guard event == "correct" || event == "wrong" else { return }
        load()   // re-read first: the web fallback appends server-side, and a stale snapshot
                 // rewritten wholesale would delete every take it logged since we launched
        let now = LogStore.isoNow()
        let dup = events.filter { $0.t == now && $0.path == path && $0.event == event }.count
        events.append(LogEvent(t: now, playlist: playlist, path: path, event: event,
                               dup: dup, date: LogStore.isoParse(now)))
        save()
    }

    @discardableResult
    func undoLast(playlist: String?) -> LogEvent? {
        load()
        guard let i = events.lastIndex(where: { playlist == nil || $0.playlist == playlist })
        else { return nil }
        let e = events.remove(at: i)
        save()
        return e
    }

    func clear(playlist: String?) {
        load()
        if let pl = playlist { events.removeAll { $0.playlist == pl } } else { events.removeAll() }
        save()
    }

    private func save() {
        let arr: [[String: Any]] = events.map {
            ["t": $0.t, "playlist": $0.playlist, "path": $0.path, "event": $0.event]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["events": arr],
            options: [.prettyPrinted, .withoutEscapingSlashes]) else { saveFailed = true; return }
        do { try data.write(to: AppPaths.log, options: .atomic); saveFailed = false }
        catch { saveFailed = true }
    }

    // matches Python's datetime.now().astimezone().isoformat(timespec="seconds")
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// The web app writes `new Date().toISOString()`, which ALWAYS carries milliseconds. One
    /// formatter cannot accept both — withFractionalSeconds makes the fraction mandatory — so a
    /// reset performed in the web app parsed as nil and every badge stayed stuck.
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    /// One formatter, not one per row per render.
    private static let hms: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static func clockText(_ iso: String) -> String {
        guard let d = isoParse(iso) else { return "--:--:--" }
        return hms.string(from: d)
    }
    private static let hmFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        f.locale = Locale(identifier: "th_TH"); return f
    }()
    static func hmText(_ d: Date) -> String { hmFmt.string(from: d) }
    static func dayText(_ d: Date) -> String { dayFmt.string(from: d) }
    static func isoNow() -> String { iso.string(from: Date()) }
    /// Only for the headless self-check, which needs events at chosen times.
    static func isoFmtForTest(_ d: Date) -> String { iso.string(from: d) }
    static func isoParse(_ s: String) -> Date? { iso.date(from: s) ?? isoFrac.date(from: s) }
}
