import Foundation

/// Where the app's data lives. The bundle sits inside the project folder exactly like the shell
/// launcher did, so `songs/`, `config.json` and `log.json` stay shared with the web version.
enum AppPaths {
    static var root: URL {
        var u = Bundle.main.bundleURL
        if u.pathExtension == "app" { u.deleteLastPathComponent() }
        return u
    }
    static var songs: URL { root.appendingPathComponent("songs") }
    static var se: URL { root.appendingPathComponent("se") }
    static var config: URL { root.appendingPathComponent("config.json") }
    static var log: URL { root.appendingPathComponent("log.json") }
}

/// Songs are identified end-to-end by their path relative to `songs/`. A subfolder is a playlist
/// (one taping); loose files form an unnamed round. Path keys — not filenames — keep two rounds
/// containing the same song independent, `played` included.
enum Library {
    static let rootLabel = "— ยังไม่ได้จัดรอบ —"
    /// Display name for a playlist — loose files have no folder, so they need the standing label.
    static func label(_ playlist: String) -> String { playlist.isEmpty ? rootLabel : playlist }
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "ogg", "flac", "aac"]

    static func scan() -> [String] {
        let base = AppPaths.songs
        guard let e = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            guard audioExts.contains(url.pathExtension.lowercased()) else { continue }
            let rel = url.path.hasPrefix(base.path + "/")
                ? String(url.path.dropFirst(base.path.count + 1))
                : url.lastPathComponent
            out.append(rel)
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    static func playlist(of p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "" }
        return String(p[p.startIndex..<i])
    }
    static func baseName(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: i)...])
    }
    static func title(_ p: String) -> String {
        let b = baseName(p)
        guard let dot = b.lastIndex(of: "."), dot != b.startIndex else { return b }
        return String(b[b.startIndex..<dot])
    }
    /// What the song list and the centre pane show. The raw names are YouTube filenames:
    /// `101_THE TOYS - ลาลาลอย (100%)  [Official Music Video]` measures 337pt in a 168pt column,
    /// so the 2-line clamp was TRUNCATING the part that tells two songs apart. Stripping the
    /// leading number and the trailing boilerplate moves most rows to one or two lines, which is
    /// worth more than any spacing change. The raw name stays in the row's tooltip.
    private static let boilerplate = ["official music video", "official mv", "official video",
                                      "official lyrics", "official lyric video", "official audio",
                                      "official visualizer", "visualizer", "lyric video",
                                      "music video", "official teaser", "audio", "mv"]
    static func displayTitle(_ p: String) -> String {
        var t = title(p)
        // leading track number
        if let m = t.range(of: "^[0-9]+[_\\-. ]+", options: .regularExpression) {
            t = String(t[m.upperBound...])
        }
        // trailing bracketed boilerplate, repeatedly — files often carry two
        var changed = true
        while changed {
            changed = false
            for (open, close) in [("[", "]"), ("(", ")"), ("【", "】")] {
                let s2 = t.trimmingCharacters(in: .whitespaces)
                guard s2.hasSuffix(close), let i = s2.range(of: open, options: .backwards)
                else { continue }
                let innerStart = s2.index(after: i.lowerBound)
                let innerEnd = s2.index(s2.endIndex, offsetBy: -close.count)
                guard innerStart <= innerEnd else { continue }
                let inner = String(s2[innerStart..<innerEnd])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if boilerplate.contains(inner) {
                    t = String(s2[s2.startIndex..<i.lowerBound])
                    changed = true
                }
            }
        }
        // Trailing boilerplate with no brackets at all — "… Official MV". Gated on the word
        // "official" so a real title ending in "Audio" or "MV" is never eaten.
        t = t.replacingOccurrences(
            of: "[\\s\\-|·]+official\\s*(music\\s*video|mv|video|audio|lyrics?|lyric\\s*video|visualizer|teaser)\\s*$",
            with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        let out = t.trimmingCharacters(in: CharacterSet(charactersIn: " -|·"))
        return out.isEmpty ? title(p) : out
    }

    /// The leading track number, kept out of the title so it can sit in its own tabular cell.
    /// The number is how the GM and the edit team refer to a question, so it must stay visible.
    static func trackNumber(_ p: String) -> String {
        let b = title(p)
        guard let m = b.range(of: "^[0-9]+", options: .regularExpression) else { return "" }
        return String(b[m])
    }

    static func url(_ p: String) -> URL {
        p.split(separator: "/").reduce(AppPaths.songs) { $0.appendingPathComponent(String($1)) }
    }

    /// Columns split a round by the leading digit of the filename: 1xx / 2xx / everything else.
    /// Display-only — nothing is stored per column.
    static let columnLabels = ["1xx", "2xx", "3xx + อื่นๆ"]
    static func column(of p: String) -> Int {
        switch baseName(p).first {
        case "1": return 0
        case "2": return 1
        default:  return 2
        }
    }
}

