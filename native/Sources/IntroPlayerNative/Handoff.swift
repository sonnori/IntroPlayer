import Foundation
import AVFoundation

// MARK: - The handover package

/// `round.json`, written into the round's own folder so that copying `songs/<round>/` carries the
/// questions with the audio. It is an EXPORT FORMAT, not the live file: `config.json` stays the
/// working file for both the native and the web app, which is what keeps the web fallback usable
/// mid-taping. Import is therefore a merge — it touches only the five question fields and never
/// `played`, `resetAt` or the log, so a marker fix sent after handover cannot wipe a taping.
struct RoundPackage {
    static let fileName = "round.json"
    static let version = 1

    var round: String = ""
    var by: String = ""
    var at: String = ""
    /// Keyed by FILE NAME, not by the path under `songs/` — the receiving side may file the round
    /// under a different folder name, and the package's scope is one round anyway.
    var songs: [String: Entry] = [:]
    /// The colours the sender CHOSE for the tags this round uses, `Store.tagKey` → slot index
    /// (§8g). Only the chosen ones: a tag coloured by the hash needs nothing in the file,
    /// because the hash is a pure function of the word and both machines compute the same answer.
    ///
    /// Merged ADDITIVELY and SILENTLY on the way in (`Store.mergeTagColors`): a local choice
    /// always wins, and a tag missing from an incoming set means "I have nothing to say", never
    /// "clear yours". It gets no `DiffRow`, unlike the note and the tag list, and that is a
    /// deliberate asymmetry — a colour changes nothing that goes to air, and a diff row per tag
    /// colour would bury the rows that decide what the audience hears.
    var tagColors: [String: Int] = [:]

    struct Entry {
        var b = SongBase()
        var configured = false
        var auto = false
        /// The setter's note for the operator. Travels because that is the entire point of the
        /// field — it is written on one machine to be read on another (§8e). Merged
        /// ADDITIVELY on the way back: see `Handoff.plan`.
        var note = ""
        /// Merged as a set UNION, which is the additive rule for a list.
        var tags: [String] = []
    }

    static func url(forRound playlist: String) -> URL {
        (playlist.isEmpty ? AppPaths.songs : AppPaths.songs.appendingPathComponent(playlist))
            .appendingPathComponent(fileName)
    }

    // MARK: Decode

