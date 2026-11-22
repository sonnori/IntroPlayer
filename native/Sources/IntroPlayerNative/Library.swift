import Foundation
import AppKit
import ImageIO

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
    static var brand: URL { root.appendingPathComponent("brand") }
}

/// The programme's logo, drawn in the header bar before the app name.
///
/// **It lives beside the app, not inside the bundle** — `brand/logo.png`, in the installer's
/// `SEED[]` next to `se/`. That is the same category as the two stings: it belongs to the
/// production rather than to this program, it changes on the production's schedule and not on
/// ours, and this repo is public. Baking it into `Resources/` would mean a rebuild and a
/// release every time the branding moves, and it would put the show's artwork in git.
/// `SEED[]` semantics are exactly right: copied on a fresh install, **never overwritten by an
/// update**, so a crew machine cannot lose its logo to a version bump.
///
/// Loaded **once per process** via a lazy `static let`. `ContentView` is re-initialised on
/// every model publish (§6c) and the header re-renders at the player's tick rate, so anything
/// that touched the disk from `body` would `stat` 50 times a second — §8f's memoised-cover
/// lesson, including the memo for "looked, not there". The cost is that swapping the file needs
/// a relaunch, which `brand/README.txt` says.
enum ShowLogo {
    /// Fits inside the header's existing line box, so adding a logo does NOT make the bar
    /// taller. That matters: `CenterView`'s only flexible child is the waveform and it has a
    /// hard `minHeight: 160` floor, so every point the header grows comes off content that has
    /// nowhere to go — §15's news-strip note, where the overflow clips the song title off the
    /// top and ✓ Correct / ✗ Wrong off the bottom with no scroller.
    static let height: CGFloat = 22
    /// Beyond this the logo starts crowding the chips and buttons at the 1900 px breakpoint.
    static let maxWidth: CGFloat = 90
    /// A 10000x10000 PNG is ~400 MB once decoded. The dimensions are read from the file's
    /// header BEFORE decoding, so an absurd file costs nothing.
    private static let maxPixels = 4096

    static let image: NSImage? = load()

    private static func load() -> NSImage? {
        let u = brandFile
        guard let d = try? Data(contentsOf: u), !d.isEmpty,
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxPixels, h <= maxPixels,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let art = trimmed(cg) ?? cg
        return NSImage(cgImage: art, size: NSSize(width: art.width, height: art.height))
    }

    /// Crop away fully transparent margins.
    ///
    /// **A designer's logo export is almost always padded**, and the padding is not decoration
    /// to us — it is height. The real file here is a 1024x1024 PNG whose artwork occupies
    /// 1024x508, i.e. half the canvas is empty. Drawn as-is inside a 22 pt box that gives a
    /// logo **10.9 pt tall** next to 15 pt text, sitting in a 22 pt square that wastes the 90 pt
    /// width it was allowed. Trimmed, the same file is 2.02:1 and draws 44 x 22 — full height,
    /// correct proportion, no re-export asked of anyone.
    ///
    /// Alpha > 8 rather than > 0: a PNG exported from a vector tool carries a fringe of
    /// near-zero alpha around the artwork from antialiasing, and testing for nonzero would
    /// "find" artwork in it and trim nothing.
    private static func trimmed(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where px[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        // Entirely transparent: there is no logo in this file, and returning the uncropped
        // image would draw 22 pt of nothing while reserving the space.
        guard maxX >= minX, maxY >= minY else { return nil }
        if minX == 0 && minY == 0 && maxX == w - 1 && maxY == h - 1 { return cg }
        return cg.cropping(to: CGRect(x: minX, y: minY,
                                      width: maxX - minX + 1, height: maxY - minY + 1))
    }

    static var brandFile: URL { AppPaths.brand.appendingPathComponent("logo.png") }

    /// Width to draw at, from the image's own aspect ratio. Returning an exact size rather than
    /// handing SwiftUI a `maxWidth` box keeps a narrow logo from reserving 90 pt of header it
    /// does not use, and a wide one from letterboxing inside it.
    static func drawSize(_ img: NSImage) -> CGSize {
        let w = min(maxWidth, height * img.size.width / max(1, img.size.height))
        return CGSize(width: max(1, w), height: height)
    }
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

    /// The waveform's two-stage marker rule. Read-only, and pure — `MarkerGrab.decide` exists as
    /// a free function precisely so this can prove it without driving a SwiftUI gesture.
    static func grabTest() {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: MarkerGrab.Outcome, _ want: MarkerGrab.Outcome) {
            let ok = got == want
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok " : "✗  ")\(name)")
            if !ok { print("        got \(got)  want \(want)") }
        }
        let layout: [(field: MarkerField, x: CGFloat)] =
            [(.introStart, 100), (.introEnd, 300), (.hook, 700)]

        print("1) ต้องกดให้ active ก่อน แล้วค่อยลากได้")
        check("กดบน Intro End ตอน Intro Start active → แค่เลือก",
              MarkerGrab.decide(pressX: 300, positions: layout, active: .introStart),
              .activate(.introEnd))
        check("กดบน Intro End ตอนมัน active อยู่แล้ว → ลากได้",
              MarkerGrab.decide(pressX: 300, positions: layout, active: .introEnd),
              .drag(.introEnd))
        check("กดห่างจากทุก marker → pan/seek ตามเดิม",
              MarkerGrab.decide(pressX: 500, positions: layout, active: .introEnd),
              .away)

        print("\n2) ขอบเขต 8pt")
        check("ห่าง 8pt พอดี → ยังจับได้",
              MarkerGrab.decide(pressX: 308, positions: layout, active: .introEnd),
              .drag(.introEnd))
        check("ห่าง 9pt → ไม่จับ",
              MarkerGrab.decide(pressX: 309, positions: layout, active: .introEnd),
              .away)

        print("\n3) marker ทับกัน — เพลง 102 มี introStart == introEnd จริงใน config.json")
        let stacked: [(field: MarkerField, x: CGFloat)] =
            [(.introStart, 420), (.introEnd, 420), (.hook, 900)]
        // `<=` on the tie-break is what makes the LATER marker win a tie. With `<` the first one
        // always won and Intro End could never be grabbed at all.
        check("ทับกันเป๊ะ → ตัวหลัง (Intro End) ชนะ",
              MarkerGrab.decide(pressX: 420, positions: stacked, active: .introEnd),
              .drag(.introEnd))
        check("ทับกันเป๊ะ ตอน Intro End ยัง active → เลือก Intro End",
              MarkerGrab.decide(pressX: 420, positions: stacked, active: .hook),
              .activate(.introEnd))
        // The blind spot the two-stage rule created: with `<=` alone the LATER marker always
        // wins a tie, so a press while Intro Start was active returned `.activate(.introEnd)`
        // — moving focus OFF Intro Start — and no sequence of gestures could ever drag it.
        // `M` did not help: the next press moved focus off again.
        check("ทับกันเป๊ะ ตอน Intro Start active → ต้องลาก Intro Start ได้",
              MarkerGrab.decide(pressX: 420, positions: stacked, active: .introStart),
              .drag(.introStart))
        check("ทับกันเป๊ะ เยื้อง 3pt ตอน Intro Start active → ยังลาก Intro Start ได้",
              MarkerGrab.decide(pressX: 423, positions: stacked, active: .introStart),
              .drag(.introStart))