/// `--analyse` runs the maths over every song and prints it, so the port can be diffed against the
/// web version's numbers instead of being eyeballed.
enum Diagnostics {
    /// Export -> simulated on-site edit -> plan -> apply, end to end on the real library.
    /// WRITES config.json and round.json. The point is to prove three things the UI cannot show
    /// quickly: that `base` is stamped only by the handover, that an edit afterwards is detected
    /// as a diff, and that a rejected row keeps the LOCAL value while an accepted one takes the
    /// sender's.
    static func handoffTest() {
        let store = Store()
        let songs = Library.scan()
        let round = Library.playlist(of: songs.first ?? "")
        let paths = songs.filter { Library.playlist(of: $0) == round }
        guard let probe = paths.first else { print("no songs"); return }
        print("round: \(Library.label(round))  songs: \(paths.count)")

        // make sure there is something to compare against
        for p in paths where store.songs[p] == nil { store.set(SongConfig(), for: p) }

        print("\n1) export")
        guard let url = try? Handoff.export(round: round, paths: paths, store: store, by: "diag")
        else { print("  ✗ export failed"); return }
        print("   wrote \(url.lastPathComponent)")
        let after = store.config(for: probe)
        print("   base stamped: \(after.base != nil)  onsiteEdits: \(after.onsiteEdits.count) (must be 0)")
        guard after.base != nil, after.onsiteEdits.isEmpty else { print("   ✗"); return }

        print("\n2) simulate an on-site edit on \(Library.baseName(probe))")
        var edited = after
        let wasHook = edited.hook
        edited.hook = (wasHook + 7.5).rounded()
        store.set(edited, for: probe)
        let e = store.config(for: probe)
        print("   hook \(wasHook) -> \(e.hook)   flagged: \(e.onsiteEdits.map(\.rawValue))")
        guard e.onsiteEdits == [.hook] else { print("   ✗ expected exactly [hook]"); return }

        print("\n3) plan an import of the package we exported")
        guard let pkg = RoundPackage.read(url) else { print("   ✗ unreadable"); return }
        let plan = Handoff.plan(pkg, round: round, paths: paths, store: store)
        print("   rows: \(plan.rows.count)  unchanged: \(plan.unchanged.count)  fresh: \(plan.fresh.count)")
        guard plan.rows.count == 1, let row = plan.rows.first, row.field == .hook else {
            print("   ✗ expected one hook row"); return
        }
        print("   \(Library.baseName(row.path))  \(row.field.label)  mine \(row.mine) / theirs \(row.theirs)")

        print("\n4a) REJECT the row — local value must survive")
        Handoff.apply(plan, accepted: [], store: store)
        let rejected = store.config(for: probe)
        print("   hook = \(rejected.hook) (expect \(e.hook))  onsite now: \(rejected.onsiteEdits.count) (expect 0)")
        guard SongConfig.same(rejected.hook, e.hook), rejected.onsiteEdits.isEmpty else {
            print("   ✗"); return
        }

        print("\n4b) ACCEPT the row — sender's value must win")
        store.set(edited, for: probe)                    // put the edit back
        var c2 = store.config(for: probe); c2.base = after.current; store.set(c2, for: probe)
        let plan2 = Handoff.plan(pkg, round: round, paths: paths, store: store)
        Handoff.apply(plan2, accepted: Set(plan2.rows.map(\.id)), store: store)
        let accepted = store.config(for: probe)
        print("   hook = \(accepted.hook) (expect \(wasHook))  onsite now: \(accepted.onsiteEdits.count) (expect 0)")
        guard SongConfig.same(accepted.hook, wasHook), accepted.onsiteEdits.isEmpty else {
            print("   ✗"); return
        }

        print("\n✓ ผ่าน — base ถูกตีเฉพาะตอนส่งมอบ, แก้หลังส่งถูกจับได้, รับ/ไม่รับทำงานถูกทั้งคู่")
    }

