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

enum LoudnessScope: String { case intro, song }

/// Reads and writes the same two files the web app uses, preserving any keys it doesn't know
/// about. That is what lets both versions run against one folder — and lets the operator fall
/// back to the web app mid-taping without losing a thing.
final class Store {
    private(set) var raw: [String: Any] = [:]      // untouched backing store
    private(set) var songs: [String: SongConfig] = [:]

    // _settings
    var normalize = true
    var loudnessScope: LoudnessScope = .intro
    var lastPlaylist = ""
    var resetAt: [String: String] = [:]

    init() { load() }

    func load() {
        raw = (try? Data(contentsOf: AppPaths.config))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        songs.removeAll()
        for (k, v) in raw where k != "_settings" {
            guard let d = v as? [String: Any] else { continue }
            songs[k] = Store.decode(d)
        }
        let s = raw["_settings"] as? [String: Any] ?? [:]
        normalize = (s["normalize"] as? Bool) ?? true
        loudnessScope = LoudnessScope(rawValue: (s["loudnessScope"] as? String) ?? "") ?? .intro
        lastPlaylist = (s["lastPlaylist"] as? String) ?? ""
        // Per-key: one bad value used to fail the whole cast, and writeSettings would then erase
        // every reset stamp in the file.
        resetAt = ((s["resetAt"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
    }

    private static func decode(_ d: [String: Any]) -> SongConfig {
        var c = SongConfig()
        // NaN/Infinity would crash saveNow(): JSONSerialization raises an Obj-C exception that
        // `try?` cannot catch, and the bad value is already on disk so it recurs every launch.
        if let v = d["introStart"] as? Double, v.isFinite { c.introStart = max(0, v) }
        if let v = d["introEnd"] as? Double, v.isFinite { c.introEnd = max(0, v) }
        if let v = d["hook"] as? Double, v.isFinite { c.hook = max(0, v) }
        if let v = d["ignoreEnd"] as? Bool { c.ignoreEnd = v }
        if let v = d["trimDb"] as? Double, v.isFinite { c.trimDb = min(12, max(-12, v)) }
        if let v = d["played"] as? Bool { c.played = v }
        if let v = d["configured"] as? Bool { c.configured = v }
        if let v = d["auto"] as? Bool { c.auto = v }
        if let bd = d["base"] as? [String: Any] {
            var b = SongBase()
            if let v = bd["introStart"] as? Double, v.isFinite { b.introStart = max(0, v) }
            if let v = bd["introEnd"] as? Double, v.isFinite { b.introEnd = max(0, v) }
            if let v = bd["hook"] as? Double, v.isFinite { b.hook = max(0, v) }
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
        scheduleSave()
    }

    func pruneOrphans(existing: Set<String>) -> Int {
        let gone = songs.keys.filter { !existing.contains($0) }
        for k in gone { songs.removeValue(forKey: k); raw.removeValue(forKey: k) }
        if !gone.isEmpty { scheduleSave() }
        return gone.count
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    private func writeSettings() {
        var s = (raw["_settings"] as? [String: Any]) ?? [:]
        s["normalize"] = normalize
        s["loudnessScope"] = loudnessScope.rawValue
        s["lastPlaylist"] = lastPlaylist
        if !resetAt.isEmpty { s["resetAt"] = resetAt }   // never delete stamps we merely failed to read
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
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func saveNow() {
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
    static func isoNow() -> String { iso.string(from: Date()) }
    static func isoParse(_ s: String) -> Date? { iso.date(from: s) ?? isoFrac.date(from: s) }
}