        print("\n4) ตัวที่ใกล้ที่สุดชนะ ไม่ใช่ตัวแรกที่เจอ")
        let near: [(field: MarkerField, x: CGFloat)] =
            [(.introStart, 200), (.introEnd, 205), (.hook, 900)]
        check("กดที่ 201 → Intro Start ใกล้กว่า",
              MarkerGrab.decide(pressX: 201, positions: near, active: .introStart),
              .drag(.introStart))
        check("กดที่ 204 → Intro End ใกล้กว่า",
              MarkerGrab.decide(pressX: 204, positions: near, active: .introStart),
              .activate(.introEnd))

        print("\n5) ไม่มี marker เลย (ยังไม่เลือกเพลง)")
        check("ไม่มีอะไรให้จับ", MarkerGrab.decide(pressX: 100, positions: [], active: .introStart),
              .away)

        print("\nผ่าน \(pass)  ตก \(fail)")
        print(fail == 0 ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

    /// Reveal is UNBOUNDED by design — it is the on-camera verb and must never stop itself. The
    /// thing that has to hold afterwards is that the intro guard RE-ARMS: §10 records a shipped
    /// bug where `mode` stayed `.reveal`, so the next Space played straight past Intro End and
    /// looked exactly like "Ignore Intro End" was ticked when it was not.
    ///
    /// This replaced `--previewtest` when the bounded hook audition (`G`) was removed. The
    /// audition's own assertions went with it; this half had no other coverage. Read-only.
    static func revealTest() {
        let songs = Library.scan()
        guard let s = songs.first else { print("no songs"); return }
        let p = Player()
        p.load(url: Library.url(s))
        p.muteForTest()
        var c = SongConfig(); c.introStart = 2; c.introEnd = 8; c.hook = 20
        p.configProvider = { c }
        print(String(format: "song: %@  dur=%.2f  intro=%.2f-%.2f  hook=%.2f",
                     Library.baseName(s), p.duration, c.introStart, c.introEnd, c.hook))
        guard p.duration > c.hook + 4 else { print("  — song too short to test"); return }

        // 1) Reveal must play on. If anything stops it inside 3 s the on-camera reveal is broken.
        var stopped: Double?
        p.onAutoStop = { stopped = p.position }
        p.reveal(config: c)
        print("  mode after reveal: \(p.mode)  (must be reveal)")
        let d1 = Date().addingTimeInterval(3)
        while Date() < d1 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let keptGoing = stopped == nil && p.isPlaying && p.position > c.hook
        print(String(format: "  after 3s: pos=%.2f playing=%@ autoStop=%@  %@",
                     p.position, p.isPlaying ? "yes" : "no",
                     stopped == nil ? "no" : "YES", keptGoing ? "ok" : "✗ Reveal หยุดเอง"))
        p.pause()

        // 2) …and the intro guard must re-arm on the next deliberate Space from inside the range.
        stopped = nil
        var maxSeen = 0.0
        p.seek(to: c.introStart, config: c)
        p.toggleStart(config: c)
        print("  mode after Space from introStart: \(p.mode)  (must be intro)")
        let d2 = Date().addingTimeInterval(10)
        while Date() < d2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if p.position > maxSeen { maxSeen = p.position }
            if stopped != nil { break }
        }
        let overshoot = max(0, maxSeen - c.introEnd)
        print(String(format: "  intro afterwards: stoppedAt=%@ overshoot=%.3f",
                     stopped.map { String(format: "%.3f", $0) } ?? "— NEVER STOPPED", overshoot))
        let okIntro = stopped != nil && overshoot < 0.02
        p.pause()
        print(keptGoing && okIntro ? "\n✓ ผ่าน" : "\n✗ ไม่ผ่าน")
    }

    /// The running order built from the REAL log. Read-only — opens a LogStore and a Store but
    /// writes neither. This is the one check that the take grouping matches what actually
    /// happened on set, including a song that was revisited later.
    static func takesReport() {
        takesSelfCheck()
        let log = LogStore()
        print("log events: \(log.events.count)")
        guard !log.events.isEmpty else { print("— log ว่าง, ไม่มีอะไรจัดลำดับ"); return }

        let store = Store()
        var rounds: [String] = []
        for e in log.events where !rounds.contains(e.playlist) { rounds.append(e.playlist) }

        for r in rounds {
            let evs = log.events.filter { $0.playlist == r }
            let since = store.resetAt[r].flatMap { LogStore.isoParse($0) }
            let current = evs.filter { e in
                guard let s = since else { return true }
                guard let d = e.date else { return false }
                return d > s
            }
            let past = evs.count - current.count
            let tk = Takes.build(current)
            print("\n=== รอบ \(Library.label(r)) — \(evs.count) events, "
                  + "\(tk.count) ข้อในรอบถ่ายนี้" + (past > 0 ? ", \(past) events ของรอบก่อน" : "") + " ===")
            if let sp = Takes.span(tk) {
                print(String(format: "    %@  %@ -> %@  (%@)", LogStore.dayText(sp.first),
                             LogStore.hmText(sp.first), LogStore.hmText(sp.last),
                             fmtSpanThai(sp.last.timeIntervalSince(sp.first))))
            }
            let groups = Takes.sittings(tk)
            if groups.count > 1 {
                print("    แยกเป็น \(groups.count) ช่วงถ่าย (ห่างกันเกิน "
                      + "\(Int(Takes.sittingGap / 3600)) ชม)")
            }
            for (gi, g) in groups.enumerated() {
                if groups.count > 1, let d = g.first?.start {
                    print("  [ ช่วง \(gi + 1): \(LogStore.dayText(d)) \(LogStore.hmText(d)) "
                          + "— \(g.count) ข้อ ]")
                }
                let first = g.first?.start
                for x in g {
                    let el = (x.start != nil && first != nil)
                        ? fmtElapsed(x.start!.timeIntervalSince(first!)) : "—"
                    print(String(format: "  %3d. %@ %-9@ %-3@ %@  %@%@",
                                 x.order, LogStore.clockText(x.startISO), el as NSString,
                                 Library.trackNumber(x.path) as NSString,
                                 x.correct ? "✓" : "✗",
                                 Library.displayTitle(x.path),
                                 x.wrongs > 0 ? "  (ผิด \(x.wrongs))" : ""))
                }
            }
            // The thing path-grouping used to hide.
            var seen: [String: Int] = [:]
            for x in tk { seen[x.path, default: 0] += 1 }
            let repeats = seen.filter { $0.value > 1 }
            if repeats.isEmpty {
                print("    ไม่มีเพลงที่เปิดซ้ำหลายข้อ")
            } else {
                for (p, n) in repeats {
                    let where_ = tk.filter { $0.path == p }.map { "\($0.order)" }.joined(separator: ", ")
                    print("    ⚠ เปิดซ้ำ \(n) ครั้ง (ข้อ \(where_)): \(Library.displayTitle(p))")
                }
            }
        }
    }