    /// What the row labels will actually say. Read-only.
    static func titles() {
        for p in Library.scan() {
            print("  raw : \(Library.title(p))")
            print("  show: \(Library.displayTitle(p))")
        }
    }

    /// Prints the handover checklist the way the sheet shows it. Read-only.
    static func preflightReport() {
        let store = Store()
        let songs = Library.scan()
        for round in Set(songs.map(Library.playlist(of:))).sorted() {
            let paths = songs.filter { Library.playlist(of: $0) == round }
            print("=== \(Library.label(round))  (\(paths.count) เพลง) ===")
            var items = Preflight.fast(round: round, paths: paths, store: store)
            items += Preflight.silentIntros(paths: paths, store: store)
            if items.isEmpty { print("  ✓ ไม่พบปัญหา"); continue }
            for it in items.sorted(by: { ($0.kind.blocking ? 0 : 1, $0.detail) < ($1.kind.blocking ? 0 : 1, $1.detail) }) {
                print("  \(it.kind.blocking ? "⚠" : "△") \(it.kind.label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(it.detail)")
            }
        }
    }

    /// Renders the column peaks as text for one song at two zoom levels. Verifies the drawing
    /// maths without driving the UI — a zoomed view must show detail that full-song view averages
    /// away, and both must stay inside 0…1.
    static func columns(match: String) {
        let songs = Library.scan()
        guard let s = songs.first(where: { $0.contains(match) }) ?? songs.first,
              let a = try? Analysis.analyse(url: Library.url(s)) else { print("no song"); return }
        let store = Store()
        let c = store.config(for: s)
        print("song: \(Library.baseName(s))  dur=\(String(format: "%.1f", a.duration))  globalPeak=\(String(format: "%.3f", a.globalPeak))")

        func show(_ label: String, _ from: Double, _ to: Double) {
            let cols = a.columnPeaks(viewStart: from, viewEnd: to, width: 100)
            let lo = cols.min() ?? 0, hi = cols.max() ?? 0
            let mean = cols.reduce(0, +) / Float(max(1, cols.count))
            let bars = "▁▂▃▄▅▆▇█"
            let art = cols.map { v -> String in
                let i = min(7, max(0, Int(v * 8)))
                return String(Array(bars)[i])
            }.joined()
            print("\n\(label)  [\(String(format: "%.2f", from))–\(String(format: "%.2f", to))s]")
            print("  min=\(String(format: "%.3f", lo)) max=\(String(format: "%.3f", hi)) mean=\(String(format: "%.3f", mean))")
            print("  \(art)")
        }
        show("เต็มเพลง", 0, a.duration)
        let pad = max(0.5, (c.introEnd - c.introStart) * 0.35)
        show("ช่วง Intro", max(0, c.introStart - pad), min(a.duration, c.introEnd + pad))
        show("ซูมลึก 1 วิ", max(0, c.introStart - 0.3), max(0, c.introStart - 0.3) + 1.0)
    }

