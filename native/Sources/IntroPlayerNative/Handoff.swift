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

    struct Entry {
        var b = SongBase()
        var configured = false
        var auto = false
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
        p.by = (o["by"] as? String) ?? ""
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
            // A degenerate range disarms the intro-end guard downstream, so repair on the way in
            // rather than trusting the sender's file.
            if e.b.introEnd <= e.b.introStart {
                e.b.introEnd = e.b.introStart + SongBase().introEnd
                e.configured = false
                e.auto = true
            }
            p.songs[name] = e
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
            ss[name] = d
        }
        out["songs"] = ss
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

// MARK: - Import

/// One field the incoming package disagrees with the local file about. The comparison is
/// incoming-vs-local (not incoming-vs-base), so it is still correct when BOTH sides edited the
/// same song since the handover — the setter sees both values and picks.
struct DiffRow: Identifiable {
    let path: String
    let field: MarkerField
    let mine: String
    let theirs: String
    var id: String { "\(path)\u{1}\(field.rawValue)" }
}

/// What importing a package would do, computed before anything is written.
struct ImportPlan {
    var package: RoundPackage
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
    /// Build the package from what is on disk right now, for one round.
    static func package(round: String, paths: [String], store: Store, by: String) -> RoundPackage {
        var p = RoundPackage()
        p.round = round
        p.by = by
        p.at = LogStore.isoNow()
        for path in paths {
            let c = store.config(for: path)
            p.songs[Library.baseName(path)] =
                RoundPackage.Entry(b: c.current, configured: c.isConfigured, auto: c.auto)
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

    static func plan(_ pkg: RoundPackage, round: String, paths: [String], store: Store)
        -> ImportPlan
    {
        var plan = ImportPlan(package: pkg)
        let byName = Dictionary(paths.map { (Library.baseName($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (name, e) in pkg.songs.sorted(by: { $0.key < $1.key }) {
            guard let path = byName[name] else { plan.orphans.append(name); continue }
            guard let local = store.songs[path] else { plan.fresh.append(path); continue }
            let mine = local.current
            var diffs: [DiffRow] = []
            for f in MarkerField.allCases {
                let a = f.text(mine), b = f.text(e.b)
                if a != b {
                    diffs.append(DiffRow(path: path, field: f, mine: a, theirs: b))
                }
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
                let rowID = "\(path)\u{1}\(f.rawValue)"
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
        store.saveNow()
    }
}