    static func read(_ url: URL) -> RoundPackage? {
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var p = RoundPackage()
        p.round = (o["round"] as? String) ?? ""
        // Bounded on read: this file is hand-editable and written by another machine, and `by`
        // lands in a one-line strip here. §15's rule for everything crossing a boundary.
        p.by = Store.clampName((o["by"] as? String) ?? "")
        p.at = (o["at"] as? String) ?? ""
        for (name, v) in (o["songs"] as? [String: Any]) ?? [:] {
            guard let d = v as? [String: Any] else { continue }
            var e = Entry()
            // Same non-finite guard as Store.decode: a NaN that reaches JSONSerialization raises
            // an Obj-C exception `try?` cannot catch, and it would then recur every launch.
            if let x = d["introStart"] as? Double { e.b.introStart = Store.clampMarker(x) }
            if let x = d["introEnd"]   as? Double { e.b.introEnd   = Store.clampMarker(x) }
            if let x = d["hook"]       as? Double { e.b.hook       = Store.clampMarker(x) }
            if let x = d["trimDb"]     as? Double, x.isFinite { e.b.trimDb = min(12, max(-12, x)) }
            if let x = d["ignoreEnd"]  as? Bool { e.b.ignoreEnd = x }
            if let x = d["configured"] as? Bool { e.configured = x }
            if let x = d["auto"]       as? Bool { e.auto = x }
            if let x = d["note"]       as? String { e.note = Store.clampNote(x) }
            if let x = d["tags"]       as? [Any] {
                e.tags = Store.clampTags(x.compactMap { $0 as? String })
            }
            // A degenerate range disarms the intro-end guard downstream, so repair on the way in
            // rather than trusting the sender's file.
            if e.b.introEnd <= e.b.introStart {
                e.b.introEnd = e.b.introStart + SongBase().introEnd
                e.configured = false
                e.auto = true
            }
            p.songs[name] = e
        }
        // Clamped to the slots THIS build has: the index is the wire format, so a round written
        // by a build with a longer ramp must not be able to index past the end of ours.
        for (k, v) in ((o["tagColors"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard p.tagColors.count < Store.tagColorChoiceMax,
                  let i = v as? Int, i >= 0, i < Palette.tagSlots,
                  let key = Store.clampTag(k).map(Store.tagKey) else { continue }
            p.tagColors[key] = i
        }
        return p
    }

    // MARK: Encode

    func write(to url: URL) throws {
        var out: [String: Any] = [
            "version": RoundPackage.version, "round": round, "by": by, "at": at,
        ]
        var ss: [String: Any] = [:]
        for (name, e) in songs {
            var d: [String: Any] = [
                "introStart": r2(e.b.introStart), "introEnd": r2(e.b.introEnd),
                "hook": r2(e.b.hook), "ignoreEnd": e.b.ignoreEnd,
            ]
            if e.b.trimDb != 0 { d["trimDb"] = e.b.trimDb }
            if e.configured { d["configured"] = true }
            if e.auto { d["auto"] = true }
            if !e.note.isEmpty { d["note"] = e.note }
            if !e.tags.isEmpty { d["tags"] = e.tags }
            ss[name] = d
        }
        out["songs"] = ss
        if !tagColors.isEmpty { out["tagColors"] = tagColors }
        guard JSONSerialization.isValidJSONObject(out) else {
            throw NSError(domain: "IntroPlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ข้อมูลไม่ถูกต้อง"])
        }
        let data = try JSONSerialization.data(
            withJSONObject: out,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

// MARK: - Pre-flight check

/// What the handover screen lists. Each item points at one song so the row can jump to it.
struct PreflightItem: Identifiable {
    enum Kind {
        case missingFile, neverOpened, stillAuto, shortIntro, hookPastEnd, silentIntro, hookDefault
        case squashedIntro
        var blocking: Bool {
            switch self {
            case .missingFile, .neverOpened, .silentIntro: return true
            default: return false
            }
        }
        var label: String {
            switch self {
            case .missingFile:  return "ไฟล์เพลงหาย"
            case .neverOpened:  return "ยังไม่เคยเปิด"
            case .stillAuto:    return "ยังเป็นค่าที่แอปเดา"
            case .shortIntro:   return "Intro สั้นกว่า 3 วิ"
            case .hookPastEnd:  return "Hook เลยท้ายเพลง"
            case .silentIntro:  return "ช่วง Intro แทบไม่มีเสียง"
            case .hookDefault:  return "Hook ยังเป็นค่าเริ่มต้น"
            case .squashedIntro: return "หัวเพลงชนเพดาน — เสียงจะโดนบี้"
            }
        }
    }
    let kind: Kind
    let path: String
    let detail: String
    var id: String { "\(kind)\u{1}\(path)" }
}

enum Preflight {
    static let minIntroSec: Double = 3.0
    /// Below the web version's MIN_USABLE_RMS — at this level there is nothing for the audience
    /// to hear, so the question is unusable however well the markers are placed.
    static let silentRms: Double = 0.005
    /// How much gain the limiter may take back before it is worth telling the setter. Under a
    /// couple of dB the limiter is doing its job on transients; past it, it is working
    /// continuously, the intro does not reach the level the app reports, and it goes out
    /// squashed. Measured on the real library: two of nine intros, one by 11.5 dB, with nothing
    /// anywhere saying so.
    static let maxLimiterEatsDb: Double = 2.0

    /// The checks that need no audio decode. Returns instantly, so the handover screen can open
    /// without a spinner; `audioChecks` fills in the rest.
    static func fast(round: String, paths: [String], store: Store) -> [PreflightItem] {
        var out: [PreflightItem] = []
        for p in paths {
            let name = Library.baseName(p)
            guard FileManager.default.fileExists(atPath: Library.url(p).path) else {
                out.append(PreflightItem(kind: .missingFile, path: p, detail: name)); continue
            }
            guard let c = store.songs[p] else {
                out.append(PreflightItem(kind: .neverOpened, path: p, detail: name)); continue
            }
            if c.auto || !c.isConfigured {
                out.append(PreflightItem(kind: .stillAuto, path: p, detail: name))
            }
            let len = c.introEnd - c.introStart
            if len < minIntroSec {
                out.append(PreflightItem(kind: .shortIntro, path: p,
                                         detail: String(format: "%@ — %.1f วิ", name, len)))
            }
            // Never moved off the default. The real library had 8 of 9 songs like this, so the
            // hook step was simply being skipped — and Reveal is the on-camera payoff.
            if SongConfig.same(c.hook, SongConfig.defaults.hook) {
                out.append(PreflightItem(kind: .hookDefault, path: p, detail: name))
            }
            // Duration comes from the file header, not a decode, so this stays cheap.
            if let d = duration(p), c.hook >= d - 0.05 {
                out.append(PreflightItem(kind: .hookPastEnd, path: p,
                                         detail: String(format: "%@ — hook %.0f วิ / เพลง %.0f วิ",
                                                        name, c.hook, d)))
            }
        }
        return out
    }

    /// Needs a decode per song, so it runs off the main actor and the screen fills in as it goes.
    static func silentIntros(paths: [String], store: Store) -> [PreflightItem] {
        var out: [PreflightItem] = []
        for p in paths {
            if Task.isCancelled { return out }
            guard let c = store.songs[p],
                  let a = try? Analysis.analyse(url: Library.url(p)) else { continue }
            let lo = min(c.introStart, c.introEnd), hi = min(max(c.introStart, c.introEnd), a.duration)
            let rms = a.rms(lo, hi)
            if rms < silentRms {
                out.append(PreflightItem(kind: .silentIntro, path: p, detail: Library.baseName(p)))
                continue      // a silent intro is already the louder complaint about this song
            }
            // Same arithmetic as `Player.applyGain`, on the same window: how much of the gain
            // the brick wall will claw back. A high-crest intro (near-silence plus one
            // transient) asks for a large boost it physically cannot be given.
            let m = a.measuredLufs(config: c, scope: store.loudnessScope)
            if m.lufs.isFinite {
                let gain = min(max(Analysis.targetLufs - m.lufs, -12), 12) + c.trimDb
                let pk = Double(a.peak(lo, hi))
                if pk > 0 {
                    let eats = gain - (Player.limiterCeilingDb - 20 * log10(pk))
                    if eats > maxLimiterEatsDb {
                        out.append(PreflightItem(
                            kind: .squashedIntro, path: p,
                            detail: String(format: "%@ — กินคืน %.1f dB", Library.baseName(p), eats)))
                    }
                }
            }
        }
        return out
    }

    static func duration(_ p: String) -> Double? {
        guard let f = try? AVAudioFile(forReading: Library.url(p)) else { return nil }
        let sr = f.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        return Double(f.length) / sr
    }
}

// MARK: - One round waiting to be taken in

/// A `round.json` sitting in a round's folder that this library has not taken in yet.
///
/// The FOLDER is part of it rather than read back out of the package, and that is the point:
/// `round.json` is keyed by file name so the receiving side may file a round under a different
/// folder name (§8e), so `pkg.round` is the name the sender used while `round` is where
/// accepting it will actually land. With one round on screen that distinction is a curiosity;
/// with three folders arriving from three setters it is the difference between a strip you can
/// act on and one you have to go and verify.
struct IncomingRound: Identifiable, Equatable {
    /// The folder under `songs/` — where the import lands. `""` is the loose-files round.
    let round: String
    let pkg: RoundPackage

    /// Also the dismissal key. `at` is stamped by `Handoff.export`, so a round the sender
    /// re-exports is a DIFFERENT item and raises the strip again instead of staying hidden
    /// behind a wave-off of the older file.
    var id: String { round + "\u{1}" + pkg.at }
    var label: String { Library.label(round) }
    /// The sender's own name for the round is not the folder it is sitting in. Legal, and worth
    /// saying on screen so "รอบไหน" is never ambiguous.
    var renamed: Bool { !pkg.round.isEmpty && pkg.round != round }

    static func == (a: IncomingRound, b: IncomingRound) -> Bool { a.id == b.id }
}

// MARK: - Import

/// Which field a diff row is about.
///
/// `MarkerField` could not simply grow a `.note` case: it is `CaseIterable` and drives
/// `onsiteEdits`, `revert`, the setup panel's field cards and `--handoff`, every one of which
/// would then have to answer "what does reverting a sentence mean". Here the note is only ever
/// a label and two strings, which is all the diff table needs.
///
/// `key` for a marker is its `rawValue`, so every existing row id is unchanged.
enum DiffField: Hashable {
    case marker(MarkerField)
    case note
    case tags

    var key: String {
        switch self {
        case .marker(let f): return f.rawValue
        case .note: return "note"
        case .tags: return "tags"
        }
    }
    var label: String {
        switch self {
        case .marker(let f): return f.label
        case .note: return "โน้ตคนรัน"
        case .tags: return "แท็ก"
        }
    }
    /// The fields that merge ADDITIVELY (§8e): `plan` raises one of these rows only when the
    /// sender has something this machine does not, so unlike a marker row it can never be our
    /// own on-site edit looking back at us.
    ///
    /// That asymmetry is load-bearing in `isWaiting`. `alreadyTakenIn` compares `base`, and
    /// `base` is a `SongBase` — the five marker fields — so it cannot see these fields at all
    /// and must not be allowed to veto them. Before this, a handover whose only change was a
    /// note or a tag matched on every marker, `alreadyTakenIn` answered "already taken in", and
    /// the round raised no strip and no 📥.
    ///
    /// The same set as `isProse` today, and deliberately a SEPARATE property: that one is about
    /// how a row is laid out, this one about whether the row can be ignored. A field that is
    /// additive but fits in a value column would have to split them, and discovering that by
    /// watching a strip quietly stop appearing is not an acceptable way to find out.
    var isAdditive: Bool {
        switch self {
        case .marker: return false
        case .note, .tags: return true
        }
    }
    /// Rendered on its own lines rather than in a value column — a sentence or a tag list
    /// cannot be compared in ~160 pt, and reading both sides IS the decision the row exists for.
    var isProse: Bool {
        switch self {
        case .marker: return false
        case .note, .tags: return true
        }
    }
}

/// One field the incoming package disagrees with the local file about. The comparison is
/// incoming-vs-local (not incoming-vs-base), so it is still correct when BOTH sides edited the
/// same song since the handover — the setter sees both values and picks.
struct DiffRow: Identifiable {
    let path: String
    let field: DiffField
    let mine: String
    let theirs: String
    var id: String { "\(path)\u{1}\(field.key)" }
}

/// What importing a package would do, computed before anything is written.
struct ImportPlan {
    var package: RoundPackage
    /// The FOLDER under `songs/` this plan lands in. Not derivable from `package.round`: a
    /// `round.json` is keyed by file name precisely so the receiving side may file a round under
    /// a different folder name (§8e), so `package.round` is where it came FROM. Stored rather
    /// than passed around a second time, so `applyImport` cannot read it off whatever round
    /// happens to be selected when the sheet is dismissed.
    var round = ""
    /// Songs the local config has never seen — applied without asking, there is nothing to lose.
    var fresh: [String] = []
    /// Songs whose values differ; the user accepts or rejects per row.
    var rows: [DiffRow] = []
    /// In the package, identical locally. Counted only.
    var unchanged: [String] = []
    /// In the package, but no audio file in this round.
    var orphans: [String] = []

    var songCount: Int { fresh.count + unchanged.count + Set(rows.map(\.path)).count }
    var hasChoices: Bool { !rows.isEmpty }
}

enum Handoff {
    /// Tags in `incoming` that `local` does not already have, compared on `Store.tagKey` so a
    /// difference in Latin case is not a new tag. Order follows the sender.
    static func tagsAdded(_ local: [String], _ incoming: [String]) -> [String] {
        let have = Set(local.map(Store.tagKey))
        var seen = Set<String>()
        return incoming.filter { t in
            let k = Store.tagKey(t)
            return !have.contains(k) && seen.insert(k).inserted
        }
    }

    /// Build the package from what is on disk right now, for one round.
    static func package(round: String, paths: [String], store: Store, by: String) -> RoundPackage {
        var p = RoundPackage()
        p.round = round
        p.by = Store.clampName(by)
        p.at = LogStore.isoNow()
        for path in paths {
            let c = store.config(for: path)
            p.songs[Library.baseName(path)] =
                RoundPackage.Entry(b: c.current, configured: c.isConfigured, auto: c.auto,
                                   note: c.note, tags: c.tags)
        }
        // Scoped to the tags this round carries, not the whole library's palette: `round.json`
        // describes one round, and a colour for a tag that is not in it would be noise the
        // receiving side cannot even see the effect of.
        for (_, e) in p.songs {
            for t in e.tags {
                let k = Store.tagKey(t)
                if let slot = store.tagColorChoice[k] { p.tagColors[k] = slot }
            }
        }
        return p
    }

    /// Export: write `round.json` into the round's folder AND stamp `base` on every song, so from
    /// this moment on any change to the question reads as an edit made after the handover.
    @discardableResult
    static func export(round: String, paths: [String], store: Store, by: String) throws -> URL {
        let p = package(round: round, paths: paths, store: store, by: by)
        let url = RoundPackage.url(forRound: round)
        try p.write(to: url)
        for path in paths {
            var c = store.config(for: path)
            c.base = c.current
            store.set(c, for: path)
        }
        store.saveNow()
        return url
    }

    /// True when every song in the package already carries this exact snapshot as its signed-off
    /// `base` — i.e. the package IS a handover this library has already been through, and
    /// anything that differs now is a local edit made SINCE.
    ///
    /// **This is what stops the strip from offering work back to the person who did it.** Export
    /// and import both stamp `base` from the result, so a round the setter sent and then kept
    /// editing, and a round the operator imported and then changed on set, both end up differing
    /// from the file on disk — and `plan` compares incoming-vs-local, so both produced rows. The
    /// diff sheet pre-accepts every row, so pressing the obvious button would have reverted the
    /// on-site edits to the snapshot they were derived from, which is the one thing §8e's
    /// "แก้ที่กอง" badges exist to protect.
    ///
    /// It mattered little while only the selected round was checked. Sweeping every round turns
    /// it into a strip that reappears from anywhere, and §12 is explicit that a warning which
    /// fires when nothing is wrong is one that gets ignored on the day it matters.
    ///
    /// A song with no local entry, or no `base` at all (never handed over), answers false — so a
    /// package carrying anything genuinely new still counts as waiting.
    static func alreadyTakenIn(_ pkg: RoundPackage, round: String, paths: [String],
                               store: Store) -> Bool {
        let byName = Dictionary(paths.map { (Library.baseName($0), $0) },
                                uniquingKeysWith: { a, _ in a })
        var matched = 0
        for (name, e) in pkg.songs {
            // No audio for it in this round: an orphan, with nothing local to have been
            // signed off against. `plan` reports it separately and it raises no row.
            guard let path = byName[name] else { continue }
            guard let local = store.songs[path], let base = local.base, base == e.b else {
                return false
            }
            matched += 1
        }
        return matched > 0
    }

    /// Is this package something the round still has to take in? The sweep's per-round decision.
    ///
    /// Two independent tests, and they are complementary rather than redundant:
    ///
    /// - `store.takenIn` — a human has reviewed THIS package (this folder, this export time).
    ///   The authoritative answer, and the only one that can see a review whose outcome was
    ///   "no": a declined row leaves the local value and `base` agreeing with each other and
    ///   both differing from the sender, so no comparison can tell it from an untouched round.
    ///   It is also the only one that notices a handover carrying nothing but a `note` or a
    ///   `tag`, because `SongBase` holds the five marker fields and nothing else.
    /// - `alreadyTakenIn` — the values already match what was signed off, so there is nothing to
    ///   take. This covers the round a setter exported and still holds locally, which was never
    ///   "reviewed" here and must not raise a strip either.
    static func isWaiting(_ pkg: RoundPackage, round: String, paths: [String], store: Store) -> Bool {
        let p = plan(pkg, round: round, paths: paths, store: store)
        guard !(p.fresh.isEmpty && p.rows.isEmpty) else { return false }
        guard !store.takenIn.contains(reviewKey(round: round, pkg: pkg)) else { return false }
        // An additive row is unambiguous — see `DiffField.isAdditive`. `alreadyTakenIn` compares
        // `base`, which holds the five marker fields only, so it cannot see these and gets no
        // vote on them. Checked BEFORE it, or it would veto the whole package on the strength of
        // the markers agreeing.
        if p.rows.contains(where: { $0.field.isAdditive }) { return true }
        return !alreadyTakenIn(pkg, round: round, paths: paths, store: store)
    }

    /// The key `Store.takenIn` records a review under: the folder, the export time, **and a
    /// fingerprint of the content**.
    ///
    /// Deliberately NOT `IncomingRound.id`, which is folder + `at` only. That id is right for
    /// the "ไว้ก่อน" dismissal — §8e wants a re-export to reappear even if nothing changed,
    /// because a wave-off is a "not now" and not a decision. A REVIEW is a decision, so it has
    /// to be keyed on what was decided about: with `at` alone, a `round.json` edited by hand
    /// while keeping its timestamp would have been swallowed as already-reviewed and the
    /// operator would never have seen it. Including the content makes the record mean exactly
    /// "I have seen these values", which is the only claim it is entitled to make.
    ///
    /// Canonical before hashing — sorted keys, fixed field order, two decimals on the markers
    /// the way `Store.round2` stores them — so the same package hashes the same on both
    /// machines and across launches.
    static func reviewKey(round: String, pkg: RoundPackage) -> String {
        var s = ""
        for name in pkg.songs.keys.sorted() {
            guard let e = pkg.songs[name] else { continue }
            s += name
            s += String(format: "|%.2f|%.2f|%.2f|%.2f|%@",
                        e.b.introStart, e.b.introEnd, e.b.hook, e.b.trimDb,
                        e.b.ignoreEnd ? "1" : "0")
            s += "|" + e.note + "|" + e.tags.sorted().joined(separator: ",") + "\n"
        }
        return "\(round)\u{1}\(pkg.at)\u{1}\(String(Store.fnv1a(s), radix: 36))"
    }

    /// Every round holding a `round.json`, read once and unfiltered.
    ///
    /// Separate from `waitingRounds` because the prune set for `Store.takenIn` is "every package
    /// on disk", which is the complement of what `waitingRounds` returns. It lives HERE and not
    /// in `AppModel` on purpose: §8e's defect was never the per-round decision, it was how many
    /// rounds the caller asked about, so a second loop over `playlists` written in the UI layer
    /// is exactly the shape that regressed — and a test of the decision alone would pass either
    /// way. One loop, one place, injected `read`.
    static func packagesOnDisk(
        _ rounds: [String],
        read: (String) -> RoundPackage? = { RoundPackage.read(RoundPackage.url(forRound: $0)) }
    ) -> [IncomingRound] {
        rounds.compactMap { round in
            guard let pkg = read(round) else { return nil }
            return IncomingRound(round: round, pkg: pkg)
        }
    }

    /// Every round holding a `round.json` that has not been taken in yet.
    ///
    /// A pure function, with `read` and `songsIn` injected, for one reason: the defect this
    /// replaced was not in the per-round decision, it was in **how many rounds the caller asked
    /// about** — so a test of the decision alone would have passed before and after. This way
    /// `--incomingtest` drives the real loop rather than a copy of it. `AppModel.detectIncoming`
    /// is now a single call to this.
    ///
    /// `compactMap`, so there is no shape in which it can stop at the first hit.
    static func waitingRounds(
        _ rounds: [String],
        store: Store,
        songsIn: (String) -> [String],
        read: (String) -> RoundPackage? = { RoundPackage.read(RoundPackage.url(forRound: $0)) }
    ) -> [IncomingRound] {
        // Built on `packagesOnDisk` rather than walking `rounds` again, so the sweep this
        // function exists to guarantee has exactly one implementation.
        packagesOnDisk(rounds, read: read).filter {
            isWaiting($0.pkg, round: $0.round, paths: songsIn($0.round), store: store)
        }
    }

    static func plan(_ pkg: RoundPackage, round: String, paths: [String], store: Store)
        -> ImportPlan
    {
        var plan = ImportPlan(package: pkg, round: round)
        let byName = Dictionary(paths.map { (Library.baseName($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (name, e) in pkg.songs.sorted(by: { $0.key < $1.key }) {
            guard let path = byName[name] else { plan.orphans.append(name); continue }
            guard let local = store.songs[path] else { plan.fresh.append(path); continue }
            let mine = local.current
            var diffs: [DiffRow] = []
            for f in MarkerField.allCases {
                let a = f.text(mine), b = f.text(e.b)
                if a != b {
                    diffs.append(DiffRow(path: path, field: .marker(f), mine: a, theirs: b))
                }
            }
            // The note merges ADDITIVELY: an EMPTY incoming value means "I have nothing to say
            // about this song", never "delete yours", so it raises no row and changes nothing.
            //
            // That one rule is what makes §13's `round.json` gap stop blocking this feature.
            // `RoundPackage.write` rebuilds its dictionary from the struct, so a build that does
            // not know the field DROPS it rather than merging it — and a round sent
            // setter(new) → operator(old) → setter(new) therefore comes back with the note
            // missing. Under this rule that reads as silence and the local note survives; under
            // a symmetric rule it would read as a deletion, and the sheet pre-accepts every row.
            //
            // The cost, so nobody has to rediscover it: a note DELETED on the operator's machine
            // cannot travel — it has to be said out loud. That is the safe direction of the two.
            if !e.note.isEmpty, e.note != local.note {
                diffs.append(DiffRow(path: path, field: .note,
                                     mine: local.note, theirs: e.note))
            }
            // Tags are the same rule for a list: UNION. A row is raised only for tags the
            // receiving side does not already have, and `theirs` shows the RESULT of accepting
            // rather than the sender's list, because the union is what would actually happen.
            //
            // It is still a row with a checkbox and not a silent merge: the setter gets to
            // decline a tag, and a union they cannot see is a change nobody reviewed. What does
            // NOT travel, by the same additive direction as the note, is a tag the operator
            // REMOVED — that has to be said out loud.
            let added = Handoff.tagsAdded(local.tags, e.tags)
            if !added.isEmpty {
                diffs.append(DiffRow(
                    path: path, field: .tags,
                    mine: local.tags.isEmpty ? "" : local.tags.joined(separator: " · "),
                    theirs: Store.clampTags(local.tags + added).joined(separator: " · ")))
            }
            if diffs.isEmpty { plan.unchanged.append(path) } else { plan.rows += diffs }
        }
        return plan
    }

    /// Apply a plan. `accepted` holds the `DiffRow.id`s the user ticked; every other row keeps the
    /// local value. `base` is stamped from the RESULT, so after a review both sides agree on what
    /// was signed off and the badges clear.
    static func apply(_ plan: ImportPlan, accepted: Set<String>, store: Store) {
        var touched = Set(plan.fresh)
        touched.formUnion(plan.unchanged)
        touched.formUnion(plan.rows.map(\.path))

        let byName = Dictionary(
            touched.map { (Library.baseName($0), $0) }, uniquingKeysWith: { a, _ in a })

        for (name, e) in plan.package.songs {
            guard let path = byName[name] else { continue }
            var c = store.config(for: path)
            let isFresh = plan.fresh.contains(path)
            for f in MarkerField.allCases {
                let rowID = "\(path)\u{1}\(DiffField.marker(f).key)"
                let take = isFresh || accepted.contains(rowID)
                guard take else { continue }
                switch f {
                case .introStart: c.introStart = e.b.introStart
                case .introEnd:   c.introEnd = e.b.introEnd
                case .hook:       c.hook = e.b.hook
                case .trimDb:     c.trimDb = e.b.trimDb
                case .ignoreEnd:  c.ignoreEnd = e.b.ignoreEnd
                }
            }
            // A fresh song has nothing to lose, same as the markers above. For a known song this
            // only ever fires for a row `plan` actually raised, so an empty incoming note cannot
            // reach here and cannot erase a local one.
            if isFresh || accepted.contains("\(path)\u{1}\(DiffField.note.key)") {
                c.note = Store.clampNote(e.note)
            }
            if isFresh {
                c.tags = Store.clampTags(e.tags)
            } else if accepted.contains("\(path)\u{1}\(DiffField.tags.key)") {
                // Union, not replace — a tag this machine added must survive accepting the
                // sender's. `clampTags` caps and dedups, so the result cannot exceed the
                // per-song limit however many arrive.
                c.tags = Store.clampTags(c.tags + Handoff.tagsAdded(c.tags, e.tags))
            }
            if isFresh {
                c.configured = e.configured
                c.auto = e.auto
            }
            // Repair rather than trust, same as everywhere else a range enters the app.
            if c.introEnd <= c.introStart {
                c.introEnd = c.introStart + SongConfig.defaults.introEnd
                c.configured = false
                c.auto = true
            }
            c.base = c.current     // both sides now agree on the signed-off values
            store.set(c, for: path)
        }
        // Silent and additive, and the only thing here that is NOT gated on `accepted`: see
        // `RoundPackage.tagColors` for why a colour gets no row. It runs after the loop so a
        // tag that only arrived with this import is already in the library when its colour
        // lands — `Store.setTagColor` is unaffected by that, but `tagColors` reads `songs`, and
        // ordering it the other way would have the cache rebuilt from a library missing the tag.
        store.mergeTagColors(plan.package.tagColors)
        // The review happened, whatever its outcome. HERE and not in `AppModel.applyImport`,
        // because this is the choke point both import paths already go through — the no-choices
        // path in `openImport` and the sheet — so a third caller cannot forget it, and
        // `--incomingtest` (which drives `apply` directly) can actually see it.
        //
        // Needed because neither of the two comparisons can see a review on its own:
        // DECLINING every row leaves the local value and `base` agreeing while both still
        // differ from the sender, so `alreadyTakenIn` is false forever and the strip returned on
        // every launch — with the sheet pre-accepting the rows that had just been turned down.
        // And `SongBase` holds the five marker fields, so a handover carrying only a `note` or a
        // `tag` matched on every song and raised nothing at all. See `Store.takenIn`.
        store.markTakenIn(Handoff.reviewKey(round: plan.round, pkg: plan.package))
        store.saveNow()
    }
}