    /// Synthetic check of the take model, because the real log happens not to contain the case
    /// that matters most: a song revisited later in the taping. Path-grouping folded that back
    /// into the song's first appearance, which is exactly the ordering the log exists to record.
    static func takesSelfCheck() {
        func ev(_ path: String, _ kind: String, _ min: Int) -> LogEvent {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let d = base.addingTimeInterval(Double(min) * 60)
            return LogEvent(t: LogStore.isoFmtForTest(d), playlist: "T", path: path,
                            event: kind, dup: 0, date: d)
        }
        // A: wrong, wrong, correct   B: wrong only (burned)   A again much later (retake)
        // C: correct                 — and a 6-hour gap before the retake, i.e. a new sitting.
        let evs = [
            ev("A.mp3", "wrong", 0), ev("A.mp3", "wrong", 1), ev("A.mp3", "correct", 2),
            ev("B.mp3", "wrong", 5),
            ev("C.mp3", "correct", 9),
            ev("A.mp3", "correct", 9 + 6 * 60),
        ]
        let tk = Takes.build(evs)
        var ok = true
        func check(_ label: String, _ got: String, _ want: String) {
            let good = got == want
            if !good { ok = false }
            print("    \(good ? "ok " : "✗  ")\(label): got \(got)  want \(want)")
        }
        print("self-check — take model")
        check("จำนวนข้อ", "\(tk.count)", "4")
        check("ลำดับ", tk.map { "\(Library.baseName($0.path))" }.joined(separator: ","),
              "A.mp3,B.mp3,C.mp3,A.mp3")
        check("A ข้อแรก: ผิดก่อน", "\(tk.first?.wrongs ?? -1)", "2")
        check("A ข้อแรก: ตอบถูก", "\(tk.first?.correct ?? false)", "true")
        check("B: เผาแล้ว (ไม่มีคนตอบ)", "\(tk.count > 1 ? !tk[1].correct : false)", "true")
        check("A เปิดซ้ำเป็นข้อที่", "\(tk.last?.order ?? -1)", "4")
        let groups = Takes.sittings(tk)
        check("จำนวนช่วงถ่าย (เว้น 6 ชม)", "\(groups.count)", "2")
        check("ช่วงที่ 2 มีกี่ข้อ", "\(groups.last?.count ?? -1)", "1")
        print(ok ? "    ✓ ผ่าน\n" : "    ✗ ไม่ผ่าน\n")
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
    /// The version comparator and the configured feed.
    ///
    /// The comparator earns a test on one case alone: a string compare puts `"1.10.0"` BELOW
    /// `"1.9.0"`, which would silently hide every release after the ninth — a bug that only
    /// appears months after it is written, on the machine of whoever is furthest behind.
    static func updateCheck() {
        print("this build: \(AppVersion.full)")
        print("schema written by this build: \(Store.schema)")
        print("\ncompare — expected vs actual")
        var ok = true
        let cases: [(String, String, Int)] = [
            ("1.0.0", "1.0.0", 0),
            ("1.0.1", "1.0.0", 1),
            ("1.0.0", "1.0.1", -1),
            ("1.10.0", "1.9.0", 1),       // the whole reason this is numeric
            ("1.9.0", "1.10.0", -1),
            ("2.0.0", "1.99.99", 1),
            ("1.1", "1.1.0", 0),          // missing components count as 0
            ("1.1.1", "1.1", 1),
            ("1.2.0-beta", "1.2.0", 0),   // suffixes compare on leading digits
            ("", "1.0.0", -1),            // a garbled manifest must read as NOT newer
            ("junk", "1.0.0", -1),
        ]
        for (a, b, want) in cases {
            let got = AppVersion.compare(a, b)
            if got != want { ok = false }
            print("  \(a.debugDescription) vs \(b.debugDescription) -> \(got) want \(want) \(got == want ? "ok" : "✗")")
        }

        print("\nfeed resolution")
        for f in ["", "https://example.com/rgf/", "https://example.com/rgf/manifest.json",
                  "/tmp/rgf-feed", "~/Drive/rgf", "ftp://nope/x", "javascript:alert(1)", "   "] {
            let loc = Updater.manifestLocation(f)
            print("  \(f.debugDescription) -> \(loc.map { $0.isFileURL ? $0.path : $0.absoluteString } ?? "nil (ปิด/ใช้ไม่ได้)")")
        }

        print("\nGitHub shorthand — the key case is that a path pasted WITHOUT its leading")
        print("slash must not parse as somebody else's repo")
        let ghCases: [(String, String?)] = [
            ("sonnori/IntroPlayer", "sonnori/IntroPlayer"),
            ("github.com/sonnori/IntroPlayer", "sonnori/IntroPlayer"),
            ("https://github.com/sonnori/IntroPlayer", "sonnori/IntroPlayer"),
            ("https://github.com/sonnori/IntroPlayer/releases", "sonnori/IntroPlayer"),
            ("https://github.com/sonnori/IntroPlayer/releases/latest", "sonnori/IntroPlayer"),
            ("https://www.github.com/sonnori/IntroPlayer.git", "sonnori/IntroPlayer"),
            ("  sonnori/IntroPlayer  ", "sonnori/IntroPlayer"),
            // must NOT be read as a repo
            ("Users/someone/Library/CloudStorage/Drive/RGF", nil),
            ("/Users/someone/Drive/RGF", nil),
            ("~/Drive/RGF", nil),
            ("https://example.com/rgf/manifest.json", nil),
            ("example.com/a/b", nil),
            ("sonnori", nil),
            ("", nil),
            ("ftp://github.com/a/b", nil),
            ("a/b c", nil),
        ]
        for (inp, want) in ghCases {
            let got = Updater.githubRepo(inp).map { "\($0.owner)/\($0.repo)" }
            if got != want { ok = false }
            print("  \(inp.debugDescription) -> \(got ?? "nil")  want \(want ?? "nil") \(got == want ? "ok" : "✗")")
        }
        print("\nfeedKind")
        for f in ["sonnori/IntroPlayer", "/tmp/rgf", "https://example.com/rgf/", ""] {
            print("  \(f.debugDescription) -> \(Updater.feedKind(f)?.describe ?? "nil (ปิด)")")
        }
        // Only http/https/file may ever reach NSWorkspace — a manifest must not be able to make
        // the app launch something.
        // The bare-PATH form matters as much as the scheme form: that branch had no guard at
        // all, so an .app path was openable. A list that only tested `file://` read as proof of
        // something it was not checking.
        for d in ["javascript:alert(1)", "ftp://x/y", "file:///etc/passwd", "mailto:a@b.c",
                  "/Applications/Calculator.app", "~/Desktop/anything.app",
                  "/tmp/payload.sh", "/tmp/release"] {
            let u = UpdateInfo(version: "9.9.9", notes: "", download: d, minMacOS: "").openable
            if u != nil { ok = false }
            print("  download \(d.debugDescription) -> \(u == nil ? "blocked ok" : "✗ OPENABLE")")
        }

        // Hoisted out of the Task: reading it inside captured a non-Sendable Store across a
        // concurrency boundary, which is an error under Swift 6.
        let feed = Store().updateFeed
        print("\nconfigured feed: \(feed.isEmpty ? "— (ปิดอยู่)" : feed)")
        if !feed.isEmpty {
            let sem = DispatchSemaphore(value: 0)
            Task {
                do {
                    if let info = try await Updater.check(feed: feed) {
                        print("  → มีเวอร์ชั่นใหม่ \(info.version)  download=\(info.download)")
                        print("     ใช้กับเครื่องนี้ได้: \(info.needsNewerOS ? "ไม่ได้ — ต้อง macOS \(info.minMacOS)" : "ได้")")
                    } else {
                        print("  → ใช้เวอร์ชั่นล่าสุดอยู่แล้ว")
                    }
                } catch {
                    print("  → เช็กไม่ได้: \(error.localizedDescription)")
                }
                sem.signal()
            }
            // A stall used to print "✓ ผ่าน" with no feed line at all, so a hung feed read as a
            // clean pass. Say so instead.
            if sem.wait(timeout: .now() + Updater.timeout + 3) == .timedOut {
                print("  → ✗ ค้าง ไม่ตอบในเวลา — ถือว่าไม่ผ่าน")
                ok = false
            }
        }
        print("\nmacOS ของเครื่องนี้: \(UpdateInfo.runningOS)")
        print(ok ? "\n✓ ผ่าน" : "\n✗ ไม่ผ่าน")
    }

    /// The whole in-app update chain except the final swap: fetch the manifest, download (or
    /// copy) the zip, unpack it, and prove the app inside reports the version the manifest
    /// promised. The swap itself is covered by `installer-test.sh`, which can test it without
    /// quitting anything.
    ///
    /// Read-only with respect to the project: everything lands in a temp dir and is deleted.
    /// Point `_settings.updateFeed` at a folder holding a real `manifest.json` + zip to run it.
    static func updateStage() {
        print("this build: \(AppVersion.full)")
        print("macOS:      \(UpdateInfo.runningOS)")
        let feed = Store().updateFeed
        guard !feed.isEmpty else {
            print("\nยังไม่ได้ตั้ง _settings.updateFeed — ไม่มีอะไรให้ทดสอบ")
            print("ตั้งเป็น path ของโฟลเดอร์ที่มี manifest.json + zip แล้วรันอีกครั้ง")
            return
        }
        print("feed:       \(feed)")
        var ok = true
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                guard let info = try await Updater.check(feed: feed) else {
                    print("\n→ ไม่มีเวอร์ชั่นใหม่กว่า \(AppVersion.short) — ไม่มีอะไรให้ stage")
                    print("   (ถ้าจะทดสอบ ให้แก้ version ใน manifest.json ให้สูงกว่านี้)")
                    return
                }
                print("\nmanifest")
                print("  version   \(info.version)")
                print("  download  \(info.download)")
                print("  sha256    \(info.sha256.isEmpty ? "— (ไม่มีใน manifest)" : info.sha256)")
                print("  minMacOS  \(info.minMacOS.isEmpty ? "—" : info.minMacOS)\(info.needsNewerOS ? "  ✗ เครื่องนี้ใช้ไม่ได้" : "")")
                // `.path` FIRST was wrong, and wrong in the one way this line exists to rule
                // out: for an https URL `.path` is non-empty, so the `??` never reached
                // `absoluteString` and a GitHub release printed as
                // `/sonnori/IntroPlayer/releases/download/…` — a remote link displayed as a
                // local absolute path. `openable` is precisely the gate that tells those two
                // apart (§15: a remote link must be http/https; a local path must end in
                // `.zip`), so this was the one line in the diagnostic that could not be
                // allowed to blur them. Branch on the URL instead of leaning on a nil-coalesce.
                if let u = info.openable {
                    print("  openable  \(u.isFileURL ? "ไฟล์ในเครื่อง: \(u.path)" : u.absoluteString)")
                } else {
                    print("  openable  ✗ ถูกบล็อก")
                }
                guard info.openable != nil else { ok = false; return }

                let dir = try Updater.scratch()
                defer { try? FileManager.default.removeItem(at: dir) }

                var ticks = 0
                let t0 = Date()
                let zip = try await Updater.fetchZip(info, into: dir) { _ in ticks += 1 }
                let dl = Date().timeIntervalSince(t0)
                let size = ((try? FileManager.default
                    .attributesOfItem(atPath: zip.path))?[.size] as? Int) ?? 0
                print("\nดาวน์โหลด")
                print(String(format: "  %.2f MB in %.2fs  (%d progress ticks)",
                             Double(size) / 1_048_576, dl, ticks))

                let t1 = Date()
                let staged = try Updater.stage(zip: zip, in: dir, expecting: info)
                print(String(format: "\nแตกไฟล์ + ตรวจ  %.2fs", Date().timeIntervalSince(t1)))
                print("  staged at \(staged.lastPathComponent)")
                let fm = FileManager.default
                // `Install.bundleName`, NOT a literal. This loop is what `Updater.Install`
                // calls the proof that the Swift copy of the bundle name still agrees with a
                // real release — and it was hardcoded to the pre-1.3.0 name, so it proved the
                // opposite: it never read `bundleName` at all, and would have reported
                // `✗ ไม่ผ่าน` against a perfectly good zip. A check that names its subject
                // literally is not checking the thing it claims to.
                for f in [Updater.Install.bundleName, Updater.installerName, "VERSION", "server.py"] {
                    let there = fm.fileExists(atPath: staged.appendingPathComponent(f).path)
                    print("  \(there ? "ok  " : "✗   ")\(f)")
                    if !there { ok = false }
                }
                print("  ✓ แอปที่แตกออกมาตอบเวอร์ชั่น \(info.version) ตรงกับ manifest")
                print("\nถ้ากดอัปเดตจริง จะเรียก:")
                print("  bash \(staged.appendingPathComponent(Updater.installerName).path) \\")
                print("    --unattended --target \(AppPaths.root.path) --wait-pid <pid> --relaunch")
            } catch {
                ok = false
                print("\n✗ \(error.localizedDescription)")
            }
        }
        if sem.wait(timeout: .now() + 960) == .timedOut {
            ok = false
            print("\n✗ ค้าง ไม่เสร็จในเวลา")
        }
        print(ok ? "\n✓ ผ่าน" : "\n✗ ไม่ผ่าน")
    }

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

    /// Where each song's cover comes from. Read-only and OFFLINE — it never makes a request,
    /// which is the point: if this says every song has embedded art, the online fallback is
    /// dead code for this library and nothing will ever go to the network.
    static func artworkReport() {
        let songs = Library.scan()
        var embedded = 0, cachedN = 0, none = 0
        print("ที่มาของปกเพลง (ไม่ต่อเน็ต)\n")
        for p in songs {
            let hasCache = FileManager.default.fileExists(atPath: Artwork.cacheURL(for: p).path)
            let hasEmbedded = Artwork.embedded(for: p) != nil
            let src: String
            if hasCache { src = "ไฟล์ที่โหลดมา (.covers/)"; cachedN += 1 }
            else if hasEmbedded { src = "ฝังมาในไฟล์เพลง"; embedded += 1 }
            else { src = "— ไม่มี"; none += 1 }
            print(String(format: "   %-44@ %@",
                         String(Library.baseName(p).prefix(42)) as NSString, src as NSString))
        }
        print("\nฝังมาในไฟล์ \(embedded) · โหลดเก็บไว้ \(cachedN) · ไม่มี \(none)")
        if none > 0 {
            print("เพลงที่ไม่มี ใช้เมนู ⋯ → ดึงปกเพลงของรอบนี้ (ต้องต่อเน็ต)")
        } else {
            print("ครบทุกเพลงโดยไม่ต้องต่อเน็ตเลย")
        }
        print("\nตรวจตัวกันจับผิดเพลง (ปฏิเสธผลที่ชื่อไม่เกี่ยวกัน):")
        let cases: [(String, String, Bool)] = [
            ("BOWKYLION วาดไว้", "สัมผัสรัก (Touch my heart)", false),
            ("PROXIE ขี้แง", "ขี้แง (Boys Don’t Cry) [feat. 2Ectasy]", true),
            ("Palmy Ooh!", "Ooh!", true),
            ("THE TOYS ลาลาลอย", "Just Being Friendly", false),
            // "the" alone must not be a match, or every English title matches every other
            ("THE TOYS ลาลาลอย", "The Weekend", false),
            ("Morvasu Melbourne", "Melbourne", true),
        ]
        var bad = 0
        for (q, t, want) in cases {
            let got = Artwork.plausible(query: q, track: t)
            if got != want { bad += 1 }
            print("   \(got == want ? "ok " : "✗  ")\(q)  →  \(t)  = \(got ? "รับ" : "ปฏิเสธ")")
        }
        print(bad == 0 ? "\n✓ ผ่าน" : "\n✗ ไม่ผ่าน")
    }

    /// The guess feature's **admission rule**, driven through a real `AppModel` and a real
    /// playing `Player`. `--guesstest` proves the arithmetic and the data-dependent refusals
    /// without any of that; this is the half that needs the app actually running.
    ///
    /// It exists because the rule it checks replaced `player.isPlaying`, and the case that
    /// mattered is the one `isPlaying` reports as FALSE: paused on a buzz. A guess landing in
    /// that window moves Intro End, and the next Space derives `.free` from a playhead now past
    /// it — no intro bound, the whole song on camera. That cannot be proven by reading the
    /// config; the playhead has to be somewhere.
    ///
    /// **Restores what it writes**, and verifies the restore, so it is safe to run on a real
    /// library. It still needs `INTROPLAYER_DIAG=1` because it writes at all.
    @MainActor static func guessFlow() {
        var pass = 0, fail = 0
        func check(_ l: String, _ ok: Bool, _ d: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(l)\(d.isEmpty ? "" : "  — " + d)")
        }
        let m = AppModel()
        guard let song = m.songsIn(m.currentPlaylist).first else { print("no songs"); return }
        let other = m.songsIn(m.currentPlaylist).dropFirst().first
        let saved = m.store.config(for: song)
        print("song: \(Library.baseName(song))")
        print("  เริ่มต้น: introStart=\(saved.introStart) introEnd=\(saved.introEnd) " +
              "configured=\(saved.configured) auto=\(saved.auto)\n")

        m.current = song
        m.player.load(url: Library.url(song))
        m.player.muteForTest()
        m.player.seek(to: saved.introStart, config: saved)

        print("1) จอดอยู่ที่ Intro Start ของตัวเอง = พักอยู่ ให้เขียนได้")
        check("guessAllowed = true", m.guessAllowed(song),
              String(format: "position %.2f  introStart %.2f", m.player.position, saved.introStart))

        print("\n2) กำลังเล่น = ห้ามเขียน")
        m.player.toggleStart(config: saved)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 1.2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if m.player.position > saved.introStart + 0.6 { break }
        }
        check("guessAllowed = false ขณะเล่น", !m.guessAllowed(song),
              "playing=\(m.player.isPlaying) " + String(format: "position %.2f", m.player.position))

        print("\n3) กดหยุดกลางคำถาม (isPlaying = false) = ยังห้ามเขียน  ← จุดที่เคยพลาด")
        m.player.pause()
        let parked = m.player.position
        check("isPlaying เป็น false จริง", !m.player.isPlaying)
        check("guessAllowed ยัง false", !m.guessAllowed(song),
              String(format: "position %.2f ห่างจาก introStart %.2f", parked, parked - saved.introStart))

        print("\n4) เพลงอื่นที่ไม่ได้อยู่บนจอ = เขียนได้ (ไม่มีอะไรของมันออกอากาศ)")
        if let o = other {
            check("guessAllowed = true สำหรับเพลงที่ไม่ใช่ current", m.guessAllowed(o),
                  Library.baseName(o))
        } else { print("   — มีเพลงเดียวในรอบนี้ ข้าม") }

        print("\n5) กลับไปจอดที่จุดเริ่ม = เขียนได้อีกครั้ง")
        m.player.seek(to: saved.introStart, config: saved)
        check("guessAllowed = true", m.guessAllowed(song))

        print("\n6) การเดาต้องไม่นับเป็นการตรวจ")
        m.applyAutoStart(song, analysis: Analysis(), manual: false)   // no analysis → refuses
        var c = m.store.config(for: song)
        check("analysis ว่าง → ไม่เขียนอะไร", c.introStart == saved.introStart)
        m.updateConfigQuiet { $0.introEnd = $0.introStart + 9 }       // a human edit, for contrast
        c = m.store.config(for: song)
        check("แก้โดยคน → configured=true auto=false", c.configured && !c.auto)

        print("\n7) คืนค่าเดิม")
        m.store.set(saved, for: song)
        m.store.saveNow()
        let back = m.store.config(for: song)
        check("config ของเพลงนี้กลับเป็นค่าเดิมทุกช่อง", SongConfig.same(back.introStart, saved.introStart)
              && SongConfig.same(back.introEnd, saved.introEnd)
              && SongConfig.same(back.hook, saved.hook)
              && back.configured == saved.configured && back.auto == saved.auto)

        print("\nผ่าน \(pass)  ตก \(fail)")
        print(fail == 0 ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

    /// The launch snapshot: what it holds, whether it can write, and what it does NOT cover.
    ///
    /// Writes a real snapshot (that is the thing being tested) but touches nothing else — the
    /// operator's `config.json` and `log.json` are READ, never modified.
    static func snapshotReport() {
        let store = Store()
        print("โฟลเดอร์สำรอง: \(Snapshot.dir.path)")
        print("โฟลเดอร์ sync : \(store.backupDir.isEmpty ? "— (ยังไม่ตั้ง, _settings.backupDir)" : store.backupDir)")
        var pass = 0, fail = 0
        func check(_ l: String, _ ok: Bool, _ d: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(l)\(d.isEmpty ? "" : "  — " + d)")
        }

        guard let shot = Snapshot.capture() else {
            print("\n✗ อ่าน config.json ไม่ได้ หรือยังไม่มีโจทย์ — ไม่มีอะไรให้สำรอง")
            return
        }
        print(String(format: "\nจะสำรอง: config.json %d bytes%@",
                     shot.config.count,
                     shot.log.map { " · log.json \($0.count) bytes" } ?? " · ไม่มี log.json"))

        let before = Snapshot.existing().count
        let r = Snapshot.write(shot, version: AppVersion.short, mirrorTo: store.backupDir)
        let after = Snapshot.existing()
        print("\nผลการเขียน")
        if r.skipped { print("   ข้าม — เหมือนชุดล่าสุดเป๊ะ (ถูกต้อง: เปิดแอปเฉย ๆ ไม่ควรกินช่องในวง)") }
        if let w = r.wrote { print("   เขียน \(w)") }
        if r.pruned > 0 { print("   ลบของเก่าเกิน \(Snapshot.keep) ชุด: \(r.pruned)") }
        if let m = r.mirrored { print("   คัดลอกไป \(m)") }
        for p in r.problems { print("   ⚠ \(p)") }

        check("มีชุดสำรองอยู่อย่างน้อยหนึ่งชุด", !after.isEmpty)
        check("ไม่เกินเพดาน \(Snapshot.keep) ชุด", after.count <= Snapshot.keep,
              "มี \(after.count) (ก่อนรัน \(before))")
        if let newest = after.first {
            let back = try? Data(contentsOf: newest.appendingPathComponent("config.json"))
            check("ชุดล่าสุดเท่ากับ config.json ปัจจุบันทุกไบต์", back == shot.config)
            check("มี อ่านก่อน.txt บอกวิธีคืนค่า",
                  FileManager.default.fileExists(atPath: newest.appendingPathComponent("อ่านก่อน.txt").path))
        }
        // The second run must be a no-op: nothing changed in between.
        let again = Snapshot.write(shot, version: AppVersion.short, mirrorTo: "")
        check("รันซ้ำทันทีต้องข้าม ไม่เขียนซ้ำ", again.skipped && again.wrote == nil)

        print("\n   สิ่งที่ครอบคลุม : git clean -xdf · แก้ไฟล์ผิด · บั๊กในแอป · กดปุ่มทำลายพลาด")
        print("   สิ่งที่ยังไม่ครอบคลุม: โฟลเดอร์หรือดิสก์หายทั้งก้อน")
        print("                      ← ปิดช่องนี้ด้วยการตั้ง _settings.backupDir เป็น path ในโฟลเดอร์ sync")

        print("\nผ่าน \(pass)  ตก \(fail)")
        print(fail == 0 ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

    /// Can the auto-guess feature damage anything? Read-only — it writes no file and calls no
    /// store mutation.
    ///
    /// The owner's requirement for this feature is explicit: **a wrong guess costs nothing, a
    /// bug costs a re-shoot.** So this asserts nothing about accuracy. It asserts the two things
    /// that can actually hurt:
    ///
    /// 1. **No value the feature can write can harm the program.** Every marker that reaches
    ///    `config.json` must be finite, inside `0...maxTime`, and satisfy
    ///    `introEnd >= introStart + minIntro` — the last one because `introStart == introEnd`
    ///    makes `modeForPosition` return `.free`, which disarms the intro-end stop and plays
    ///    the whole song on camera. Section 1 feeds `clampMarkers` the inputs that have
    ///    actually broken this app or a comparable path before: NaN, infinities, `1e19` (which
    ///    TRAPS in `Int(_:)`), `1e308` (which `round2` turns into infinity, after which every
    ///    save fails), negatives, and a degenerate range.
    /// 2. **The admission rules are what the comments claim.** Section 2 reports, per real
    ///    song, whether each half of the feature would write, and asserts it refuses on a
    ///    signed-off round (`base != nil`) and on any field a human has moved off its default.
    static func guessSafety() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }

        print("1) clampMarkers กับค่าที่เคยทำให้พัง  (ไม่ต้องมีไฟล์เสียง)")
        let nasty: [(String, Double, Double, Double, Double?)] = [
            ("NaN ทั้งสามจุด",          .nan, .nan, .nan, 200),
            ("+infinity",              .infinity, .infinity, .infinity, 200),
            ("-infinity",              -.infinity, -.infinity, -.infinity, 200),
            ("1e19 (Int() จะ trap)",    1e19, 1e19, 1e19, 200),
            ("1e308 (round2 -> inf)",   1e308, 1e308, 1e308, 200),
            ("ติดลบ",                   -5, -5, -5, 200),
            ("ช่วงพิการ start==end",     33.73, 33.73, 60, 200),
            ("end อยู่ก่อน start",       40, 10, 60, 200),
            ("เกินความยาวเพลง",          500, 600, 700, 200),
            ("duration เป็น NaN",        10, 25, 60, Double.nan),
            ("duration เป็น 0",          10, 25, 60, 0),
            ("ไม่รู้ duration",          10, 25, 60, nil),
        ]
        for (name, a, b, h, dur) in nasty {
            var c = SongConfig()
            c.introStart = a; c.introEnd = b; c.hook = h
            let r = AppModel.clampMarkers(c, duration: dur)
            let finite = r.introStart.isFinite && r.introEnd.isFinite && r.hook.isFinite
            let inRange = [r.introStart, r.introEnd, r.hook]
                .allSatisfy { $0 >= 0 && $0 <= AppModel.maxTime }
            let armed = r.introEnd >= r.introStart + AppModel.minIntro - 1e-9
            check(name, finite && inRange && armed,
                  String(format: "start %.2f  end %.2f  hook %.2f", r.introStart, r.introEnd, r.hook))
            // round2 is what actually reaches the file, so prove THAT is serialisable.
            let json: [String: Any] = ["introStart": Store.round2(r.introStart),
                                       "introEnd": Store.round2(r.introEnd),
                                       "hook": Store.round2(r.hook)]
            check("  ^ เขียนเป็น JSON ได้", JSONSerialization.isValidJSONObject(json))
        }

        print("\n2) กฎการรับเข้า ต่อเพลงจริง  (เดา/ตั้งไว้/จะเขียนไหม)")
        let store = Store()
        let songs = Library.scan()
        let d = SongConfig.defaults
        var admittedFresh = 0
        for p in songs {
            let c = store.config(for: p)
            let startIsDefault = SongConfig.same(c.introStart, d.introStart)
            let endIsDefault = SongConfig.same(c.introEnd, d.introEnd)
            let hookIsDefault = SongConfig.same(c.hook, d.hook)
            let signedOff = c.base != nil
            // The two halves, exactly as `applyAutoStart` and `applyGuess` decide (minus
            // `guessAllowed`, which needs a live player and is proven by --remodetest/--playtest).
            let autoStartWrites = !signedOff && startIsDefault && endIsDefault
            let autoEndWrites = !signedOff && !c.isConfigured && endIsDefault
            let autoHookWrites = !signedOff && !c.isConfigured && hookIsDefault
            if autoStartWrites || autoEndWrites || autoHookWrites { admittedFresh += 1 }
            print(String(format: "   %-28@ start %7.2f%@  end %7.2f%@  hook %7.2f%@  %@",
                         String(Library.baseName(p).prefix(28)) as NSString,
                         c.introStart, (autoStartWrites ? " W" : " ·") as NSString,
                         c.introEnd, (autoEndWrites ? " W" : " ·") as NSString,
                         c.hook, (autoHookWrites ? " W" : " ·") as NSString,
                         (signedOff ? "ส่งต่อแล้ว" : (c.isConfigured ? "ตั้งค่าแล้ว" : "")) as NSString))
            if signedOff {
                check("  ^ รอบที่ส่งต่อแล้วต้องไม่ถูกเขียน",
                      !autoStartWrites && !autoEndWrites && !autoHookWrites)
            }
            if !startIsDefault { check("  ^ start ที่คนตั้งต้องไม่ถูกทับ", !autoStartWrites) }
            if !hookIsDefault { check("  ^ hook ที่คนตั้งต้องไม่ถูกทับ", !autoHookWrites) }
        }
        print("\n   เพลงที่ยังรับการเดาได้ \(admittedFresh)/\(songs.count)  (W = จะเขียนช่องนั้น)")

        print("\nผ่าน \(pass)  ตก \(fail)")
        print(fail == 0 ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

    /// What the auto-guess proposes for every song, against whatever is configured. Read-only.
    ///
    /// Ground truth is thin — the real library has three hooks that differ from the 60 s default
    /// at all — so this does NOT pass or fail on agreement with the config. It prints both and
    /// the repetition score, so the guess can be judged by ear. What it does assert is the part
    /// that is objectively checkable: a guess must be inside the song, after the intro, and the
    /// chosen hook must actually repeat somewhere.
    static func autoDetectReport() {
        let store = Store()
        let songs = Library.scan()
        var pass = 0, fail = 0, skip = 0
        print("เทียบค่าที่เดา กับค่าที่ตั้งไว้ใน config.json  (\(songs.count) เพลง)\n")
        print(String(format: "   %-26@ %17@ %17@ %6@",
                     "song" as NSString, "intro end (เดา/ตั้ง)" as NSString,
                     "hook (เดา/ตั้ง)" as NSString, "หลักฐาน" as NSString))
        for p in songs {
            guard let a = try? Analysis.analyse(url: Library.url(p)),
                  let f = AutoDetect.extract(url: Library.url(p)) else {
                print("   \(Library.baseName(p))  — อ่านไม่ได้"); continue
            }
            let c = store.config(for: p)
            let start = a.detectIntroStart() ?? c.introStart
            let iEnd = AutoDetect.introEnd(features: f, from: start)
            let h = AutoDetect.hook(features: f, after: iEnd)
            let name = String(Library.baseName(p).prefix(26))
            // Bound to `Double` locals FIRST. `h?.time ?? -1` passed STRAIGHT into a
            // `CVarArg...` list resolves to the `??(T?, T?) -> T?` overload — because
            // `Optional` itself conforms to `CVarArg` — so what reaches the va_list is an
            // `Optional<Double>`, not a `Double`, and `%f` reads the wrong eight bytes.
            // It printed `nan` for a value that was -1.0. `type(of:)` reports `Double`,
            // because in a non-variadic context the other overload wins — so the type checker
            // will not warn you and an inspection of the expression lies. This was the only
            // occurrence in the project; the safe idiom everywhere else is
            // `opt.map { String(format: …, $0) } ?? "—"`, where the `??` yields a String.
            let hTime: Double = h?.time ?? -1
            let hRep: Double = h?.repetition ?? 0
            let hLoud: Double = h?.loudness ?? 0
            let hookCol: String = h == nil ? "     —" : String(format: "%6.1f", hTime)
            print(String(format: "   %-26@  %6.1f / %6.1f   %@ / %6.1f  ซ้ำ %4.2f ดัง %4.2f %@",
                         name as NSString, iEnd, c.introEnd,
                         hookCol as NSString, c.hook, hRep, hLoud,
                         ((h?.onBoundary ?? false) ? "รอยต่อ" : "—") as NSString))

            // The objectively checkable part. **No guess at all is a PASS, not a failure.**
            // Declining is the correct, safe outcome for a file with no usable structure —
            // silence, a constant tone, a 10-second clip — and the owner's requirement for
            // this feature is that a wrong or absent guess costs nothing. Counting it as a
            // failure made one odd file in the library print `✗ ไม่ผ่าน` for the whole run,
            // which is §12's "a warning that fires when nothing is wrong is a warning that
            // gets ignored on the day it matters". Skips are printed, so a detector that
            // silently stopped guessing everything is still visible.
            let okEnd = iEnd > start && iEnd < a.duration
            if okEnd { pass += 1 } else { fail += 1; print("      ✗ intro end อยู่ในเพลง") }
            guard let h else {
                skip += 2
                print("      – ไม่เดา hook ให้ (ไม่มีโครงสร้างที่ใช้ได้) — ปลอดภัย ไม่นับตก")
                continue
            }
            for (label, ok) in [("hook อยู่หลัง intro และไม่เลยท้ายเพลง",
                                 h.time > iEnd && h.time < a.duration - 2),
                                ("hook ที่เลือกซ้ำจริง (correlation > 0.5)",
                                 h.repetition > 0.5)] {
                if ok { pass += 1 } else { fail += 1; print("      ✗ \(label)") }
            }
        }
        print("\nผ่าน \(pass)  ตก \(fail)\(skip > 0 ? "  ข้าม \(skip) (ไม่เดาให้)" : "")")
        print(fail == 0 ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

    /// Is the intro auto-gain actually levelling what the audience hears?
    ///
    /// Read-only. Measures every intro two ways — the app's gated LUFS and, independently, by
    /// re-reading the file — and reports the SPREAD of on-air loudness left behind. A normaliser
    /// is only as good as that spread. Also reports how much of each gain the output limiter
    /// takes back, because a gain the limiter eats is not a gain the audience hears.
    static func loudTest() {
        var pass = 0, fail = 0
        func assertThat(_ ok: Bool) { if ok { pass += 1 } else { fail += 1 } }

        // The coefficients are derived per file rate, so prove the derivation against the one
        // rate BS.1770-4 publishes a table for. Getting this wrong is silent.
        print("1) สัมประสิทธิ์ K-weighting ที่ 48 kHz เทียบตาราง BS.1770-4")
        let (shelf, hp) = Loudness.kWeighting(rate: 48000)
        let want: [(String, Double, Double)] = [
            ("shelf b0", shelf.b0,  1.53512485958697),
            ("shelf b1", shelf.b1, -2.69169618940638),
            ("shelf b2", shelf.b2,  1.19839281085285),
            ("shelf a1", shelf.a1, -1.69065929318241),
            ("shelf a2", shelf.a2,  0.73248077421585),
            ("hp a1",    hp.a1,    -1.99004745483398),
            ("hp a2",    hp.a2,     0.99007225036621),
        ]
        for (name, got, expect) in want {
            let ok = abs(got - expect) <= 1e-10
            assertThat(ok)
            print(String(format: "   %@ %-9@ %+.14f  want %+.14f",
                         (ok ? "ok " : "✗  ") as NSString, name as NSString, got, expect))
        }

        let store = Store()
        let songs = Library.scan()
        let scope = store.loudnessScope
        print("\n2) วัดช่วง intro ของทุกเพลง  (songs=\(songs.count) scope=\(scope.rawValue))")

        struct Row {
            let name: String, a: Double, b: Double
            let lufs: Double, peakDb: Double, gain: Double
            let clamped: Bool, eats: Double
        }
        var rows: [Row] = []
        var worstDelta = 0.0, worstName = "—"

        for s in songs {
            guard let an = try? Analysis.analyse(url: Library.url(s)) else {
                print("   \(Library.baseName(s))  FAILED to analyse"); continue
            }
            let c = store.config(for: s)
            let m = an.measuredLufs(config: c, scope: scope)
            var lo = min(c.introStart, c.introEnd), hi = max(c.introStart, c.introEnd)
            if m.usedScope == .song { lo = 0; hi = an.duration }

            // Cross-check: the fast path reads sub-blocks cached during analysis, the reference
            // re-reads the file. A reference implementation is only worth keeping if something
            // actually compares against it.
            //
            // Snap the reference to the SAME 100 ms grid. The cached sub-blocks are laid out
            // from frame 0, so `Analysis.lufs` always measures whole sub-blocks; handing the
            // reference the raw marker times gave it a different block phase, and on song 107
            // — near-silence with one transient — a shifted grid moves which blocks clear the
            // gates and the answer moved 0.72 LU. That is two legitimate measurements of
            // slightly different things, not a defect, but it makes the check meaningless.
            let step = Loudness.stepSec
            let snapLo = (lo / step).rounded(.down) * step
            let snapHi = (hi / step).rounded(.up) * step
            if let ref = Loudness.measure(url: Library.url(s), from: snapLo, to: snapHi),
               ref.lufs.isFinite, m.lufs.isFinite {
                let d = abs(ref.lufs - m.lufs)
                if d > worstDelta { worstDelta = d; worstName = Library.baseName(s) }
            }

            let raw = Analysis.targetLufs - m.lufs
            let g = min(max(raw, -12), 12)
            let pk = Double(an.peak(lo, hi))
            let peakDb = pk > 0 ? 20 * log10(pk) : -.infinity
            let headroom = Player.limiterCeilingDb - peakDb
            rows.append(Row(name: String(Library.baseName(s).prefix(26)), a: lo, b: hi,
                            lufs: m.lufs, peakDb: peakDb, gain: g,
                            clamped: abs(raw - g) > 1e-9,
                            eats: headroom.isFinite ? max(0, g - headroom) : 0))
        }
        guard !rows.isEmpty else { print("   ไม่มีเพลงที่วัดได้"); return }

        print(String(format: "   %-26@ %11@ %8@ %8@ %8@",
                     "song" as NSString, "intro" as NSString, "LUFS" as NSString,
                     "peak" as NSString, "gain" as NSString))
        for r in rows {
            print(String(format: "   %-26@ %5.1f-%5.1f %8.2f %8.1f %+8.2f%@",
                         r.name as NSString, r.a, r.b, r.lufs, r.peakDb, r.gain,
                         (r.clamped ? " CLAMP" : "") as NSString))
        }

        print("\n3) ทางเร็ว (sub-block ที่แคชไว้) ต้องตรงกับการอ่านไฟล์ใหม่")
        let okFast = worstDelta < 0.15
        assertThat(okFast)
        print(String(format: "   %@ต่างมากสุด %.3f LU  (%@)",
                     (okFast ? "ok  " : "✗   ") as NSString, worstDelta, worstName as NSString))

        func spread(_ v: [Double]) -> (lo: Double, hi: Double, span: Double, sd: Double) {
            let lo = v.min() ?? 0, hi = v.max() ?? 0
            let mean = v.reduce(0, +) / Double(v.count)
            let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
            return (lo, hi, hi - lo, sd)
        }
        let before = spread(rows.map { $0.lufs })
        let after = spread(rows.map { $0.lufs + $0.gain })
        // A clamped song CANNOT reach target, so it is reported apart rather than allowed to
        // swamp the figure for the set.
        let reachable = rows.filter { !$0.clamped }
        let afterOK = spread(reachable.map { $0.lufs + $0.gain })

        print("\n4) ความต่างของความดังที่ออกอากาศ (LU — ยิ่งน้อยยิ่งเท่ากัน)")
        print(String(format: "   ไม่ปรับอะไรเลย      %7.2f .. %7.2f  กว้าง %5.2f  sd %4.2f",
                     before.lo, before.hi, before.span, before.sd))
        print(String(format: "   หลังเกลี่ย          %7.2f .. %7.2f  กว้าง %5.2f  sd %4.2f",
                     after.lo, after.hi, after.span, after.sd))
        print(String(format: "   เฉพาะเพลงที่ถึงเป้า  %7.2f .. %7.2f  กว้าง %5.2f  sd %4.2f  (%d/%d เพลง)",
                     afterOK.lo, afterOK.hi, afterOK.span, afterOK.sd, reachable.count, rows.count))
        let okSpread = afterOK.span < 0.5
        assertThat(okSpread)
        print("   \(okSpread ? "ok  " : "✗   ")เพลงที่ถึงเป้าต้องเท่ากันแทบสนิท")

        print("\n5) ลิมิตเตอร์กินคืนเท่าไหร่ (gain ที่ขอ เทียบกับที่หัวเพลงเหลือให้)")
        var eaten = 0
        for r in rows where r.eats > 0.1 {
            eaten += 1
            print(String(format: "   %-26@ ขอ %+.2f  กินคืน %.2f dB", r.name as NSString, r.gain, r.eats))
        }
        if eaten == 0 { print("   ไม่มี — ลิมิตเตอร์ไม่ทำงานในช่วง intro ของเพลงไหนเลย") }
        else { print("   \(eaten)/\(rows.count) เพลง — SetupPanel กับ pre-flight จะเตือนให้") }

        print("\nผ่าน \(pass)  ตก \(fail)")
        // The compiler emits `warning: will never be executed` on the `✗` branch here, with
        // `note: condition always evaluates to true`. **It is wrong, and the branch must stay.**
        // Proved by inserting one failing assertion that cannot be constant-folded: the run
        // printed `ผ่าน 9  ตก 1` and `✗ ไม่ผ่าน`. The false positive comes from the mandatory
        // pass not seeing `assertThat`'s `fail += 1` as an assignment to the captured var.
        //
        // What DID make this suite look like it always passed is unrelated and was real: for a
        // library containing an unreadable file, `Loudness.measure` died on an uncatchable
        // Obj-C exception (see `Loudness.measure`) and the process never reached these two
        // lines at all. A suite that cannot print its own verdict reads exactly like a suite
        // that passed.
        print(fail == 0 ? "✓ ผ่าน" : "✗ ไม่ผ่าน")
    }

}