    /// The app's #1 requirement, tested headlessly and silently: playback must stop exactly on
    /// Intro End and never run into the song.
    static func playTest() {
        let songs = Library.scan()
        guard let s = songs.first else { print("no songs"); return }
        let p = Player()
        p.load(url: Library.url(s))
        p.muteForTest()
        var c = SongConfig(); c.introStart = 2; c.introEnd = 8; c.ignoreEnd = false
        p.configProvider = { c }
        print("song: \(Library.baseName(s))  introStart=\(c.introStart) introEnd=\(c.introEnd)")

        var maxSeen = 0.0
        var stopped: Double?
        p.onAutoStop = { stopped = p.position }
        p.seek(to: c.introStart, config: c)
        p.toggleStart(config: c)
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if p.position > maxSeen { maxSeen = p.position }
            if stopped != nil { break }
        }
        print(String(format: "  mode=%@ playing=%@ stoppedAt=%@ maxReached=%.3f overshoot=%.3f",
                     "\(p.mode)", p.isPlaying ? "yes" : "no",
                     stopped.map { String(format: "%.3f", $0) } ?? "—",
                     maxSeen, max(0, maxSeen - c.introEnd)))

        // ignoreEnd must still bypass the guard
        c.ignoreEnd = true
        stopped = nil
        p.seek(to: 2, config: c)
        p.toggleStart(config: c)
        let d2 = Date().addingTimeInterval(9)
        while Date() < d2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        print(String(format: "  ignoreEnd: pos=%.2f playing=%@ wentPast8=%@",
                     p.position, p.isPlaying ? "yes" : "no", p.position > 8 ? "yes" : "no"))
        p.pause()
    }

    /// The bounded hook audition (`G`). Must stop ON `hook + previewSec` with zero overshoot, the
    /// same structural guarantee `--playtest` proves for the intro — and must leave the player in a
    /// state where the ordinary intro stop still arms. Read-only.
    static func previewTest() {
        let songs = Library.scan()
        guard let s = songs.first else { print("no songs"); return }
        let p = Player()
        p.load(url: Library.url(s))
        p.muteForTest()
        var c = SongConfig(); c.introStart = 2; c.introEnd = 8; c.hook = 20
        p.configProvider = { c }
        let want = min(p.duration, c.hook + Player.previewSec)
        print(String(format: "song: %@  dur=%.2f  hook=%.2f  previewSec=%.1f  expect stop at %.2f",
                     Library.baseName(s), p.duration, c.hook, Player.previewSec, want))
        guard p.duration > want + 1 else { print("  — song too short to test"); return }

        var maxSeen = 0.0
        var stopped: Double?
        p.onAutoStop = { stopped = p.position }
        p.previewHook(config: c)
        print("  mode after previewHook: \(p.mode)  (must be preview)")
        let deadline = Date().addingTimeInterval(Player.previewSec + 6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if p.position > maxSeen { maxSeen = p.position }
            if stopped != nil { break }
        }
        let overshoot = max(0, maxSeen - want)
        print(String(format: "  stoppedAt=%@ maxReached=%.3f overshoot=%.3f  playing=%@ mode=%@",
                     stopped.map { String(format: "%.3f", $0) } ?? "— NEVER STOPPED",
                     maxSeen, overshoot, p.isPlaying ? "yes" : "no", "\(p.mode)"))
        let okPreview = stopped != nil && overshoot < 0.02 && !p.isPlaying

        // The intro stop must still work right after a preview — the preview bound is set on the
        // same scheduling path, so a leaked previewEnd would cut the next intro short.
        stopped = nil; maxSeen = 0
        p.seek(to: c.introStart, config: c)
        p.toggleStart(config: c)
        print("  mode after Space from introStart: \(p.mode)  (must be intro)")
        let d2 = Date().addingTimeInterval(10)
        while Date() < d2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if p.position > maxSeen { maxSeen = p.position }
            if stopped != nil { break }
        }
        let introOvershoot = max(0, maxSeen - c.introEnd)
        print(String(format: "  intro afterwards: stoppedAt=%@ overshoot=%.3f",
                     stopped.map { String(format: "%.3f", $0) } ?? "— NEVER STOPPED",
                     introOvershoot))
        let okIntro = stopped != nil && introOvershoot < 0.02
        p.pause()
        print(okPreview && okIntro ? "\n✓ ผ่าน" : "\n✗ ไม่ผ่าน")
    }

    /// Marker edits DURING playback — `Player.remode`, which had no coverage at all.
    ///
    /// The case that matters: pulling Intro End back behind the playhead used to flip the mode to
    /// `.free`, which skipped the intro bound, left `want` at the file length and passed the
    /// "moved outward" test against the OLD boundary — so the node was rescheduled to the end of
    /// the file and the whole song played out. Shortening the intro made playback longer.
    /// Read-only (local Player, local config).
    static func remodeTest() {
        let songs = Library.scan()
        guard let s = songs.first else { print("no songs"); return }
        let p = Player()
        p.load(url: Library.url(s))
        p.muteForTest()
        guard p.duration > 40 else { print("✗ song too short to test (need > 40s)"); return }
        print(String(format: "song: %@  dur=%.2f", Library.baseName(s), p.duration))
        var ok = true

        func run(_ title: String, introEnd0: Double, editTo: Double, at trigger: Double,
                 mustStopBy: Double) {
            var c = SongConfig(); c.introStart = 2; c.introEnd = introEnd0; c.ignoreEnd = false
            p.configProvider = { c }
            var stopped: Double?
            var maxSeen = 0.0
            var edited = false
            p.onAutoStop = { stopped = p.position }
            p.seek(to: c.introStart, config: c)
            p.mode == .idle ? () : ()
            p.toggleStart(config: c)
            let deadline = Date().addingTimeInterval(mustStopBy + 8)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if p.position > maxSeen { maxSeen = p.position }
                if !edited, p.position >= trigger {
                    edited = true
                    c.introEnd = editTo              // the marker edit, mid-playback
                    p.remode(config: c)
                }
                if stopped != nil { break }
            }
            let good = stopped != nil && maxSeen <= mustStopBy + 0.15
            if !good { ok = false }
            print(String(format: "  %@", title))
            print(String(format: "     edited introEnd %.2f -> %.2f at ~%.2fs", introEnd0, editTo, trigger))
            print(String(format: "     stoppedAt=%@ maxReached=%.3f  must be <= %.2f  %@",
                         stopped.map { String(format: "%.3f", $0) } ?? "— NEVER STOPPED",
                         maxSeen, mustStopBy, good ? "ok" : "✗ FAIL"))
            print(String(format: "     mode=%@ playing=%@", "\(p.mode)", p.isPlaying ? "yes" : "no"))
            p.pause()
        }

        // 1) the dangerous one: pull Intro End BEHIND the playhead.
        //    Must stop at once. Before the fix this ran to the end of the file.
        run("pull Intro End behind the playhead", introEnd0: 20, editTo: 3, at: 5, mustStopBy: 5.6)

        // 2) the legitimate one: push Intro End OUT mid-intro. Must re-arm at the NEW boundary,
        //    which is the whole reason remode exists — so fix 1 must not have broken it.
        run("push Intro End outward", introEnd0: 6, editTo: 12, at: 3, mustStopBy: 12.0)

        // 3) tighten but stay AHEAD of the playhead. Must stop at the new, earlier boundary.
        run("tighten Intro End, still ahead", introEnd0: 20, editTo: 8, at: 4, mustStopBy: 8.0)

        print(ok ? "\n✓ ผ่าน — แก้ marker ตอนเล่นอยู่ ไม่ทำให้เล่นเลย Intro End"
                 : "\n✗ ไม่ผ่าน — มีกรณีที่เล่นเลย Intro End")
    }

    /// The typed marker field's parser. Read-only, no audio.
    static func timeFmt() {
        print("round-trip  fmtClock -> parseClock")
        var ok = true
        for v in [0.0, 0.01, 0.99, 1.0, 14.2, 59.99, 60.0, 83.45, 123.07, 599.99, 3599.99, 3600.0] {
            let txt = fmtClock(v)
            let back = parseClock(txt)
            let good = back.map { abs($0 - v) < 0.005 } ?? false
            if !good { ok = false }
            print(String(format: "  %8.2f -> %-12@ -> %@  %@", v, txt as NSString,
                         back.map { String(format: "%.2f", $0) } ?? "nil",
                         good ? "ok" : "✗ MISMATCH"))
        }
        print("\naccept")
        for t in ["83.45", "1:23.45", "1:23", "0:00", "12", "0.5", " 14.2 "] {
            let r = parseClock(t)
            if r == nil { ok = false }
            print("  \(t.debugDescription) -> \(r.map { String(format: "%.2f", $0) } ?? "nil ✗ SHOULD PARSE")")
        }
        print("\nreject — a typo must leave the marker alone, never move it to 0")
        for t in ["", "abc", "1:75", "-5", "1:2:3", ":", "1:", "12s", "1,5"] {
            let r = parseClock(t)
            if r != nil { ok = false }
            print("  \(t.debugDescription) -> \(r.map { String(format: "%.2f ✗ SHOULD REJECT", $0) } ?? "nil ok")")
        }
        print(ok ? "\n✓ ผ่าน" : "\n✗ ไม่ผ่าน")
    }

    /// The overview strip's peaks. Two things to prove: it agrees with the zoomed-out column peaks,
    /// and interleaving the two does NOT evict either cache — sharing one would re-walk the whole
    /// envelope twice per frame, which is the exact cost the column cache exists to avoid.
    static func overviewTest() {
        let songs = Library.scan()
        guard let s = songs.first, let a = try? Analysis.analyse(url: Library.url(s)) else {
            print("no songs / decode failed"); return
        }
        let w = 1400
        print(String(format: "song: %@  dur=%.2f  width=%d", Library.baseName(s), a.duration, w))

        let ov = a.overviewPeaks(width: w)
        let full = a.columnPeaks(viewStart: 0, viewEnd: a.duration, width: w)
        var maxDiff: Float = 0
        for i in 0..<min(ov.count, full.count) { maxDiff = max(maxDiff, abs(ov[i] - full[i])) }
        print(String(format: "  agreement with full-song columnPeaks: maxDiff=%.4f  (bucket rounding only)",
                     maxDiff))

        func time(_ body: () -> Void) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent(); body(); return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        // `w + 1` is a width neither cache holds, so this is the true recompute cost.
        let cold = time { _ = a.overviewPeaks(width: w + 1) }
        let cached = time { _ = a.overviewPeaks(width: w + 1) }
        // Now one frame of the real app, in order: the zoomed waveform, then the strip. If they
        // shared a cache each would evict the other and both numbers below would read `cold`.
        _ = a.overviewPeaks(width: w)
        _ = a.columnPeaks(viewStart: 10, viewEnd: 25, width: w)
        let stripAfterZoom = time { _ = a.overviewPeaks(width: w) }
        let zoomAfterStrip = time { _ = a.columnPeaks(viewStart: 10, viewEnd: 25, width: w) }
        print(String(format: "  recompute=%.3f ms   same width again=%.3f ms", cold, cached))
        print(String(format: "  strip after a zoomed columnPeaks = %.3f ms  (must stay cached)", stripAfterZoom))
        print(String(format: "  zoomed columnPeaks after the strip = %.3f ms  (must stay cached)", zoomAfterStrip))
        let ok = maxDiff < 0.0001 && stripAfterZoom < cold / 4 && zoomAfterStrip < cold / 4
        print(ok ? "\n✓ ผ่าน — ข้อมูลตรงกัน และไม่กวนแคชกันเอง"
                 : "\n✗ ไม่ผ่าน" + (maxDiff >= 0.0001 ? " — ข้อมูลไม่ตรงกัน" : " — แคชตีกัน"))
    }

    /// Does "รีเซ็ตเล่นแล้ว" actually clear the badges? Tests the model logic without the UI.
    static func resetTest() {
        let log = LogStore()
        print("log events: \(log.events.count)")
        for e in log.events {
            print("  raw t=\(e.t)  parsed=\(e.date.map { "\($0)" } ?? "*** PARSE FAILED ***")")
        }
        let now = LogStore.isoNow()
        print("isoNow() = \(now)  parsed=\(LogStore.isoParse(now).map { "\($0)" } ?? "*** PARSE FAILED ***")")

        // simulate the comparison resetPlayed relies on
        if let e = log.events.first, let d = e.date, let n = LogStore.isoParse(now) {
            print("event > resetAt ? \(d > n)   (ต้องเป็น false = เป็นของรอบก่อน)")
        }
        let store = Store()
        print("resetAt in config: \(store.resetAt)")
    }

    /// Runs the real AppModel.resetPlayed end to end. Writes to the real files — the caller backs
    /// them up first.
    @MainActor static func resetFlow() {
        let m = AppModel()
        guard let song = m.songsIn(m.currentPlaylist).first else { print("no songs"); return }
        print("playlist=\(m.currentPlaylist)  song=\(Library.baseName(song))")

        m.current = song
        m.updateConfigQuiet { $0.played = true }
        m.logStore.append(playlist: Library.playlist(of: song), path: song, event: "wrong")

        let before = (played: m.store.config(for: song).played, status: m.status(of: song))
        print("ก่อน : played=\(before.played) status=\(before.status.map { "\($0)" } ?? "nil")")

        let msg = m.resetPlayed()
        m.store.saveNow()

        let after = (played: m.store.config(for: song).played, status: m.status(of: song))
        print("หลัง : played=\(after.played) status=\(after.status.map { "\($0)" } ?? "nil")")
        print("ข้อความ: \(msg)")
        print("resetAt: \(m.store.resetAt)")
        print("log ยังอยู่: \(m.logStore.events.count) events")
        let ok = !after.played && after.status == nil && m.store.resetAt[m.currentPlaylist] != nil
                 && m.logStore.events.count > 0
        print(ok ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

    /// Does a folder added while the app is running show up after rescan()?
    @MainActor static func rescanTest() {
        let m = AppModel()
        print("ตอนเปิด  : playlists=\(m.playlists.map { $0.isEmpty ? "(root)" : $0 })")
        print("           เลือกอยู่=\(m.currentPlaylist)  เพลงในรอบนี้=\(m.songsIn(m.currentPlaylist).count)")

        let newDir = AppPaths.songs.appendingPathComponent("__t_rescan")
        try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: AppPaths.se.appendingPathComponent("correct.mp3"),
                                          to: newDir.appendingPathComponent("501_ใหม่.mp3"))
        print("เพิ่มโฟลเดอร์ __t_rescan ลงดิสก์แล้ว (ยังไม่ rescan)")
        print("           แอปยังเห็น=\(m.playlists.count) รอบ  ← ยังไม่รู้ ถูกต้อง")

        m.rescan()
        print("หลัง rescan: playlists=\(m.playlists.map { $0.isEmpty ? "(root)" : $0 })")
        print("           toast=\(m.toast ?? "—")")
        let ok = m.playlists.contains("__t_rescan")
        print(ok ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
        try? FileManager.default.removeItem(at: newDir)
    }

    static func analyseAll() {
        let store = Store()
        let songs = Library.scan()
        print("songs=\(songs.count) scope=\(store.loudnessScope.rawValue)")
        print(String(format: "%-30@ %8@ %8@ %10@ %10@", "song" as NSString, "dur" as NSString,
                     "detect" as NSString, "rmsWhole" as NSString, "rmsIntro" as NSString))
        for s in songs {
            let a: Analysis
            do { a = try Analysis.analyse(url: Library.url(s)) }
            catch { print("\(Library.baseName(s))  FAILED: \(error)"); continue }
            let c = store.config(for: s)
            let det = a.detectIntroStart()
            let whole = a.rms(0, a.duration)
            let intro = a.rms(min(c.introStart, c.introEnd), max(c.introStart, c.introEnd))
            let name = String(Library.baseName(s).prefix(28))
            print(String(format: "%-30@ %8.2f %8@ %10.4f %10.4f",
                         name as NSString, a.duration,
                         (det.map { String(format: "%.2f", $0) } ?? "—") as NSString,
                         whole, intro))
        }
    }
}
