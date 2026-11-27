import Foundation
import AppKit
import ImageIO

/// Where the app's data lives. The bundle sits inside the project folder exactly like the shell
/// launcher did, so `songs/`, `config.json` and `log.json` stay shared with the web version.
/// Where the program is, and where the questions are — **two different places now**.
///
/// Until this they were one: `root` was the bundle's parent, and `songs/`, `config.json`,
/// `log.json`, `se/` and `brand/` were its siblings (§5). That is what makes §15's surgical swap
/// possible and it is not being thrown away — but it also means the app cannot live in
/// `/Applications`, because it would then look for `/Applications/songs/` and try to write
/// `/Applications/config.json`. A drag-to-Applications install and a "choose the songs folder"
/// picker are therefore the SAME change, not two.
///
/// **`programRoot` and `root` must not be confused, and the compiler cannot tell them apart.**
/// `programRoot` is where the bundle sits: it is what the installer replaces, what
/// `InstallLocation` records, and what `Updater.apply` passes as `--target`. `root` is where the
/// operator's questions are. Passing the data root to the installer would install the program on
/// top of the questions; passing the program root to `Store` would look for a library beside the
/// app. Every call site had to be read and classified by hand when this split landed — there is
/// no test that can catch getting one wrong, only the names.
enum AppPaths {
    // MARK: the program

    /// The folder the `.app` sits in. Never stored, always derived — this is a fact about where
    /// the process was launched from, not a preference.
    static var programRoot: URL {
        var u = Bundle.main.bundleURL
        if u.pathExtension == "app" { u.deleteLastPathComponent() }
        return u
    }

    // MARK: the questions

    /// Where the operator's questions live. See `resolveRoot` for the order it is found in.
    ///
    /// Resolved ONCE per process and cached, because it is read from `body` (the About row, the
    /// header) and from the save path — the `stat`-50-times-a-second lesson §6e records for the
    /// logo, in a place where the answer also must not change under a half-finished save.
    static var root: URL {
        if let r = cachedRoot { return r }
        let (url, src) = resolveRoot()
        cachedRoot = url
        rootSourceCache = src
        return url
    }
    static var songs: URL { root.appendingPathComponent("songs") }
    static var se: URL { root.appendingPathComponent("se") }
    static var config: URL { root.appendingPathComponent("config.json") }
    static var log: URL { root.appendingPathComponent("log.json") }
    static var brand: URL { root.appendingPathComponent("brand") }

    /// How `root` was found. `.none` means there is no library anywhere we know to look, which is
    /// the state a fresh DMG install starts in and the one thing the UI must not render as an
    /// empty song list — that is §8c's "the app can't find my songs", which was reported from
    /// real use when the cause was merely a remembered playlist.
    enum RootSource: String {
        case chosen      // the operator picked it; stored in UserDefaults
        case breadcrumb  // ~/Library/Application Support/IntroPlayer/location
        case beside      // the classic layout: the library is the bundle's sibling
        case none        // nothing found — ask
    }

    private static var cachedRoot: URL?
    private static var rootSourceCache: RootSource?
    /// Reading this resolves `root` if it has not been resolved yet, so the two can never
    /// disagree about which candidate won.
    static var rootSource: RootSource {
        if rootSourceCache == nil { _ = root }
        return rootSourceCache ?? .none
    }
    static var hasRoot: Bool { rootSource != .none }

    static let dataRootKey = "dataRoot"

    /// Order matters, and every step is a fallback rather than a default:
    ///
    /// 1. what the operator CHOSE — survives the app moving, which is the whole point;
    /// 2. the bundle's sibling — the classic layout, unchanged. **This is why nothing breaks for
    ///    an existing install:** the folder beside the app wins before anybody is prompted;
    /// 3. the breadcrumb the app already writes for the installer (§15 step 2), so a machine that
    ///    has been running the classic layout keeps working after the app moves to `/Applications`
    ///    without anyone being asked anything;
    /// 4. nothing. Not a guess, and above all not a freshly created empty folder: inventing a
    ///    second, empty library is how a day of markers becomes invisible rather than lost.
    ///
    /// **`beside` must come before `breadcrumb`, and the first draft had it the other way round.**
    /// `InstallLocation.record()` rewrites the breadcrumb from the program folder on every launch
    /// — but it runs in `AppModel.init` AFTER the root has been resolved. So with the breadcrumb
    /// first, copying a whole classic-layout folder somewhere new and opening it read the OLD
    /// folder for one entire launch before the breadcrumb caught up: a session of marker edits
    /// landing in the copy the operator thought they had left behind. Found by running
    /// `--whereami` in the project folder and seeing `source: breadcrumb` where `beside` was the
    /// honest answer — the two happened to be the same path, so nothing looked wrong.
    /// In `/Applications` there is no library beside the app, so step 2 falls through and the
    /// breadcrumb still does the migration it was added for.
    ///
    /// Each candidate must look like a library (`looksLikeLibrary`), so a bundle in
    /// `/Applications` does not adopt `/Applications` and a stale breadcrumb does not win over a
    /// real folder beside the app.
    static func resolveRoot() -> (URL, RootSource) {
        resolveRoot(chosen: UserDefaults.standard.string(forKey: dataRootKey),
                    breadcrumb: try? String(contentsOf: InstallLocation.file, encoding: .utf8),
                    beside: programRoot)
    }

    /// The order, with its three inputs passed in rather than read.
    ///
    /// Parameterised so `--roottest` can prove the precedence without touching the operator's
    /// `UserDefaults` or their breadcrumb — a diagnostic that had to write the real "chosen
    /// folder" key in order to test it would be the one flag capable of pointing the app at the
    /// wrong library, which is the failure the whole resolver exists to avoid.
    static func resolveRoot(chosen: String?, breadcrumb: String?,
                            beside: URL) -> (URL, RootSource) {
        if let raw = chosen {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty {
                let u = URL(fileURLWithPath: p)
                if looksLikeLibrary(u) { return (u, .chosen) }
            }
        }
        if looksLikeLibrary(beside) { return (beside, .beside) }
        if let raw = breadcrumb {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty {
                let u = URL(fileURLWithPath: p)
                if looksLikeLibrary(u) { return (u, .breadcrumb) }
            }
        }
        return (beside, .none)
    }

    /// Is there a library here? `songs/` as a directory, or a `config.json` — the same two marks
    /// the retired `installer.command`'s `valid_target` used, for the same reason: they are
    /// what an install
    /// has and what a download, a release folder or an arbitrary directory does not.
    ///
    /// §15 records that this test was too loose **for the installer**, because "any folder with a
    /// subdirectory called songs" qualified and the installer then deleted files. The stakes here
    /// are the opposite way round — this only decides where to READ — but the exclusions still
    /// apply, because adopting one of those folders points every later save at it.
    static func looksLikeLibrary(_ u: URL) -> Bool {
        let path = u.path
        guard !path.isEmpty, path != "/" else { return false }
        guard !isTransient(path), !inBackups(path) else { return false }
        return hasLibraryMarkers(u)
    }

    /// The shape test alone, with no exclusions. Split out so `--roottest` can build fixtures in
    /// the system temp dir — which `isTransient` rejects by design — and still check the marks.
    /// Production code calls `looksLikeLibrary`; there is no flag that turns an exclusion off.
    static func hasLibraryMarkers(_ u: URL) -> Bool {
        let fm = FileManager.default
        // An unzipped release has these and is not an install — §15's `launchedFromRelease`.
        for marker in ["ติดตั้ง-อัปเดต.command", "อ่านก่อน.txt"] where
            fm.fileExists(atPath: u.appendingPathComponent(marker).path) { return false }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: u.appendingPathComponent("songs").path, isDirectory: &isDir),
           isDir.boolValue { return true }
        return fm.fileExists(atPath: u.appendingPathComponent("config.json").path)
    }

    /// Temp roots and removable volumes. Lifted out of `InstallLocation`, which had the identical
    /// list private — a sandboxed verification run of the update feature once pointed the
    /// breadcrumb at a scratch folder that passed every check (§15), and the resolver reads that
    /// same breadcrumb.
    static let transientRoots = ["/private/tmp/", "/tmp/", "/private/var/folders/",
                                 "/var/folders/", "/Volumes/"]
    static func isTransient(_ path: String) -> Bool {
        transientRoots.contains { path.hasPrefix($0) }
    }
    /// Anything inside a `backups/` directory. The installer moves the previous bundle there and
    /// the Dock follows a same-volume move, so the operator's own icon can open the OLD app —
    /// which finds a `config.json` the installer copied in and no `songs/`. §15 calls this out as
    /// reachable, and pruning deletes that folder three updates later.
    static func inBackups(_ path: String) -> Bool { ("/" + path + "/").contains("/backups/") }

    /// Point the app at a different library. Returns nil on success, or the reason in Thai.
    ///
    /// Validation is deliberately the same `looksLikeLibrary` the resolver uses, so a folder the
    /// operator can choose is exactly a folder the app would have adopted on its own. Creating a
    /// new library is `createLibrary`, a separate verb — "open" and "create" doing the same thing
    /// is how an empty folder silently becomes a second library.
    @discardableResult
    static func setRoot(_ u: URL) -> String? {
        guard looksLikeLibrary(u) else {
            if isTransient(u.path) { return "โฟลเดอร์ชั่วคราว/ไดรฟ์นอก ใช้เป็นโฟลเดอร์งานไม่ได้" }
            if inBackups(u.path) { return "นี่คือโฟลเดอร์สำรองของตัวติดตั้ง ไม่ใช่โฟลเดอร์งาน" }
            return "โฟลเดอร์นี้ไม่มี songs/ หรือ config.json — ถ้าจะเริ่มรอบใหม่ ให้ใช้ \u{201C}สร้างโฟลเดอร์งานใหม่\u{201D}"
        }
        UserDefaults.standard.set(u.path, forKey: dataRootKey)
        cachedRoot = nil
        rootSourceCache = nil
        return nil
    }

    /// Make a library in an empty (or new) folder. Only `songs/` — `se/` and `brand/` are the
    /// production's own files (§6e, §15's `SEED[]`), and this build may not be carrying them.
    @discardableResult
    static func createLibrary(_ u: URL) -> String? {
        let fm = FileManager.default
        guard !isTransient(u.path), !inBackups(u.path) else {
            return "โฟลเดอร์ชั่วคราว/ไดรฟ์นอก ใช้เป็นโฟลเดอร์งานไม่ได้"
        }
        if looksLikeLibrary(u) { return setRoot(u) }   // already one; just open it
        do {
            try fm.createDirectory(at: u.appendingPathComponent("songs"),
                                   withIntermediateDirectories: true)
        } catch {
            return "สร้างโฟลเดอร์ไม่ได้: \(error.localizedDescription)"
        }
        return setRoot(u)
    }

    /// Only for `--roottest`: re-resolve without a relaunch.
    static func invalidateRootForTest() { cachedRoot = nil; rootSourceCache = nil }
}

/// First-run seeding: the production's own files, from the bundle into the questions folder.
///
/// §15's `SEED[]` promise was "copied on a fresh install, never overwritten by an update", and the
/// old installer kept it by copying `se/` and `brand/` out of the release zip. With the app in
/// `/Applications` there is no installer and nothing sitting next to the data, so the files travel
/// inside the bundle and this copies them out — under exactly the same rule.
///
/// **Only present in a crew build.** `build.sh --with-payload` is the only thing that puts
/// `Resources/seed/` there, and `release.sh --crew` is the only thing that passes it. A public
/// build has no seed folder at all and this does nothing: §15 records the day `brand` joined
/// `SEED[]` and the show's logo went into a public GitHub release, and baking it into every bundle
/// would do that permanently rather than once.
enum Seeding {
    /// Relative paths, destination-first thinking: each is copied only if it is ABSENT. That is
    /// the whole promise — an operator who swapped in their own stings must never lose them to a
    /// version bump, and the production's logo changes on the production's schedule, not ours.
    static let items = ["se/correct.mp3", "se/wrong.mp3", "brand/logo.png"]

    static var sourceDir: URL? {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("seed"),
              FileManager.default.fileExists(atPath: r.path) else { return nil }
        return r
    }

    /// Scripts seeded separately from `items` because they come from `Resources/scripts/` and
    /// ship in EVERY build — they are the program's, not the production's.
    ///
    /// Placed in the questions folder rather than left in the bundle on purpose: the diagnostic's
    /// whole instruction is "double-click this on the machine with the issue", and the situation
    /// it exists for is the app not working. A menu item inside that app would be no use there.
    static let scripts = ["ตรวจสอบเครื่อง.command"]

    @discardableResult
    static func placeScripts() -> Int {
        guard AppPaths.hasRoot,
              let web = Bundle.main.resourceURL?.appendingPathComponent("scripts")
        else { return 0 }
        let fm = FileManager.default
        var n = 0
        for name in scripts {
            let src = web.appendingPathComponent(name)
            let to = AppPaths.root.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.copyItem(at: src, to: to)
                // `copyItem` keeps the mode, but a bundle that lost the +x — an Archive Utility
                // round trip, a Drive sync — would leave a file that opens in TextEdit instead
                // of running, which for a diagnostic is indistinguishable from it being broken.
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
                n += 1
            } catch { continue }
        }
        return n
    }

    /// Returns how many files it placed. Silent on every failure, by §8f's rule: on a show day a
    /// file that cannot be copied must not produce a dialog, a toast or a retry.
    @discardableResult
    static func run() -> Int {
        guard AppPaths.hasRoot, let src = sourceDir else { return 0 }
        let fm = FileManager.default
        var placed = 0
        for rel in items {
            let to = AppPaths.root.appendingPathComponent(rel)
            guard !fm.fileExists(atPath: to.path) else { continue }
            let from = src.appendingPathComponent(rel)
            guard fm.fileExists(atPath: from.path) else { continue }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: to)
                placed += 1
            } catch {
                continue
            }
        }
        // `brand/logo.png` is one of `items` and `ShowLogo` memoises per process, so the run that
        // PLACES the logo has to be what drops the memo — otherwise the header keeps the "not
        // there" answer it cached before this folder existed, and the logo waits for a relaunch.
        //
        // In the callee, not at the two call sites, so a third caller cannot forget it — the same
        // reason `markTakenIn` lives in `Handoff.apply` rather than in `AppModel`'s import paths
        // (§8e). At the `AppModel.init` call site this is a no-op by construction: nothing has
        // read `prepared` yet, so there is no memo to drop.
        if placed > 0 { ShowLogo.invalidate() }
        return placed
    }
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

    /// The image AND the size to draw it at, resolved together. They have to be, because the
    /// bitmap is pre-scaled to exactly the pixels that size occupies — see `load`.
    struct Prepared { let image: NSImage; let size: CGSize }

    /// Memoised per process, **including the memo for "looked, and it is not there"** — §8f's
    /// cover-art lesson. `ContentView` is re-initialised on every model publish and the header
    /// re-renders at the player's tick rate, so a plain `load()` from `body` would `stat` and
    /// decode 50 times a second.
    ///
    /// It was a `static let`, and that was a bug on a machine with no library yet: `Seeding.run`
    /// is guarded on `AppPaths.hasRoot`, so on a FIRST run it copies nothing, the header then
    /// draws and memoises nil, and the logo the operator chose a folder for did not appear until
    /// the app was relaunched. Reported from the first install on a second machine. The outer
    /// optional is "has anyone looked yet", the inner one is the answer.
    nonisolated(unsafe) private static var cache: Prepared??
    static var prepared: Prepared? {
        if let answered = cache { return answered }
        let p = load()
        cache = .some(p)
        return p
    }

    /// Look again. Called from `Seeding.run` and nowhere else — see there for why it is the
    /// callee's job rather than each caller's.
    static func invalidate() { cache = nil }

    private static func load() -> Prepared? {
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
        guard art.width > 0, art.height > 0 else { return nil }

        let dw = min(maxWidth, height * CGFloat(art.width) / CGFloat(art.height))
        let pts = CGSize(width: max(1, dw), height: height)
        // **Resample ONCE, here, to the pixels this will actually occupy** — rather than handing
        // SwiftUI a 1024 px image and a 44 pt frame and letting it rescale on every draw.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pxW = max(1, Int((pts.width * scale).rounded()))
        let pxH = max(1, Int((pts.height * scale).rounded()))
        let small = resampled(art, pxW, pxH) ?? art
        return Prepared(image: NSImage(cgImage: small, size: pts), size: pts)
    }

    /// High-quality reduction.
    ///
    /// **For a big reduction this must average areas, not sample points.** The real logo is
    /// 1024x508 drawn at 44x22 on this 1x panel (§6d: 2560x1080 at ~81 PPI, `scale = 1.0`), so
    /// one output pixel covers **23 x 23 = 529** source pixels. `CGContext`'s `.high` samples a
    /// handful of them, which on artwork carrying a halftone dot pattern aliases the dots into
    /// a muddy mush — the reported "ภาพมันเละ". Averaging all 529 is what a camera does and
    /// what the result has to look like.
    ///
    /// Measured on the real file at 44x22, zoomed back 7x to inspect the actual pixels:
    ///
    /// | | |
    /// |---|---|
    /// | `CGContext` `.high`, one step | aliased, the upper text line breaks up — 0.7 ms |
    /// | successive halving | clean but soft — 1.6 ms |
    /// | Core Image Lanczos | ringing: purple specks inside the yellow — **82 ms** |
    /// | **exact area average** | **sharpest and cleanest — 1.3 ms** |
    ///
    /// Box averaging is only right when there IS an area to average, so it is used solely for
    /// reductions of 2x or more on both axes; below that each output pixel would claim one
    /// source pixel, which is nearest-neighbour and worse than the bilinear it replaced.
    /// Averaging happens in **premultiplied** space, so a transparent pixel contributes nothing
    /// but transparency rather than dragging its undefined colour into the result.
    private static func resampled(_ cg: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        if cg.width == w && cg.height == h { return cg }
        let sw = cg.width, sh = cg.height
        guard sw >= w * 2, sh >= h * 2 else {
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.interpolationQuality = .high
            c?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return c?.makeImage()
        }
        var srcPx = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let sc = CGContext(data: &srcPx, width: sw, height: sh, bitsPerComponent: 8,
                                 bytesPerRow: sw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        sc.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))

        var out = [UInt8](repeating: 0, count: w * h * 4)
        for oy in 0..<h {
            let y0 = oy * sh / h, y1 = max(y0 + 1, (oy + 1) * sh / h)
            for ox in 0..<w {
                let x0 = ox * sw / w, x1 = max(x0 + 1, (ox + 1) * sw / w)
                var r = 0, g = 0, b = 0, a = 0, n = 0
                for y in y0..<y1 {
                    let row = y * sw * 4
                    for x in x0..<x1 {
                        let i = row + x * 4
                        r += Int(srcPx[i]); g += Int(srcPx[i + 1])
                        b += Int(srcPx[i + 2]); a += Int(srcPx[i + 3]); n += 1
                    }
                }
                let o = (oy * w + ox) * 4
                out[o]     = UInt8(r / n)
                out[o + 1] = UInt8(g / n)
                out[o + 2] = UInt8(b / n)
                out[o + 3] = UInt8(a / n)
            }
        }
        return CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
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
    /// Narrow a list of paths to those carrying `tag`. An empty tag is the identity, which is
    /// what makes "no filter" need no branch at the call sites.
    ///
    /// A free function and not a method on `AppModel`, so `--filtertest` can exercise it without
    /// building an `AppModel` — which would run the launch snapshot and could let `guessRest`
    /// write to the operator's real config. Matching is on `Store.tagKey`, so a difference in
    /// Latin case never hides a song.
    static func visible(_ paths: [String], tag: String, search: String = "",
                        starred: Bool = false, store: Store) -> [String] {
        var out = paths
        // Still the ONE place the list narrows (§8g). A third way in is a third chance for the
        // handover, the pre-flight or the review sweep to be handed a view instead of the round.
        if starred { out = out.filter { store.config(for: $0).starred } }
        if !tag.isEmpty {
            let k = Store.tagKey(tag)
            out = out.filter { p in
                store.config(for: p).tags.contains { Store.tagKey($0) == k }
            }
        }
        if !search.isEmpty {
            let needle = searchTokens(search)
            if !needle.isEmpty { out = out.filter { matches($0, tokens: needle) } }
        }
        return out
    }

    /// Normalised form both sides of a search comparison are reduced to: NFC (Thai combining
    /// marks compare unequal otherwise — §8g's lesson for the note), lower-cased, and runs of
    /// whitespace collapsed to one.
    static func searchKey(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .localizedLowercase
    }

    static func searchTokens(_ s: String) -> [String] {
        searchKey(s).split(separator: " ").map(String.init)
    }

    /// Does this song's **raw filename** contain every token, in any order?
    ///
    /// The raw basename rather than `displayTitle`, and that is deliberate: `displayTitle` only
    /// ever REMOVES from the raw name (the leading track number, the trailing "[Official MV]"
    /// boilerplate), so the raw name is a superset of what is on screen — which makes typing the
    /// `101` you can see at the left of the column a search that works, and still finds anything
    /// you read off the row. The one thing `displayTitle` rewrites rather than removes is runs
    /// of whitespace, and `searchKey` collapses those on both sides.
    ///
    /// Tokens are ANDed and order-free, so "palmy ooh" finds `202_Ooh! - Palmy`. Thai carries no
    /// spaces, so the single-token substring case is the common one and costs one `contains`.
    static func matches(_ path: String, _ needle: String) -> Bool {
        let t = searchTokens(needle)
        return t.isEmpty || matches(path, tokens: t)
    }

    static func matches(_ path: String, tokens: [String]) -> Bool {
        let hay = searchKey(baseName(path))
        return tokens.allSatisfy { hay.contains($0) }
    }

    /// Display-only — nothing is stored per column.
    static let columnLabels = ["1xx", "2xx", "3xx + อื่นๆ"]
    /// What a FOLDED column's rail says (§8c). It has to fit `AppModel.collapsedColWidth`
    /// without rotating the text — measured at 12 pt bold through the real cascade, the widest
    /// of these is `3xx+` at **29.78 pt**, which is what sets that width. Rotation was the first
    /// idea and was dropped: `rotationEffect` is a visual transform only, so the layout box stays
    /// the UNROTATED width and a 70 pt label would have forced the rail open again.
    static let columnShort = ["1xx", "2xx", "3xx+"]
    static func column(of p: String) -> Int {
        switch baseName(p).first {
        case "1": return 0
        case "2": return 1
        default:  return 2
        }
    }
}

/// How the window divides into the three panes, as a pure function.
///
/// Asked for as *"อยากให้ขยับปรับขนาดได้คือ 3 column นี้: LIST เพลง | ส่วนกลาง | Right Tab"*, with
/// *"เครื่องส่วนใหย่จะเป็นหน้าจอแคบ"*.
///
/// **This supersedes §6c's refusal, which was explicit and was not wrong.** §6c rejected
/// `NavigationSplitView` partly because "a split view's divider is user-draggable by design —
/// which adds a way to resize the waveform mid-take by brushing the mouse", and §12's recurring
/// defect is a control that moves under the cursor. The owner asked for it directly, so the
/// question becomes how to carry that risk rather than whether to:
///
/// - **A brush is not a drag.** `DragGesture(minimumDistance: 4)` on the pane handles, double the
///   2 pt the in-list column edges use, because this is the divider §6c was afraid of.
/// - **Nothing can collapse.** Hard floors below, applied before any fraction is honoured, so no
///   pane can be squeezed to nothing and no drag can hide a pane the operator then cannot find.
/// - **The handle is a deliberate 8 pt target with a visible grip**, so a drag is something you
///   aim at rather than something that happens to you.
/// - **Nothing about audio depends on it.** Pane width changes the waveform's drawn width, which
///   `Analysis.columnPeaks` re-derives from the view window; the playhead is time-based. There is
///   no path from a pane width to what the audience hears.
enum PaneLayout {
    /// list · centre · setup. **Measured, not chosen.**
    ///
    /// - list 240: below it a row's 2-line clamped title plus the tag chips and the note line
    ///   stop telling two songs apart. Today's narrow layout gives the list 300.
    /// - centre 480: §12 records 378 as broken — a 330 px waveform with a wrapped transport row.
    ///   The transport needs 834 pt not to wrap at all (four fixed buttons at 200/210/190/150,
    ///   36 pt of spacing, 48 of pane padding), which the CURRENT wide layout does not give it
    ///   either: 660 at the 1900 breakpoint. Wrapping is the designed behaviour there — a
    ///   `FlowRow`, "wraps instead of compressing, because a squeezed button renders its label as
    ///   vertical text" — so the floor protects the waveform, not the row.
    /// - setup 300: the marker cards and their typed time fields. It is 340 by design.
    ///
    /// They sum to 1020, and with the two 8 pt handles that is 1036 against `App.swift`'s
    /// declared `minWidth: 1100` — 64 pt of surplus at the narrowest allowed window.
    static let floors: [CGFloat] = [240, 480, 300]
    static let count = 3

    /// The default split, as shares of the surplus above the floors.
    ///
    /// Chosen for roughly (420, 740, 340) at a 1500 pt window, because *most machines are narrow
    /// screens* — at 1440 that gives **391 / 699 / 334**, where today's narrow layout gives the
    /// list only 300 and this is the pane the request is about. At 1900 it gives 564 / 948 / 372.
    ///
    /// It deliberately does NOT reproduce the 900 pt list §8c asks for on a wide screen: one
    /// fraction set cannot be both, and the step function it replaces could. The 900 is one drag
    /// away and the split persists per machine, which is the trade.
    static let defaultFractions: [Double] = [0.375, 0.542, 0.083]

    static func normalised(_ f: [Double]?) -> [Double] {
        guard let f, f.count == count else { return defaultFractions }
        let clean = f.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let sum = clean.reduce(0, +)
        guard sum > 0 else { return defaultFractions }
        return clean.map { $0 / sum }
    }

    /// Floors first, surplus by fraction — the same shape as `ColumnLayout.widths` and for the
    /// same reason: scaling first and clamping after lets three clamped panes sum past the
    /// window, which in an `HStack` of fixed frames overflows silently.
    static func widths(fractions: [Double], total: CGFloat) -> [CGFloat] {
        let f = normalised(fractions)
        let floorSum = floors.reduce(0, +)
        guard total > floorSum else {
            // Below the declared minimum width, which AppKit should not allow. Share it out
            // rather than overflow.
            let k = max(0, total) / floorSum
            return floors.map { $0 * k }
        }
        let surplus = total - floorSum
        return (0..<count).map { floors[$0] + surplus * CGFloat(f[$0]) }
    }

    /// Drag the handle after pane `i`. Only the two adjacent panes change, so the third holds
    /// still. Inverted in SURPLUS space — see `ColumnLayout.drag` for the version of this that
    /// looked right and was wrong by 23 pt at +50.
    static func drag(after i: Int, dx: CGFloat, fractions: [Double], total: CGFloat) -> [Double]? {
        guard i >= 0, i < count - 1 else { return nil }
        let w = widths(fractions: fractions, total: total)
        let pair = w[i] + w[i + 1]
        guard pair - floors[i + 1] >= floors[i] else { return nil }
        let left = min(max(floors[i], w[i] + dx), pair - floors[i + 1])
        let floorSum = floors.reduce(0, +)
        let surplus = total - floorSum
        guard surplus > 0 else { return nil }
        var out = normalised(fractions)
        out[i] = Double((left - floors[i]) / surplus)
        out[i + 1] = Double((pair - left - floors[i + 1]) / surplus)
        return out
    }
}

/// How the three list columns divide the pane, as a pure function.
///
/// Asked for as *"อยากให้แบบลากตรงขอบเพื่อปรับขยายได้"*. Pure for the same reason
/// `ColumnFold.decide` is: a drag cannot be driven headlessly, so the arithmetic is what gets
/// proved and `--foldtest` does it.
///
/// **§6c's objection to a draggable divider does NOT apply here, and the distinction matters.**
/// That section refuses `NavigationSplitView` partly because its divider would let the operator
/// resize the WAVEFORM by brushing the mouse mid-take. These handles sit *inside* the left pane,
/// which stays a fixed `AppModel.leftPaneWidth`: dragging one moves the boundary between two
/// song columns and changes nothing in the centre pane. The waveform, the markers and the
/// transport cannot move.
enum ColumnLayout {
    /// Below this a 2-line clamped title plus a tag chip stops being readable, so a drag may not
    /// take a column under it however far the mouse goes.
    static let minWidth: CGFloat = 140

    /// Equal thirds — what a fresh session and a double-click on a handle both mean.
    static func evenFractions(_ n: Int) -> [Double] {
        n > 0 ? Array(repeating: 1.0 / Double(n), count: n) : []
    }

    /// Point widths per column. A folded column takes `railWidth` and drops out of the split;
    /// the expanded ones share what is left in proportion to `fractions`, each held at
    /// `minWidth`.
    ///
    /// The clamp is applied by giving every expanded column its minimum first and distributing
    /// only the SURPLUS by fraction. Scaling first and clamping after would let three clamped
    /// columns sum past the pane, which in an `HStack` of fixed frames silently overflows the
    /// pane and clips the third column's rows.
    static func widths(fractions: [Double], folded: Set<Int>, total: CGFloat,
                       railWidth: CGFloat, columns: Int) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let expanded = (0..<columns).filter { !folded.contains($0) }
        guard !expanded.isEmpty else {
            return (0..<columns).map { _ in railWidth }
        }
        let forRails = railWidth * CGFloat(columns - expanded.count)
        let pool = max(0, total - forRails)
        let floors = minWidth * CGFloat(expanded.count)
        var out = [CGFloat](repeating: railWidth, count: columns)
        guard pool > floors else {
            // Not enough room to honour every floor — share the pool evenly and let the floors
            // go rather than overflowing the pane. Only reachable in the narrow layout, which
            // does not use this.
            let each = pool / CGFloat(expanded.count)
            for i in expanded { out[i] = each }
            return out
        }
        let surplus = pool - floors
        let sum = expanded.reduce(0.0) { $0 + max(0, fractions.indices.contains($1) ? fractions[$1] : 0) }
        for i in expanded {
            let f = sum > 0 ? max(0, fractions.indices.contains(i) ? fractions[i] : 0) / sum
                            : 1.0 / Double(expanded.count)
            out[i] = minWidth + surplus * CGFloat(f)
        }
        return out
    }

    /// A handle exists between `i` and `i+1` only when BOTH are expanded. With the MIDDLE column
    /// folded the two expanded ones are not adjacent, so there is no handle — deliberately, since
    /// a handle whose two sides are not the things it sits between is worse than none.
    static func handleAfter(_ i: Int, folded: Set<Int>, columns: Int) -> Bool {
        i >= 0 && i < columns - 1 && !folded.contains(i) && !folded.contains(i + 1)
    }

    /// Drag the handle after column `i` by `dx` points. Returns the new fractions, or nil when
    /// there is nothing to drag.
    ///
    /// Only the two adjacent columns change, so the rest of the layout holds still — a drag that
    /// re-proportioned every column would move rows the operator is not touching.
    static func drag(after i: Int, dx: CGFloat, fractions: [Double], folded: Set<Int>,
                     total: CGFloat, railWidth: CGFloat, columns: Int) -> [Double]? {
        guard handleAfter(i, folded: folded, columns: columns) else { return nil }
        let w = widths(fractions: fractions, folded: folded, total: total,
                       railWidth: railWidth, columns: columns)
        guard w.indices.contains(i), w.indices.contains(i + 1) else { return nil }
        let pair = w[i] + w[i + 1]
        // Clamped to the pair, so neither side can be pushed under the floor and the pair's own
        // total never changes: every other column keeps the width it had.
        let left = min(max(minWidth, w[i] + dx), pair - minWidth)
        guard pair - minWidth >= minWidth else { return nil }
        var out = fractions.count == columns ? fractions : evenFractions(columns)
        // **Convert in SURPLUS space, not width space.** `widths` gives each expanded column
        // `minWidth + surplus * f`, so the floor is a constant offset and a fraction is NOT
        // proportional to a width. The first version of this rewrote both sides as their share
        // of the pair's width, which looks right and is wrong: dragging handle 0 by +50 pt
        // landed the column at 325.9 instead of 349.3 — an error that grows with `minWidth` and
        // would have shipped as "the divider does not keep up with the mouse".
        //
        // `f = (w - minWidth) / surplus` inverts it exactly, and the pair's combined f is
        // preserved by construction — `(left - min) + (pair - left - min) = pair - 2 * min`,
        // whatever `left` is — so every other column's width is untouched.
        let expanded = (0..<columns).filter { !folded.contains($0) }
        let pool = max(0, total - railWidth * CGFloat(columns - expanded.count))
        let surplus = pool - minWidth * CGFloat(expanded.count)
        guard surplus > 0 else { return nil }
        let scale = expanded.reduce(0.0) { $0 + max(0, out.indices.contains($1) ? out[$1] : 0) }
        guard scale > 0 else { return nil }
        // `widths` normalises by the sum over expanded columns, so the inverse has to carry that
        // same factor or one drag would silently rescale every other column.
        out[i] = Double((left - minWidth) / surplus) * scale
        out[i + 1] = Double((pair - left - minWidth) / surplus) * scale
        return out
    }
}

/// Whether a fold is allowed, as a pure function.
///
/// The house pattern for a decision no headless test can drive: `MarkerGrab.decide` for the
/// two-stage marker grab (§11) and `FocusRelease.shouldRelease` for click-outside (§8g). A click
/// on a column header cannot be synthesised — §6c forbids driving the running app with synthetic
/// keystrokes — so the *decision* is lifted out and `--foldtest` proves the table instead.
///
/// Both refusals are about work going missing on a show day, which is why they are refusals here
/// rather than conventions the UI is trusted to keep.
enum ColumnFold {
    enum Outcome: Equatable {
        /// Fold it.
        case fold
        /// Unfold it. Never refused: unfolding can only reveal.
        case unfold
        /// §8g's rule — the selection can never be hidden.
        case refuseHoldsSelection
        /// Folding every column leaves no list at all.
        case refuseLastExpanded
        /// Already in the asked-for state, or the index is not a column.
        case noop
    }

    static func decide(index: Int, collapsed: Bool, folded: Set<Int>,
                       selectionColumn: Int?, columns: Int) -> Outcome {
        guard columns > 0, (0..<columns).contains(index) else { return .noop }
        guard collapsed else { return folded.contains(index) ? .unfold : .noop }
        guard !folded.contains(index) else { return .noop }
        // Checked BEFORE the last-expanded rule, so the message names the reason the operator can
        // actually act on: moving the selection is a thing they can do, "a column must stay open"
        // is not something they can do anything about on a two-column-folded round.
        if selectionColumn == index { return .refuseHoldsSelection }
        if folded.count >= columns - 1 { return .refuseLastExpanded }
        return .fold
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
        guard let probe = paths.first else { Diagnostics.cannotRun("no songs"); return }
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
        guard plan.rows.count == 1, let row = plan.rows.first, row.field == .marker(.hook) else {
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
        guard let s = songs.first else { Diagnostics.cannotRun("no songs"); return }
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
        let overshoot = max(0, maxSeen - c.introEnd)
        print(String(format: "  mode=%@ playing=%@ stoppedAt=%@ maxReached=%.3f overshoot=%.3f",
                     "\(p.mode)", p.isPlaying ? "yes" : "no",
                     stopped.map { String(format: "%.3f", $0) } ?? "—",
                     maxSeen, overshoot))

        // Captured HERE, before the second phase reuses `stopped` — evaluating it after the
        // reset below read `nil` and failed a passing run.
        let stoppedInTime = stopped != nil && overshoot < 0.05

        // ignoreEnd must still bypass the guard
        c.ignoreEnd = true
        stopped = nil
        p.seek(to: 2, config: c)
        p.toggleStart(config: c)
        let d2 = Date().addingTimeInterval(9)
        while Date() < d2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let bypassed = p.position > 8
        print(String(format: "  ignoreEnd: pos=%.2f playing=%@ wentPast8=%@",
                     p.position, p.isPlaying ? "yes" : "no", bypassed ? "yes" : "no"))
        p.pause()

        // This suite printed three lines of facts and NO verdict, and CLAUDE.md §14 describes it
        // as "asserts playback stops AT introEnd (overshoot must be 0)" — it asserted nothing.
        // A human had to read `overshoot=0.000` and know what it should be, which is the
        // `--loudtest` lesson (§12) on the one check that covers §1's core requirement: playback
        // must not continue past `introEnd`.
        //
        // Both halves are required, and the second is the one that would otherwise rot quietly:
        // a guard that never releases would make `overshoot` 0 forever and look perfect, so
        // `ignoreEnd` having to go PAST the boundary is what proves the stop is a decision
        // rather than a wall.
        if !stoppedInTime { print("   ✗ ไม่หยุดที่ Intro End — ผิดข้อกำหนดหลัก (§1)") }
        if !bypassed { print("   ✗ ติ๊ก \"ข้าม Intro End\" แล้วยังหยุด — ตัวข้ามพัง") }
        Diagnostics.verdict(stoppedInTime && bypassed,
                            "\n✓ ผ่าน — หยุดตรง Intro End และ \"ข้าม\" ยังข้ามได้",
                            "\n✗ ไม่ผ่าน")
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

        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
        guard let s = songs.first else { Diagnostics.cannotRun("no songs"); return }
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
        Diagnostics.verdict(keptGoing && okIntro, "\n✓ ผ่าน", "\n✗ ไม่ผ่าน")
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
        Diagnostics.verdict(ok, "    ✓ ผ่าน\n", "    ✗ ไม่ผ่าน\n")
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
        guard let s = songs.first else { Diagnostics.cannotRun("no songs"); return }
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

        // 4) `Shift` + `←` HELD. `AppModel.nudgeStepCoarse` is 0.1 s a press against a ~30 ms
        //    autorepeat — ~3.3 s of marker movement per second of real time, which is fast enough
        //    to OVERTAKE the playhead. §11's old 0.01 s step could not, and leaned on that. The
        //    thing that actually protects this was never the step size: it is §10's rule that
        //    `remode` may only ARM the intro-end guard and never disarm it. This is the case that
        //    proves it at a speed the suite had never seen, and it steps HARDER than the real key
        //    (one press per 20 ms loop tick = 5 s/s).
        func slew(_ title: String, introEnd0: Double, from trigger: Double,
                  step: Double, mustStopBy: Double) {
            var c = SongConfig(); c.introStart = 2; c.introEnd = introEnd0; c.ignoreEnd = false
            p.configProvider = { c }
            var stopped: Double?
            var maxSeen = 0.0
            var presses = 0
            p.onAutoStop = { stopped = p.position }
            p.seek(to: c.introStart, config: c)
            p.toggleStart(config: c)
            let deadline = Date().addingTimeInterval(introEnd0 + 8)
            // `updateConfig`'s own floor, so the slew bottoms out where the real one would
            // instead of reaching a degenerate `introEnd <= introStart` the player never sees
            // from a real edit.
            let floor = c.introStart + 0.5
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if p.position > maxSeen { maxSeen = p.position }
                if stopped != nil { break }
                if p.position >= trigger, c.introEnd > floor {
                    c.introEnd = max(floor, ((c.introEnd - step) * 100).rounded() / 100)
                    presses += 1
                    // EXACTLY what `AppModel.nudgeFocused` does, and the reason this case is
                    // worth having: the nudge commits through a 350 ms debounce, and §12 records
                    // that a HELD key re-arms that debounce every ~30 ms so it never fires at
                    // all. `boundRunsOutEarly` is the only thing that can commit mid-hold. A
                    // test that called `remode` on every press instead would be testing a code
                    // path the app does not have — and would pass with §10's guard removed,
                    // which is how the first version of this case was written.
                    if p.boundRunsOutEarly(config: c) { p.remode(config: c) }
                }
            }
            let good = stopped != nil && maxSeen <= mustStopBy
            if !good { ok = false }
            print(String(format: "  %@", title))
            print(String(format: "     %d presses of %.2fs from ~%.1fs — introEnd %.2f -> %.2f",
                         presses, step, trigger, introEnd0, c.introEnd))
            print(String(format: "     stoppedAt=%@ maxReached=%.3f  must be <= %.2f  %@",
                         stopped.map { String(format: "%.3f", $0) } ?? "— NEVER STOPPED",
                         maxSeen, mustStopBy, good ? "ok" : "✗ FAIL"))
            print(String(format: "     mode=%@ playing=%@", "\(p.mode)", p.isPlaying ? "yes" : "no"))
            p.pause()
        }
        // What this case actually pins, which is NOT what case 1 pins. `boundRunsOutEarly` only
        // answers true when the bound moved OUTWARD, so a held `Shift+←` calls `remode` zero
        // times — measured. Nothing re-schedules the node, which stays bounded at the original
        // 20 s, and what stops the audio is the guard timer in `tick()`: it reads
        // `configProvider()` live every 20 ms and fades at `introEnd - fadeSec` with no reference
        // to the scheduled end. So the marker and the playhead close at 5 s/s + 1 s/s and meet at
        // ~6.7 s; the fade and the timer's granularity put the stop at ~7.5.
        //
        // `mustStopBy` is therefore set to fail loudly if the audio ran on to the OLD bound —
        // which is the dropout §12 calls indistinguishable from a hang — while leaving room
        // around the real figure. "It stopped eventually" is not the claim.
        slew("hold Shift+← on Intro End, straight through the playhead",
             introEnd0: 20, from: 4, step: AppModel.nudgeStepCoarse, mustStopBy: 9.0)

        Diagnostics.verdict(ok, "\n✓ ผ่าน — แก้ marker ตอนเล่นอยู่ ไม่ทำให้เล่นเลย Intro End", "\n✗ ไม่ผ่าน — มีกรณีที่เล่นเลย Intro End")
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
        Diagnostics.verdict(ok, "\n✓ ผ่าน", "\n✗ ไม่ผ่าน")
    }

    /// The whole in-app update chain except the final swap: fetch the manifest, download (or
    /// copy) the zip, unpack it, and prove the app inside reports the version the manifest
    /// promised. The swap itself is covered by `swap-test.sh`, which can test it without
    /// quitting anything.
    ///
    /// Read-only with respect to the project: everything lands in a temp dir and is deleted.
    /// Point `_settings.updateFeed` at a folder holding a real `manifest.json` + zip to run it.
    static func updateStage() {
        print("this build: \(AppVersion.full)")
        print("macOS:      \(UpdateInfo.runningOS)")
        // `--feed <path|owner/repo>` overrides `_settings.updateFeed` for this run only.
        //
        // It exists because testing the staging chain otherwise means EDITING the operator's own
        // config.json — and the one thing this diagnostic is for is the update path, which is
        // exactly where a stray write to their settings would be hardest to notice. It also makes
        // the chain testable at all: staging requires a feed offering a version HIGHER than the
        // running build, which the real feed never does right after a release.
        var feed = Store().updateFeed
        if let i = CommandLine.arguments.firstIndex(of: "--feed"),
           CommandLine.arguments.count > i + 1 {
            feed = CommandLine.arguments[i + 1]
            print("feed override: ใช้ --feed แทนค่าใน config.json")
        }
        guard !feed.isEmpty else {
            print("\nยังไม่ได้ตั้ง _settings.updateFeed — ไม่มีอะไรให้ทดสอบ")
            print("ตั้งเป็น path ของโฟลเดอร์ที่มี manifest.json + zip แล้วรันอีกครั้ง")
            print("หรือรัน: --updatestage --feed <path ของโฟลเดอร์ หรือ owner/repo>")
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
                // The zip holds the bundle and nothing else now — the installer, `server.py`,
                // `index.html` and `VERSION` all moved inside it (§5d). Spelled through
                // `Install.bundleName` and `Updater.swapHelper`, never as literals: this loop
                // IS the proof that the Swift copies still agree with a real release, and §12
                // records it once hardcoding the pre-1.3.0 bundle name and therefore proving
                // the opposite — a check that names its subject literally is not checking the
                // thing it claims to.
                let staged_app = staged.appendingPathComponent(Updater.Install.bundleName)
                //
                // This list went stale the moment the web fallback was unshipped: it still named
                // `Resources/web/server.py`, so a perfectly good 1.5.1 zip reported `✗ ไม่ผ่าน`.
                // §12's lesson in the mirror — a check that spells its subject literally stops
                // covering the subject that ARRIVES later, and keeps asserting the one that LEFT.
                // Driven off `Seeding.scripts` now, so adding or removing a seeded file moves
                // this with it.
                var want = [Updater.Install.bundleName,
                            "\(Updater.Install.bundleName)/\(Updater.swapHelper)"]
                want += Seeding.scripts.map {
                    "\(Updater.Install.bundleName)/Contents/Resources/scripts/\($0)"
                }
                for f in want {
                    let there = fm.fileExists(atPath: staged.appendingPathComponent(f).path)
                    print("  \(there ? "ok  " : "✗   ")\(f)")
                    if !there { ok = false }
                }
                print("  ✓ แอปที่แตกออกมาตอบเวอร์ชั่น \(info.version) ตรงกับ manifest")
                print("\nถ้ากดอัปเดตจริง จะเรียก:")
                print("  bash \(staged_app.appendingPathComponent(Updater.swapHelper).path) \\")
                print("    --target \(Bundle.main.bundleURL.path) \\")
                print("    --source \(staged_app.path) \\")
                print("    --expect \(info.version) --wait-pid <pid> --relaunch")
            } catch {
                ok = false
                print("\n✗ \(error.localizedDescription)")
            }
        }
        if sem.wait(timeout: .now() + 960) == .timedOut {
            ok = false
            print("\n✗ ค้าง ไม่เสร็จในเวลา")
        }
        Diagnostics.verdict(ok, "\n✓ ผ่าน", "\n✗ ไม่ผ่าน")
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
        Diagnostics.verdict(ok, "\n✓ ผ่าน", "\n✗ ไม่ผ่าน")
    }

    /// The overview strip's peaks. Two things to prove: it agrees with the zoomed-out column peaks,
    /// and interleaving the two does NOT evict either cache — sharing one would re-walk the whole
    /// envelope twice per frame, which is the exact cost the column cache exists to avoid.
    static func overviewTest() {
        let songs = Library.scan()
        guard let s = songs.first, let a = try? Analysis.analyse(url: Library.url(s)) else {
            Diagnostics.cannotRun("no songs / decode failed"); return
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
        Diagnostics.verdict(ok, "\n✓ ผ่าน — ข้อมูลตรงกัน และไม่กวนแคชกันเอง",
                            "\n✗ ไม่ผ่าน" + (maxDiff >= 0.0001 ? " — ข้อมูลไม่ตรงกัน" : " — แคชตีกัน"))
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
        guard let song = m.songsIn(m.currentPlaylist).first else { Diagnostics.cannotRun("no songs"); return }
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
        Diagnostics.verdict(ok, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
        Diagnostics.verdict(ok, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
        Diagnostics.verdict(bad == 0, "\n✓ ผ่าน", "\n✗ ไม่ผ่าน")
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
        guard let song = m.songsIn(m.currentPlaylist).first else { Diagnostics.cannotRun("no songs"); return }
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
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
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
            // EVERY channel, because the gain is applied to all of them. `an.peak` is channel 0
            // — right for drawing the waveform, wrong here, and it is what `applyGain` was
            // changed away from for this exact reason (§7a3). Keeping the old call in the test
            // made the suite under-report headroom by 1.41 dB on song 106, i.e. it compared two
            // slightly different things, which §7a3 itself calls worse than not comparing.
            let pk = Double(an.peakAllChannels(lo, hi))
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

        // Reveal puts the HOOK on air, and a pop master's loudest 15 seconds is its chorus. So
        // this measures Reveal's own window, and asserts the two things that were measurably
        // wrong when Reveal inherited the intro's gain: the reveals must land ON target, and the
        // limiter must not be eating them. Before `Analysis.revealLufs` existed the real library
        // gave a 15.21 LU spread here (sd 5.02) against 9.93 untouched — i.e. levelling the
        // intro made the on-camera moment LESS even than doing nothing — with song 107 at
        // +0.86 LUFS, 15.9 LU over target, and 10.78 dB of claw-back.
        print("\n6) ระดับตอน Reveal (วัดจากช่วง hook เอง)")
        print(String(format: "   %-26@ %9@ %8@ %8@ %7@ %7@",
                     "song" as NSString, "hook LUFS" as NSString, "gain" as NSString,
                     "on-air" as NSString, "peak" as NSString, "eats" as NSString))
        var airs: [Double] = []
        var revealSquashed = 0
        var worstOffTarget = 0.0
        for s in songs {
            guard let an = try? Analysis.analyse(url: Library.url(s)) else { continue }
            let c = store.config(for: s)
            let r = an.revealLufs(config: c, scope: scope)
            guard r.lufs.isFinite else { continue }
            let g = min(max(Analysis.revealTargetLufs - r.lufs, -12), 12) + c.trimDb
            let (h0, h1) = an.revealRange(config: c)
            let pk = Double(h1 > h0 ? an.peakAllChannels(h0, h1) : 0)
            let pkDb = pk > 0 ? 20 * log10(pk) : -.infinity
            let head = Player.limiterCeilingDb - pkDb
            let eats = head.isFinite ? max(0, g - head) : 0
            let air = r.lufs + g
            airs.append(air)
            if eats > 1 { revealSquashed += 1 }
            // Only songs the clamp did not bite can be expected to land on target.
            if abs(g - c.trimDb) < 11.9 {
                worstOffTarget = max(worstOffTarget, abs(air - Analysis.revealTargetLufs - c.trimDb))
            }
            print(String(format: "   %-26@ %9.2f %+8.2f %8.2f %7.1f %7.2f",
                         String(Library.baseName(s).prefix(26)) as NSString,
                         r.lufs, g, air, pkDb, eats))
        }
        if airs.isEmpty { print("   ไม่มีเพลงที่วัดได้") } else {
            let spread = (airs.max() ?? 0) - (airs.min() ?? 0)
            print(String(format: "   กว้าง %.2f LU · ห่างเป้ามากสุด %.2f LU · ลิมิตเตอร์กินคืน >1 dB %d เพลง",
                         spread, worstOffTarget, revealSquashed))
            assertThat(worstOffTarget <= 0.01)
            print(worstOffTarget <= 0.01
                  ? "   ok  เพลงที่ไม่ติด clamp ต้องลงตรงเป้าทุกเพลง"
                  : "   ✗   เฉลยไม่ลงเป้า — gain ของ Reveal ไม่ได้วัดจาก hook")
            assertThat(revealSquashed == 0)
            print(revealSquashed == 0
                  ? "   ok  ไม่มีเพลงไหนที่ท่อนเฉลยชนลิมิตเตอร์"
                  : "   ✗   ยังมีเฉลยที่โดนบี้ \(revealSquashed) เพลง")
        }

        // Reveal must not have quietly changed what the INTRO plays at. Same graph, two figures.
        print("\n7) เปิด/ปิดการเกลี่ย — ค่าที่ใช้จริงต้องมาจากโหมดที่กำลังเล่น")
        let p = Player()
        if let first = songs.first, let an = try? Analysis.analyse(url: Library.url(first)) {
            let c = store.config(for: first)
            let on = p.applyGain(analysis: an, config: c, normalize: true, scope: .intro)
            let off = p.applyGain(analysis: an, config: c, normalize: false, scope: .intro)
            assertThat(abs(off.db - c.trimDb) < 1e-9 && abs(off.revealDb - c.trimDb) < 1e-9)
            print(String(format: "   %@ ปิดเกลี่ย: intro %+.2f  เฉลย %+.2f  (ต้องเท่ากับ trim %+.2f)",
                         (abs(off.db - c.trimDb) < 1e-9 && abs(off.revealDb - c.trimDb) < 1e-9
                          ? "ok " : "✗  ") as NSString, off.db, off.revealDb, c.trimDb))
            print(String(format: "       เปิดเกลี่ย: intro %+.2f  เฉลย %+.2f", on.db, on.revealDb))
        }

        print("\nผ่าน \(pass)  ตก \(fail)")
        // The compiler used to emit `warning: will never be executed` on the `✗` branch here,
        // with `note: condition always evaluates to true`. It was WRONG — proved by inserting
        // one failing assertion that cannot be constant-folded, which printed `ผ่าน 9  ตก 1` and
        // `✗ ไม่ผ่าน`. The false positive came from the mandatory pass not seeing `assertThat`'s
        // `fail += 1` as an assignment to the captured var.
        //
        // The warning is GONE now, and not because anything about the condition changed: routing
        // the verdict through `Diagnostics.verdict` means the strings are arguments rather than
        // operands of a ternary inside `print`, so there is no branch left for the optimiser to
        // fold away. Kept on record because the next person to see that warning somewhere else
        // in this file should know it has already been investigated once and was a lie.
        //
        // What DID make this suite look like it always passed is unrelated and was real: for a
        // library containing an unreadable file, `Loudness.measure` died on an uncatchable
        // Obj-C exception (see `Loudness.measure`) and the process never reached these two
        // lines at all. A suite that cannot print its own verdict reads exactly like a suite
        // that passed.
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    // MARK: - the setter's note

    /// `SongConfig.note` — the sentence the setter writes for the operator to read as they open
    /// the question (§9).
    ///
    /// **READ-ONLY.** Every `Store` here is built with `init(rawForTest:)`, which cannot write;
    /// that is what lets this exercise `set`'s delete guards and `Handoff.apply` (which ends in
    /// `saveNow()`) against controlled values instead of the operator's real file.
    static func noteTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }

        // 1 ------------------------------------------------------------------ clampNote
        print("1) clampNote — สิ่งที่โน้ตต้องทนตอนเข้ามา")
        let long = String(repeating: "ก", count: Store.noteMax + 40)
        let cases: [(String, String, String)] = [
            ("ข้อความธรรมดา", "ฝั่งซ้ายน่าจะได้เปรียบ", "ฝั่งซ้ายน่าจะได้เปรียบ"),
            ("ตัดช่องหน้าหลัง", "   ยุค 90   ", "ยุค 90"),
            ("\\n → เว้นวรรค", "a\nb", "a b"),
            ("\\r\\n → ช่องเดียว ไม่ใช่สอง", "a\r\nb", "a b"),
            ("\\t → เว้นวรรค", "a\tb", "a b"),
            ("U+2028 → เว้นวรรค", "a\u{2028}b", "a b"),
            ("ว่างเปล่า", "", ""),
            ("มีแต่ช่องว่าง", "  \n\t  ", ""),
            ("ยาวเกิน → ตัดที่ \(Store.noteMax)", long, String(repeating: "ก", count: Store.noteMax)),
        ]
        for (label, input, want) in cases {
            let got = Store.clampNote(input)
            check(label, got == want, got.isEmpty ? "\"\"" : got.debugDescription)
            check("  ^ เข้า JSON ได้",
                  JSONSerialization.isValidJSONObject(["note": got]))
        }
        // The cap counts grapheme clusters, which is the unit the operator sees. §8f records
        // the same fact for the cover-art token floor: Thai above-marks fold into their base.
        let cluster = "ขี้แง"
        check("วรรณยุกต์ไทยรวมกับพยัญชนะ — \(cluster) นับเป็น 3 ตัว",
              cluster.count == 3, "\(cluster.count)")
        // NFC on the way in, or two visually identical strings compare unequal and the handover
        // diff offers a row where nothing changed.
        let decomposed = "e\u{301}clair"
        check("NFC — ตัวประกอบรวมเป็นตัวเดียว",
              Store.clampNote(decomposed) == "\u{e9}clair"
                  && Store.clampNote(decomposed).count == 6,
              "\(decomposed.count) → \(Store.clampNote(decomposed).count) ตัว")

        // 2 -------------------------------------------------------- it is not a marker
        print("\n2) โน้ตไม่ใช่ marker — ห้ามพาเพลงหลุดจากรอบตรวจ")
        check("ค่าเริ่มต้นว่าง", SongConfig().note.isEmpty)
        var guessed = SongConfig()
        guessed.auto = true                      // the app guessed this one; still needs a human
        guessed.note = "คนรุ่น 40+ รู้แน่"
        check("เขียนโน้ตแล้ว isConfigured ยัง false", !guessed.isConfigured)
        check("เขียนโน้ตแล้ว auto ยัง true", guessed.auto)
        var signed = SongConfig()
        signed.configured = true
        signed.base = signed.current
        signed.note = "แก้ทีหลัง"
        check("โน้ตไม่ขึ้นป้าย แก้ที่กอง (onsiteEdits ว่าง)", signed.onsiteEdits.isEmpty)

        // 3 ---------------------------------------------- the raw merge and its delete guard
        print("\n3) merge เข้า raw — คือสิ่งที่เคยลบ resetAt หายไปทั้งไฟล์")
        let key = "EP00/x.mp3"
        let st = Store(rawForTest: [
            key: ["introStart": 3.0, "introEnd": 18.0, "hook": 61.0,
                  "note": "เดิม", "somethingNewerBuildsWrite": ["a", "b"]],
        ])
        check("อ่าน note จากไฟล์ได้", st.config(for: key).note == "เดิม")
        var c3 = st.config(for: key)
        c3.note = "ใหม่"
        st.set(c3, for: key)
        let d3 = st.raw[key] as? [String: Any] ?? [:]
        check("เขียนทับแล้วอ่านกลับมาเหมือนเดิม", (d3["note"] as? String) == "ใหม่")
        check("คีย์ที่ build อื่นเขียนยังรอด", d3["somethingNewerBuildsWrite"] != nil)
        c3.note = ""
        st.set(c3, for: key)
        check("ลบโน้ต → คีย์หายจากไฟล์",
              (st.raw[key] as? [String: Any])?["note"] == nil)
        // The guard that matters: a note this build cannot READ must not be deleted. `set` runs
        // on every marker edit, so an unguarded removeValue would wipe it on the first drag.
        let weird = Store(rawForTest: [key: ["introStart": 0.0, "introEnd": 15.0,
                                             "note": ["บรรทัด 1", "บรรทัด 2"]]])
        check("note ที่ไม่ใช่ String → อ่านเป็นว่าง", weird.config(for: key).note.isEmpty)
        var w = weird.config(for: key)
        w.introStart = 1.0                        // an ordinary marker edit
        weird.set(w, for: key)
        check("แก้ marker แล้ว note ของ build อื่นยังอยู่",
              (weird.raw[key] as? [String: Any])?["note"] is [Any])

        // 4 --------------------------------------------------- round.json, additive merge
        print("\n4) การส่งต่อ — ว่างที่เข้ามา = ไม่มีความเห็น ไม่ใช่ ลบ")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notetest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        /// local note, incoming note, expected row?, value if accepted, value if rejected
        let table: [(String, String, Bool, String, String)] = [
            ("",  "",  false, "",  ""),
            ("",  "X", true,  "X", ""),
            ("Y", "",  false, "Y", "Y"),      // ← the load-bearing row
            ("Y", "Y", false, "Y", "Y"),
            ("Y", "Z", true,  "Z", "Y"),
        ]
        for (mine, theirs, wantRow, ifYes, ifNo) in table {
            let label = "เครื่องนี้ \(mine.isEmpty ? "—" : mine)  รับมา \(theirs.isEmpty ? "—" : theirs)"
            for accept in [true, false] {
                let s = Store(rawForTest: [key: ["introStart": 0.0, "introEnd": 15.0,
                                                 "configured": true, "played": true,
                                                 "note": mine]])
                var pkg = RoundPackage()
                pkg.round = "EP00"
                var e = RoundPackage.Entry()
                e.b = s.config(for: key).current
                e.note = theirs
                pkg.songs[Library.baseName(key)] = e
                guard (try? pkg.write(to: tmp)) != nil,
                      let reread = RoundPackage.read(tmp) else {
                    check(label + " (เขียน/อ่าน round.json)", false); continue
                }
                let plan = Handoff.plan(reread, round: "EP00", paths: [key], store: s)
                let noteRows = plan.rows.filter { $0.field == .note }
                if accept {
                    check(label + " → ขึ้นแถวให้เลือก \(wantRow ? "ใช่" : "ไม่")",
                          noteRows.count == (wantRow ? 1 : 0), "แถว \(noteRows.count)")
                }
                Handoff.apply(plan, accepted: accept ? Set(plan.rows.map(\.id)) : [], store: s)
                let got = s.config(for: key)
                check("   └ \(accept ? "รับ" : "ไม่รับ") → \(got.note.isEmpty ? "—" : got.note)",
                      got.note == (accept ? ifYes : ifNo),
                      "ควรเป็น \((accept ? ifYes : ifNo).isEmpty ? "—" : (accept ? ifYes : ifNo))")
                check("   └ ไม่แตะ played", got.played)
            }
        }

        // A song the receiving side has never seen takes the sender's note with no question,
        // exactly like its markers.
        do {
            let s = Store(rawForTest: [:])
            var pkg = RoundPackage()
            var e = RoundPackage.Entry()
            e.b = SongBase(introStart: 2, introEnd: 20, hook: 70, trimDb: 0, ignoreEnd: false)
            e.note = "เพลงใหม่ ยังไม่เคยมี"
            pkg.songs[Library.baseName(key)] = e
            let plan = Handoff.plan(pkg, round: "EP00", paths: [key], store: s)
            Handoff.apply(plan, accepted: [], store: s)
            check("เพลงใหม่ (fresh) รับโน้ตมาเลยโดยไม่ต้องติ้ก",
                  s.config(for: key).note == e.note, s.config(for: key).note)
        }

        // A hand-edited round.json goes through the same clamp as everything else.
        do {
            let dirty = "a\nb" + String(repeating: "ก", count: Store.noteMax)
            var pkg = RoundPackage()
            var e = RoundPackage.Entry(); e.b = SongBase(); e.note = dirty
            pkg.songs["x.mp3"] = e
            try? pkg.write(to: tmp)
            let back = RoundPackage.read(tmp)?.songs["x.mp3"]?.note ?? "#"
            check("round.json ที่แก้มือ → ผ่าน clampNote",
                  back == Store.clampNote(dirty) && back.count <= Store.noteMax,
                  "\(back.count) ตัว")
        }

        // 5 ----------------------------------------------------------- the layout claim
        print("\n5) ความกว้างจริง — cap กับกล่องในแถบกลาง")
        // 520 pt box, 10 pt padding each side, 3 pt edge bar.
        let avail: CGFloat = 520 - 10 - 10 - 3
        let f = Typo.nsFont(13)
        func lines(_ s: String) -> (CGFloat, Double) {
            let w = NSAttributedString(string: s, attributes: [.font: f]).size().width
            return (w, Double((w / avail).rounded(.up)))
        }
        let thai = String(("ฝั่งซ้ายน่าจะได้เปรียบ ดังมากยุค 90 คนรุ่น 40+ รู้แน่ เข้าเรื่องช้าหน่อยรอห้อง "
            + "ห้องเรียนสมัยม.ต้น ถ้าไม่มีใครตอบเก็บไว้เล่นท้าย").prefix(Store.noteMax))
        let padded = thai + String(repeating: "ก", count: max(0, Store.noteMax - thai.count))
        let (tw, tl) = lines(padded)
        check("ไทยยาวเต็ม cap (\(padded.count) ตัว) พอดี 2 บรรทัด", tl <= 2,
              String(format: "%.0f pt / %.0f pt → %.0f บรรทัด", tw, avail, tl))
        // And the honest other half: the cap is NOT what bounds the height. 120 Latin capitals
        // are far wider than 120 Thai clusters, so `.lineLimit(2)` is the guarantee and this
        // number is the reason it has to stay.
        let (ww, wl) = lines(String(repeating: "W", count: Store.noteMax))
        print(String(format: "   (กรณีเลวร้ายสุด: W x%d = %.0f pt → %.0f บรรทัด"
                     + " — .lineLimit(2) คือสิ่งที่คุมความสูง ไม่ใช่ cap)",
                     Store.noteMax, ww, wl))
        // Two 13 pt lines plus the box's 7 pt padding, against the 52 pt the row already has.
        let boxH = 2 * f.ascender - 2 * f.descender + 14
        check("กล่อง 2 บรรทัด เตี้ยกว่ากรอปก 52 pt — ไม่เพิ่มความสูงแถบกลาง",
              boxH <= 52, String(format: "%.1f pt", boxH))

        // 6 ------------------------------------------------- the song list's ※ (§8g)
        print("\n6) เครื่องหมาย ※ ในรายการเพลง — วัด ไม่ใช่เลือกด้วยตา")
        let slotW: CGFloat = 9                 // SongRow's reserved .frame(width:)
        let markF = Typo.nsFont(10)            // = Typo.font(10), i.e. clamped to thaiFloor
        func markWidth(_ str: String) -> CGFloat {
            NSAttributedString(string: str, attributes: [.font: markF]).size().width
        }
        // A missing glyph renders as .notdef, which HAS a width — so the width check below
        // cannot stand in for this one.
        //
        // Two wrong ways to ask this, both of which looked right:
        //
        // 1. `CTFontGetGlyphsForCharacters` queries the BASE font only and knows nothing about
        //    fallback, so it reports `※` as absent — true of SF and irrelevant, because §6d's
        //    whole mechanism is that CoreText falls through (to HelveticaNeue here, exactly as
        //    `ก` falls through to SukhumvitSet).
        // 2. Testing the laid-out line for glyph 0 **can never fail.** CoreText's `LastResort`
        //    font supplies a glyph for every codepoint in Unicode, assigned or not — U+E000
        //    comes back as glyph 4 at 13.20 pt. The negative control below is what found that;
        //    without it this check would have passed while reaching nothing (§6d, Palette.audit).
        //
        // So the discriminator is the run's FONT: landing in LastResort *is* the placeholder box.
        func glyphPresent(_ str: String) -> Bool {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: str, attributes: [.font: markF]))
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
            for r in runs {
                let attrs = CTRunGetAttributes(r) as NSDictionary
                guard let any = attrs[kCTFontAttributeName as String] else { return false }
                let name = CTFontCopyPostScriptName(any as! CTFont) as String
                if name.localizedCaseInsensitiveContains("LastResort") { return false }
            }
            return true
        }
        check("※ มีกลิฟจริงในสิ่งที่วาดออกมา (ผ่าน fallback ได้)", glyphPresent("※"))
        // Negative control, so the line above cannot pass by being unable to fail — the
        // Palette.audit lesson (§6d): a check whose subject it does not actually reach reads
        // exactly like a check that passed. U+E000 is private use; nothing assigns it.
        check("...และตอบ \"ไม่มี\" ได้จริง — คุมด้วยอักขระที่ไม่มีในฟอนต์ไหนเลย",
              !glyphPresent("\u{E000}"))
        check("※ กว้างไม่เกินช่อง \(Int(slotW)) pt",
              markWidth("※") <= slotW,
              String(format: "%.2f pt @ %.0f pt", markWidth("※"), markF.pointSize))
        // Recorded because it is true, it predates this feature, and nobody would guess it:
        // the glyph ※ sits beside does not fit its own slot.
        print(String(format: "   (✎ ข้างกันกว้าง %.2f pt — ล้นช่อง %d pt ของตัวเองอยู่แล้ว)",
                     markWidth("✎"), Int(slotW)))

        // The rule the glyph stands for. If absence ever stops meaning "no note" the mark is
        // worthless, so a song with tags and nothing written must NOT be marked.
        let storeM = Store(rawForTest: [
            "EP/a.mp3": ["note": "ฝั่งซ้ายน่าจะได้เปรียบ"],
            "EP/b.mp3": ["tags": ["ยุค 90"]],
            "EP/c.mp3": ["introStart": 3.0],
        ])
        check("มีโน้ต → ติด ※", !storeM.config(for: "EP/a.mp3").note.isEmpty)
        check("มีแต่แท็ก → ไม่ติด ※", storeM.config(for: "EP/b.mp3").note.isEmpty)
        check("ไม่มีทั้งสอง → ไม่ติด ※", storeM.config(for: "EP/c.mp3").note.isEmpty)
        // ...but the tooltip is note AND tags, because a hover is asked for.
        check("แท็กล้วน → ไม่มีกลิฟ แต่ทูลทิปยังเห็น",
              CenterView.plainNoteText(storeM.config(for: "EP/b.mp3")) == "ยุค 90")

        print("\nผ่าน \(pass)  ตก \(fail)")
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    // MARK: - the tag filter

    /// `Library.visible` and the contract around it (§8g).
    ///
    /// **READ-ONLY**, via `Store(rawForTest:)`.
    ///
    /// What this proves: the filter narrows, an empty tag is the identity, Latin case never
    /// hides a song, the counts the strip prints add up, and — the one that matters — that
    /// `Handoff.package` and `Preflight.fast` still cover a song the filter hides, because they
    /// are handed the ROUND and not the view.
    ///
    /// **What it does NOT prove** is that the UI calls the right accessor; no headless check can,
    /// and building an `AppModel` here would run the launch snapshot and let `guessRest` write to
    /// the operator's real config. That half is protected by construction instead: the unfiltered
    /// column accessor was DELETED rather than kept beside the filtered one, so handing a
    /// narrowed list to the handover now means typing `visibleSongs` somewhere it does not
    /// belong — a visible mistake instead of an invisible one.
    /// Where the questions live (§5, the DMG work). Read-only: it builds fixtures in the system
    /// temp dir and deletes them, and it NEVER touches `UserDefaults` or the breadcrumb — the
    /// resolver takes its three inputs as parameters precisely so this does not have to.
    static func rootTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }
        let fm = FileManager.default
        let box = fm.temporaryDirectory.appendingPathComponent("rgf-roottest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: box) }
        func make(_ name: String, _ build: (URL) -> Void) -> URL {
            let u = box.appendingPathComponent(name)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            build(u)
            return u
        }
        func touch(_ u: URL, _ n: String) {
            fm.createFile(atPath: u.appendingPathComponent(n).path, contents: Data("x".utf8))
        }
        func dir(_ u: URL, _ n: String) {
            try? fm.createDirectory(at: u.appendingPathComponent(n), withIntermediateDirectories: true)
        }

        print("1) อะไรนับว่าเป็นโฟลเดอร์งาน (hasLibraryMarkers)")
        let withSongs = make("withSongs") { dir($0, "songs") }
        let withCfg = make("withCfg") { touch($0, "config.json") }
        let both = make("both") { dir($0, "songs"); touch($0, "config.json") }
        let empty = make("empty") { _ in }
        // `songs` as a FILE, not a directory. A bare existence check would pass this and the app
        // would then adopt a folder it cannot scan.
        let songsIsFile = make("songsIsFile") { touch($0, "songs") }
        let release = make("release") { dir($0, "songs"); touch($0, "ติดตั้ง-อัปเดต.command") }
        let readme = make("readme") { touch($0, "config.json"); touch($0, "อ่านก่อน.txt") }
        check("มี songs/ → ใช่", AppPaths.hasLibraryMarkers(withSongs))
        check("มี config.json → ใช่", AppPaths.hasLibraryMarkers(withCfg))
        check("มีทั้งคู่ → ใช่", AppPaths.hasLibraryMarkers(both))
        check("ว่างเปล่า → ไม่ใช่", !AppPaths.hasLibraryMarkers(empty))
        check("songs เป็นไฟล์ ไม่ใช่โฟลเดอร์ → ไม่ใช่", !AppPaths.hasLibraryMarkers(songsIsFile))
        // §15: launching out of an unzipped release is a natural thing to do and must not be
        // mistaken for an install, or the breadcrumb and the resolver both point at a download.
        check("โฟลเดอร์ที่แตก zip (มี ติดตั้ง-อัปเดต.command) → ไม่ใช่",
              !AppPaths.hasLibraryMarkers(release))
        check("โฟลเดอร์ที่แตก zip (มี อ่านก่อน.txt) → ไม่ใช่", !AppPaths.hasLibraryMarkers(readme))

        print("\n2) ข้อห้าม — ที่ที่ห้ามใช้เป็นโฟลเดอร์งาน")
        check("โฟลเดอร์ temp ถูกตัด", AppPaths.isTransient("/private/var/folders/x/y/T/a"))
        check("/tmp ถูกตัด", AppPaths.isTransient("/tmp/work"))
        check("/Volumes ถูกตัด", AppPaths.isTransient("/Volumes/USB/งาน"))
        check("โฟลเดอร์ปกติไม่ถูกตัด", !AppPaths.isTransient("/Users/x/Documents/IntroPlayer"))
        // The Dock follows the old bundle into `backups/` after an update (§15), and that folder
        // has a config.json the installer copied in and no songs/.
        check("ใน backups/ ถูกตัด", AppPaths.inBackups("/Users/x/IntroPlayer/backups/2026-01-01"))
        check("ชื่อมีคำว่า backups แต่ไม่ใช่โฟลเดอร์นั้น ไม่ถูกตัด",
              !AppPaths.inBackups("/Users/x/my-backups-notes"))
        // The exclusions have to beat the marks, not the other way round: the temp fixtures above
        // all HAVE the marks, so if the order were wrong every one of them would qualify.
        check("ข้อห้ามชนะเครื่องหมาย (fixture ใน temp มี songs/ แต่ใช้ไม่ได้)",
              AppPaths.hasLibraryMarkers(both) && !AppPaths.looksLikeLibrary(both))
        check("/ ไม่ใช่โฟลเดอร์งาน", !AppPaths.looksLikeLibrary(URL(fileURLWithPath: "/")))

        print("\n3) ลำดับการหา (resolveRoot) — ของที่เลือกเองต้องชนะเสมอ")
        // Non-transient paths that really are libraries cannot be built in temp, so the order is
        // checked with the REAL project folder as the stand-in for "a real library": it is the
        // one directory this process is guaranteed to be able to see.
        let real = AppPaths.programRoot
        let realIsLib = AppPaths.looksLikeLibrary(real)
        check("โฟลเดอร์โปรแกรมตอนนี้เป็นโฟลเดอร์งาน (ใช้เป็นตัวแทนของจริง)", realIsLib, real.path)
        if realIsLib {
            let other = URL(fileURLWithPath: "/no/such/place")
            var r = AppPaths.resolveRoot(chosen: real.path, breadcrumb: other.path, beside: other)
            check("เลือกเองใช้ได้ → ชนะ", r.1 == .chosen && r.0.path == real.path, r.1.rawValue)
            r = AppPaths.resolveRoot(chosen: other.path, breadcrumb: other.path, beside: real)
            check("เลือกเองใช้ไม่ได้ → ตกไปที่โฟลเดอร์ข้างแอป",
                  r.1 == .beside && r.0.path == real.path, r.1.rawValue)
            // The migration case, and the ONLY one the breadcrumb is for: the app has moved to
            // /Applications, so there is no library beside it.
            r = AppPaths.resolveRoot(chosen: nil, breadcrumb: real.path, beside: other)
            check("แอปย้ายไป /Applications (ไม่มี library ข้างแอป) → ใช้ breadcrumb",
                  r.1 == .breadcrumb && r.0.path == real.path, r.1.rawValue)
            // The ordering defect this found: with the breadcrumb first, a classic-layout folder
            // copied somewhere new read the OLD folder for a whole launch.
            r = AppPaths.resolveRoot(chosen: nil, breadcrumb: real.path, beside: real)
            check("มี library ข้างแอป → ชนะ breadcrumb (กันอ่านโฟลเดอร์เก่า)",
                  r.1 == .beside, r.1.rawValue)
            r = AppPaths.resolveRoot(chosen: nil, breadcrumb: nil, beside: real)
            check("ไม่มีทั้งคู่ → ใช้โฟลเดอร์ข้างแอป (ของเดิมไม่พัง)",
                  r.1 == .beside && r.0.path == real.path, r.1.rawValue)
            r = AppPaths.resolveRoot(chosen: "  ", breadcrumb: "\n", beside: real)
            check("ค่าว่าง/ช่องว่าง ถูกข้าม ไม่ใช่ถูกใช้", r.1 == .beside, r.1.rawValue)
            r = AppPaths.resolveRoot(chosen: both.path, breadcrumb: nil, beside: real)
            check("เลือกเองชี้ที่ต้องห้าม → ไม่เอา ตกไปข้างแอป", r.1 == .beside, r.1.rawValue)
        }
        let nowhere = URL(fileURLWithPath: "/no/such/place")
        let none = AppPaths.resolveRoot(chosen: nil, breadcrumb: nil, beside: nowhere)
        // The one that matters most. `.none` is what a fresh drag-to-Applications install is in,
        // and `Store.saveNow` / `LogStore.save` / `Snapshot.write` all refuse while it holds —
        // because `AppPaths.root` then falls back to the bundle's parent, and writing a
        // `config.json` there would make `looksLikeLibrary` true for `/Applications` on the next
        // launch. An empty second library the app PREFERS is worse than no library at all.
        check("ไม่เจอที่ไหนเลย → .none (ไม่เดา ไม่สร้าง)", none.1 == .none, none.1.rawValue)
        check("เส้นทางที่ไม่มีอยู่จริง ไม่ถูกนับเป็นโฟลเดอร์งาน",
              !AppPaths.looksLikeLibrary(nowhere))

        print("\n4) โปรแกรมกับข้อมูลเป็นคนละที่ได้")
        check("programRoot ไม่ได้มาจากค่าที่เก็บไว้ (เป็นที่อยู่ของ bundle จริง)",
              AppPaths.programRoot.path == Bundle.main.bundleURL.deletingLastPathComponent().path
                || Bundle.main.bundleURL.pathExtension != "app",
              AppPaths.programRoot.path)
        check("accessor ของข้อมูลทั้งห้าอิงกับ root เดียวกัน",
              AppPaths.songs.deletingLastPathComponent().path == AppPaths.root.path
                && AppPaths.se.deletingLastPathComponent().path == AppPaths.root.path
                && AppPaths.config.deletingLastPathComponent().path == AppPaths.root.path
                && AppPaths.log.deletingLastPathComponent().path == AppPaths.root.path
                && AppPaths.brand.deletingLastPathComponent().path == AppPaths.root.path)

        print("\nผ่าน \(pass)  ตก \(fail)")
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    /// Click-outside-to-stop-typing. Read-only, builds only throwaway AppKit views.
    ///
    /// The click itself cannot be driven headlessly, so the DECISION is a pure function and this
    /// is what holds it. Two of the cases are the whole feature: a click on a button must let go
    /// (otherwise the transport stays dead), and a click on another text field must NOT
    /// (otherwise we fight AppKit for focus it is already moving).
    static func focusTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }
        let editor = NSTextView()
        let field = NSTextField()
        let button = NSButton()
        let plain = NSView()
        // A subview of the field — the border or clip view is what a click near the edge hits.
        let inner = NSView()
        field.addSubview(inner)

        print("1) ไม่มีใครพิมพ์อยู่ = คลิกธรรมดา ต้องไม่ทำอะไรเลย")
        check("firstResponder เป็น nil", !FocusRelease.shouldRelease(firstResponder: nil, hit: button))
        check("firstResponder ไม่ใช่ช่องข้อความ",
              !FocusRelease.shouldRelease(firstResponder: plain, hit: button))

        print("\n2) กำลังพิมพ์อยู่ แล้วคลิกที่อื่น = ต้องคืนคีย์บอร์ด")
        check("คลิกปุ่ม (คือเคสที่ทำให้ S/R/P/I/O/H ตายค้าง)",
              FocusRelease.shouldRelease(firstResponder: editor, hit: button))
        check("คลิกพื้นที่ว่าง / คลื่นเสียง",
              FocusRelease.shouldRelease(firstResponder: editor, hit: plain))
        check("คลิกนอกทุก view (แถบหัวหน้าต่าง)",
              FocusRelease.shouldRelease(firstResponder: editor, hit: nil))

        print("\n3) คลิกช่องข้อความอีกช่อง = ย้าย focus ไม่ใช่ปล่อย (ปล่อยแล้วจะแย่ง AppKit)")
        check("คลิก NSTextField อีกอัน",
              !FocusRelease.shouldRelease(firstResponder: editor, hit: field))
        check("คลิกขอบ/ลูกของช่องนั้น ก็ยังนับว่าเป็นช่อง",
              !FocusRelease.shouldRelease(firstResponder: editor, hit: inner))
        check("คลิกในตัว editor เอง",
              !FocusRelease.shouldRelease(firstResponder: editor, hit: editor))

        print("\nผ่าน \(pass)  ตก \(fail)")
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    /// The receive sweep: it has to look at EVERY round, not the one on screen.
    ///
    /// Read-only by construction — every `Store` here is `init(rawForTest:)`, which makes
    /// `scheduleSave`/`saveNow` no-ops, so `Handoff.apply` can be exercised for real against
    /// controlled values instead of the operator's file.
    static func incomingTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }

        func song(_ start: Double) -> [String: Any] {
            ["introStart": start, "introEnd": start + 15, "hook": 61.0, "configured": true]
        }
        // Three setters, one round each — the scenario the sweep exists for.
        let rounds = ["EP01", "EP02", "EP03"]
        var paths: [String: [String]] = [:]
        var senderRaw: [String: Any] = [:]
        for (i, r) in rounds.enumerated() {
            let ps = ["\(r)/10\(i + 1)_a.mp3", "\(r)/20\(i + 1)_b.mp3"]
            paths[r] = ps
            for (j, path) in ps.enumerated() { senderRaw[path] = song(Double(i * 2 + j) + 1) }
        }
        let sender = Store(rawForTest: senderRaw)
        var pkgs: [String: RoundPackage] = [:]
        for r in rounds {
            pkgs[r] = Handoff.package(round: r, paths: paths[r]!, store: sender, by: "คนเซ็ต \(r)")
        }
        // The receiving machine has the audio but has never seen any of the questions.
        let receiver = Store(rawForTest: [:])

        print("1) กวาดทุกรอบ ไม่ใช่รอบที่เลือกอยู่")
        // The REAL sweep, with the two things that touch the disk injected — not a copy of its
        // loop, because the defect was the loop and not the per-round decision.
        func waiting(_ st: Store, _ rs: [String] = rounds,
                     _ have: Set<String> = Set(rounds)) -> [String] {
            Handoff.waitingRounds(rs, store: st,
                                  songsIn: { paths[$0] ?? [] },
                                  read: { have.contains($0) ? pkgs[$0] : nil }).map(\.round)
        }
        let all = waiting(receiver)
        check("เจอทั้ง \(rounds.count) รอบ", all == rounds, all.joined(separator: ", "))
        // The counterfactual, as a number rather than a claim: this IS the old behaviour.
        let onlySelected = waiting(receiver, ["EP01"])
        check("ถ้าดูแค่รอบที่เลือก (ของเดิม) → เห็น \(onlySelected.count) จาก \(rounds.count) " +
              "= หาย \(rounds.count - onlySelected.count) ชุด",
              onlySelected == ["EP01"], onlySelected.joined(separator: ", "))
        // Nothing may stop the walk early: a round with no round.json in the MIDDLE must be
        // skipped, not treated as the end of the list.
        let gap = waiting(receiver, rounds, ["EP01", "EP03"])
        check("รอบที่ไม่มี round.json ถูกข้าม ไม่ใช่หยุดกวาด", gap == ["EP01", "EP03"],
              gap.joined(separator: ", "))
        check("เรียงตามลำดับรอบที่ส่งเข้าไป",
              waiting(receiver, rounds.reversed()) == rounds.reversed())

        print("\n2) รับแล้วต้องหายจากรายการ — และต้องหายแค่รอบนั้น")
        let plan = Handoff.plan(pkgs["EP02"]!, round: "EP02", paths: paths["EP02"]!, store: receiver)
        check("รอบที่ยังไม่เคยเห็น เข้า fresh ทั้งหมด ไม่ต้องถาม",
              plan.fresh.count == 2 && !plan.hasChoices, "fresh \(plan.fresh.count)")
        // `plan.round` is what `applyImport` clears by, so it must be the folder it was built for.
        check("plan จำโฟลเดอร์ของตัวเองไว้", plan.round == "EP02", plan.round)
        Handoff.apply(plan, accepted: [], store: receiver)
        let after = waiting(receiver)
        check("EP02 หายไป EP01/EP03 ยังอยู่", after == ["EP01", "EP03"], after.joined(separator: ", "))
        check("เอาเข้าแล้ว package เดิมไม่ขึ้นซ้ำ",
              !Handoff.isWaiting(pkgs["EP02"]!, round: "EP02", paths: paths["EP02"]!, store: receiver))

        print("\n3) ของที่เราส่งเองแล้วแก้ต่อ ต้องไม่ขึ้นมาให้ \"รับ\"")
        // EP01 was taken in above? No — take it in now, then edit it the way an operator does
        // on set. The file on disk now DIFFERS from local, so `plan` has rows; but local `base`
        // is that file, so those rows are our own work and accepting them would revert it.
        let p1 = Handoff.plan(pkgs["EP01"]!, round: "EP01", paths: paths["EP01"]!, store: receiver)
        Handoff.apply(p1, accepted: [], store: receiver)
        check("รับแล้วก็ไม่ขึ้นอีก", !waiting(receiver).contains("EP01"))
        var edited = receiver.config(for: paths["EP01"]![0])
        edited.introEnd += 3                    // แก้ที่กอง
        receiver.set(edited, for: paths["EP01"]![0])
        let after1 = Handoff.plan(pkgs["EP01"]!, round: "EP01", paths: paths["EP01"]!, store: receiver)
        check("แก้แล้ว plan เห็นค่าต่าง (ซึ่งถูก — มันเทียบ incoming-vs-local)",
              after1.rows.count == 1, "\(after1.rows.count) แถว")
        check("แต่ถือว่า \"รับไปแล้ว\" เพราะ base ตรงกับไฟล์",
              Handoff.alreadyTakenIn(pkgs["EP01"]!, round: "EP01",
                                     paths: paths["EP01"]!, store: receiver))
        check("→ ไม่ขึ้นแถบให้กดรับงานของตัวเอง", !waiting(receiver).contains("EP01"),
              waiting(receiver).joined(separator: ", "))
        // And the thing it must NOT swallow: a real new value from the sender.
        var resent = pkgs["EP01"]!
        let n0 = Library.baseName(paths["EP01"]![1])
        resent.songs[n0]!.b.hook += 7
        check("ผู้ส่งแก้มาจริง → ยังขึ้นปกติ",
              Handoff.isWaiting(resent, round: "EP01", paths: paths["EP01"]!, store: receiver))

        print("\n4) ปุ่ม “ไว้ก่อน” ต้องแยกเป็นรายชุด")
        let a = IncomingRound(round: "EP01", pkg: pkgs["EP01"]!)
        let b = IncomingRound(round: "EP03", pkg: pkgs["EP03"]!)
        check("สองรอบ = สอง id (ไว้ก่อนชุดหนึ่ง ต้องไม่ปิดอีกชุด)", a.id != b.id)
        check("ไฟล์เดิมอ่านซ้ำ = id เดิม",
              a.id == IncomingRound(round: "EP01", pkg: pkgs["EP01"]!).id)
        // A re-export must be able to raise the strip again even after a wave-off of the old file.
        var again = pkgs["EP01"]!
        again.at = "2026-11-24T09:00:00+07:00"
        check("ส่งมาใหม่ = id ใหม่ (ของเดิมเคยถูกปิดไว้ก็ยังขึ้น)",
              IncomingRound(round: "EP01", pkg: again).id != a.id)

        print("\n5) ชื่อที่โชว์คือโฟลเดอร์ที่จะลง ไม่ใช่ชื่อที่ผู้ส่งตั้ง")
        // Legal by design: round.json is keyed by FILE NAME so the receiver may file a round
        // under another folder name (§8e). The strip must name where it lands.
        let filedElsewhere = IncomingRound(round: "EP09", pkg: pkgs["EP01"]!)
        check("รู้ว่าชื่อไม่ตรงกัน", filedElsewhere.renamed, "pkg=\(pkgs["EP01"]!.round) folder=EP09")
        check("ชื่อเดียวกัน = ไม่ต้องเตือน", !a.renamed)
        // And the import really does target the folder's own songs, not the sender's round.
        let ep09 = ["EP09/101_a.mp3", "EP09/201_b.mp3"]
        let r9 = Store(rawForTest: [:])
        let p9 = Handoff.plan(pkgs["EP01"]!, round: "EP09", paths: ep09, store: r9)
        check("นำเข้าลงเพลงของโฟลเดอร์นั้น ไม่ใช่ของรอบที่ผู้ส่งตั้งชื่อ",
              Set(p9.fresh) == Set(ep09), p9.fresh.sorted().joined(separator: ", "))

        print("\n6) ชื่อคนเซ็ตต้องอยู่ข้ามการเปิดแอป")
        // `by` is the ONLY field saying whose round this is, and it used to be typed into a
        // sheet that forgets — so every handover arrived reading "ไม่ระบุชื่อ".
        let typed = "ภู  ทีมเซ็ตโจทย์"
        let st2 = Store(rawForTest: [:])
        st2.setterName = Store.clampName(typed)
        st2.settingsChanged()
        let written = (st2.raw["_settings"] as? [String: Any])?["setterName"] as? String
        check("เขียนลง _settings", written == typed, written ?? "—")
        let reopened = Store(rawForTest: st2.raw)
        check("เปิดใหม่แล้วยังอยู่", reopened.setterName == typed, reopened.setterName)
        // Read-it-before-you-delete-it, the same rule as updateFeed/resetAt.
        reopened.setterName = ""
        reopened.settingsChanged()
        check("ลบชื่อ = คีย์หายไป ไม่ใช่ค้างสตริงว่าง",
              (reopened.raw["_settings"] as? [String: Any])?["setterName"] == nil)

        print("\n7) ชื่อถูกตัดความยาว — มันข้ามเครื่องไปโผล่ในแถบบรรทัดเดียว")
        let huge = String(repeating: "ก่", count: 500)
        let cut = Store.clampName(huge)
        check("ตัดที่ \(Store.nameMax) ตัวอักษรไทย (นับเป็น cluster ไม่ใช่ scalar)",
              cut.count == Store.nameMax && cut.unicodeScalars.count > Store.nameMax,
              "\(cut.count) cluster / \(cut.unicodeScalars.count) scalar")
        check("ขึ้นบรรทัดใหม่/แท็บถูกยุบเป็นบรรทัดเดียว",
              !Store.clampName("ก\nข\tค").contains(where: \.isNewline) &&
              Store.clampName("  ก  ") == "ก")
        // The file crosses machines and is hand-editable, so the bound must hold on READ too —
        // the write side cannot be trusted to have been this app. Written into the SYSTEM temp
        // dir and removed; nothing here goes near the operator's folder.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rgf-incoming-\(UUID().uuidString).json")
        let hostile: [String: Any] = ["round": "EP01", "by": huge, "at": "x",
                                      "songs": [String: Any]()]
        try? JSONSerialization.data(withJSONObject: hostile).write(to: tmp)
        let parsed = RoundPackage.read(tmp)
        try? FileManager.default.removeItem(at: tmp)
        check("อ่าน round.json ที่ชื่อยาวผิดปกติ → ตัดตั้งแต่ขาเข้า",
              parsed?.by.count == Store.nameMax, "\(parsed?.by.count ?? -1)")
        let viaPackage = Handoff.package(round: "EP01", paths: paths["EP01"]!, store: receiver,
                                         by: huge)
        check("ตอนเขียนก็ตัด", viaPackage.by.count == Store.nameMax, "\(viaPackage.by.count)")

        print("\n8) การ \"ไว้ก่อน\" ต้องตายพร้อม process — แต่การ \"ตรวจแล้ว\" ต้องอยู่")
        // Two different things, and the substring filter below used to pass by accident rather
        // than on purpose, so both halves are now named. A wave-off is "not now" and must not
        // outlive the session (§8e). A REVIEW is a decision and has to survive a relaunch, or
        // the strip comes back on a show day for work that is already done.
        receiver.settingsChanged()
        let keys = Set(((receiver.raw["_settings"] as? [String: Any]) ?? [:]).keys)
        let suspect = keys.filter {
            let k = $0.lowercased()
            return k.contains("incoming") || k.contains("dismissedround") || k.contains("pending")
        }
        check("_settings ไม่มีคีย์ของรายการที่ \"ไว้ก่อน\"", suspect.isEmpty,
              suspect.isEmpty ? "\(keys.count) คีย์ ไม่มีอันไหนเกี่ยว"
                              : suspect.sorted().joined(separator: ", "))
        check("แต่ \"ตรวจแล้ว\" ถูกเขียนลง _settings", keys.contains("takenIn"))
        check("เขียนเป็น list เรียงแล้ว (ไฟล์นี้คนอ่านและแก้มือ)",
              ((receiver.raw["_settings"] as? [String: Any])?["takenIn"] as? [String])
                  .map { $0 == $0.sorted() } ?? false)

        print("\n9) ส่งมาเฉพาะ note หรือ tag — ต้องขึ้นแถบ")
        // `SongBase` is the five marker fields. `alreadyTakenIn` compares it, so a handover whose
        // only change is the field §8g exists for matched on every song and raised NOTHING: no
        // strip, no 📥 in the picker. The setter watched round.json land and assumed it arrived.
        let r9n = Store(rawForTest: [:])
        Handoff.apply(Handoff.plan(pkgs["EP03"]!, round: "EP03", paths: paths["EP03"]!, store: r9n),
                      accepted: [], store: r9n)
        let n9 = Library.baseName(paths["EP03"]![0])
        var noteOnly = pkgs["EP03"]!
        noteOnly.at = "2026-11-25T10:00:00+07:00"      // a genuine re-export
        noteOnly.songs[n9]!.note = "ฝั่งซ้ายน่าจะได้เปรียบ"
        let pn = Handoff.plan(noteOnly, round: "EP03", paths: paths["EP03"]!, store: r9n)
        check("plan ยก row ของ note", pn.rows.count == 1 &&
              pn.rows.first?.field.key == DiffField.note.key, "\(pn.rows.count) แถว")
        // The counterfactual, as a number: the comparison this used to rest on says "done".
        check("ของเดิม: alreadyTakenIn ตอบว่า \"รับไปแล้ว\" → หายไปทั้งชุด",
              Handoff.alreadyTakenIn(noteOnly, round: "EP03",
                                     paths: paths["EP03"]!, store: r9n))
        check("ของใหม่: ยังขึ้นแถบ",
              Handoff.isWaiting(noteOnly, round: "EP03", paths: paths["EP03"]!, store: r9n))
        var tagOnly = pkgs["EP03"]!
        tagOnly.at = "2026-11-25T11:00:00+07:00"
        tagOnly.songs[n9]!.tags = ["ยุค 90"]
        check("tag เดี่ยว ๆ ก็เหมือนกัน",
              Handoff.isWaiting(tagOnly, round: "EP03", paths: paths["EP03"]!, store: r9n))

        print("\n10) ปฏิเสธ row แล้วต้องไม่วนกลับมา")
        // Declining leaves the local value and `base` agreeing with each other and both
        // differing from the sender — which is exactly what §8e asks `apply` to do. So no
        // comparison can tell a declined review from an untouched round, and the strip returned
        // on every launch with the sheet PRE-ACCEPTING the rows that had just been turned down.
        let r10 = Store(rawForTest: [:])
        Handoff.apply(Handoff.plan(pkgs["EP01"]!, round: "EP01", paths: paths["EP01"]!, store: r10),
                      accepted: [], store: r10)
        var pushy = pkgs["EP01"]!
        pushy.at = "2026-11-25T12:00:00+07:00"
        let n10 = Library.baseName(paths["EP01"]![0])
        let mine10 = r10.config(for: paths["EP01"]![0]).introEnd
        pushy.songs[n10]!.b.introEnd = mine10 + 4
        let p10 = Handoff.plan(pushy, round: "EP01", paths: paths["EP01"]!, store: r10)
        check("มี row ให้เลือก", p10.rows.count == 1, "\(p10.rows.count) แถว")
        Handoff.apply(p10, accepted: [], store: r10)          // ปฏิเสธ
        check("ค่าเดิมของเครื่องนี้อยู่ครบ (ปฏิเสธได้ผล)",
              r10.config(for: paths["EP01"]![0]).introEnd == mine10)
        check("base ถูกปั๊มจากผลลัพธ์ ไม่ใช่จากผู้ส่ง (§8e) → ไม่มีป้าย \"แก้ที่กอง\" ปลอม",
              r10.config(for: paths["EP01"]![0]).base?.introEnd == mine10)
        check("ของเดิม: alreadyTakenIn ตอบ false ตลอดไป → นี่คือเหตุที่มันวนกลับมา",
              !Handoff.alreadyTakenIn(pushy, round: "EP01", paths: paths["EP01"]!, store: r10))
        check("ของใหม่: ไม่ขึ้นอีก",
              !Handoff.isWaiting(pushy, round: "EP01", paths: paths["EP01"]!, store: r10))
        // And it has to survive a relaunch, which is the whole reason it is in `_settings`.
        r10.settingsChanged()
        let r10b = Store(rawForTest: r10.raw)
        check("เปิดแอปใหม่แล้วยังไม่ขึ้น",
              !Handoff.isWaiting(pushy, round: "EP01", paths: paths["EP01"]!, store: r10b))
        check("แต่ถ้าผู้ส่งแก้มาจริงอีกรอบ ยังขึ้นปกติ", {
            var again2 = pushy
            again2.at = "2026-11-25T13:00:00+07:00"
            again2.songs[n10]!.b.hook += 9
            return Handoff.isWaiting(again2, round: "EP01", paths: paths["EP01"]!, store: r10b)
        }())

        print("\n11) คีย์ของ \"ตรวจแล้ว\" ผูกกับเนื้อหา ไม่ใช่แค่เวลา export")
        let k1 = Handoff.reviewKey(round: "EP01", pkg: pkgs["EP01"]!)
        check("ไฟล์เดิมอ่านซ้ำ = คีย์เดิม",
              k1 == Handoff.reviewKey(round: "EP01", pkg: pkgs["EP01"]!))
        check("คนละโฟลเดอร์ = คนละคีย์",
              k1 != Handoff.reviewKey(round: "EP09", pkg: pkgs["EP01"]!))
        // The reason this is NOT `IncomingRound.id`: that is folder + `at`, so a round.json
        // edited by hand while keeping its timestamp would be swallowed as already-reviewed.
        var handEdited = pkgs["EP01"]!
        handEdited.songs[n10]!.b.introEnd += 1          // at ไม่เปลี่ยน
        check("แก้เนื้อหาโดย at เท่าเดิม = คนละคีย์ (ซึ่ง IncomingRound.id แยกไม่ออก)",
              Handoff.reviewKey(round: "EP01", pkg: handEdited) != k1 &&
              IncomingRound(round: "EP01", pkg: handEdited).id
                  == IncomingRound(round: "EP01", pkg: pkgs["EP01"]!).id)
        check("note เปลี่ยนก็นับ", Handoff.reviewKey(round: "EP03", pkg: noteOnly)
              != Handoff.reviewKey(round: "EP03", pkg: pkgs["EP03"]!))
        check("tag เปลี่ยนก็นับ", Handoff.reviewKey(round: "EP03", pkg: tagOnly)
              != Handoff.reviewKey(round: "EP03", pkg: pkgs["EP03"]!))

        print("\n12) ล้างรายการเก่าต้องเทียบกับ \"ทุกชุดบนดิสก์\" ไม่ใช่ \"ชุดที่รออยู่\"")
        // A reviewed package is BY DEFINITION not waiting, so pruning against the waiting set
        // deletes every record on the first sweep and puts the feature back where it started.
        // `packagesOnDisk` exists for this, and it lives in `Handoff` so the sweep still has one
        // implementation (§8e: the defect was the loop, not the per-round decision).
        // What is ON DISK for EP01 is the re-export section 10 reviewed, not the original — the
        // prune set has to be built from the files as they stand, and getting that wrong is the
        // whole point of this section.
        var disk = pkgs
        disk["EP01"] = pushy
        let onDisk = Handoff.packagesOnDisk(rounds, read: { disk[$0] })
        check("packagesOnDisk เห็นทุกชุด ไม่กรอง", onDisk.count == rounds.count,
              "\(onDisk.count) จาก \(rounds.count)")
        let liveKeys = Set(onDisk.map { Handoff.reviewKey(round: $0.round, pkg: $0.pkg) })
        let kept = r10b.takenIn.intersection(liveKeys).count
        r10b.pruneTakenIn(to: liveKeys)
        check("ล้างด้วยชุดที่ถูก → รายการที่ยังอยู่บนดิสก์ไม่หาย", r10b.takenIn.count == kept,
              "\(r10b.takenIn.count) รายการ")
        check("ของใหม่: ยังไม่ขึ้นหลังล้าง",
              !Handoff.isWaiting(pushy, round: "EP01", paths: paths["EP01"]!, store: r10b))
        // The counterfactual with a number, because this is the mistake that looks correct.
        let r12 = Store(rawForTest: r10.raw)
        let before12 = r12.takenIn.count
        let waitingKeys = Set(Handoff.waitingRounds(rounds, store: r12,
                                                    songsIn: { paths[$0] ?? [] },
                                                    read: { disk[$0] })
            .map { Handoff.reviewKey(round: $0.round, pkg: $0.pkg) })
        r12.pruneTakenIn(to: waitingKeys)
        check("ถ้าล้างด้วย \"ชุดที่รออยู่\" (ผิด) → เหลือ \(r12.takenIn.count) จาก \(before12) " +
              "= ลืมที่ตรวจแล้วทั้งหมด", before12 > 0 && r12.takenIn.isEmpty)
        check("และแถบที่ปฏิเสธไว้จะกลับมา (นี่คือราคาของการล้างผิดชุด)",
              Handoff.isWaiting(pushy, round: "EP01", paths: paths["EP01"]!, store: r12))

        print("\nผ่าน \(pass)  ตก \(fail)")
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    static func filterTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }
        func names(_ ps: [String]) -> String {
            ps.isEmpty ? "—" : ps.map(Library.baseName).sorted().joined(separator: ", ")
        }

        func song(_ tags: [String], star: Bool = false) -> [String: Any] {
            var d: [String: Any] = ["introStart": 1.0, "introEnd": 16.0, "hook": 61.0,
                                    "configured": true, "tags": tags]
            if star { d["starred"] = true }
            return d
        }
        let round = "EP09"
        let paths = ["EP09/101_a.mp3", "EP09/102_b.mp3", "EP09/201_c.mp3", "EP09/301_d.mp3"]
        let st = Store(rawForTest: [
            paths[0]: song(["ยุค 90", "ผู้หญิงร้อง"]),
            paths[1]: song(["ยุค 90"], star: true),
            paths[2]: song(["Rock"], star: true),
            paths[3]: song([]),
        ])

        print("1) Library.visible")
        check("แท็กว่าง = ไม่กรอง (คือสิ่งที่ทำให้ไม่ต้องมี branch ทุกที่)",
              Library.visible(paths, tag: "", store: st) == paths)
        let p90 = Library.visible(paths, tag: "ยุค 90", store: st)
        check("กรองตามแท็ก", p90.count == 2 && p90.allSatisfy { paths.prefix(2).contains($0) },
              names(p90))
        check("ไม่สนตัวพิมพ์เล็ก/ใหญ่",
              Library.visible(paths, tag: "rOcK", store: st) == [paths[2]],
              names(Library.visible(paths, tag: "rOcK", store: st)))
        check("แท็กที่ไม่มีใครติด → ว่าง",
              Library.visible(paths, tag: "ไม่มีแท็กนี้", store: st).isEmpty)
        check("เพลงที่ไม่มีแท็กเลย ถูกซ่อนเสมอ", !p90.contains(paths[3]))
        // The two numbers the strip prints must add up, or it is lying about what it hides.
        let hidden = paths.count - p90.count
        check("เห็น + ซ่อน = ทั้งรอบ", p90.count + hidden == paths.count,
              "\(p90.count) + \(hidden) = \(paths.count)")

        print("\n2) การส่งต่อกับ pre-flight ไม่สนตัวกรอง — รับรอบ ไม่ใช่สิ่งที่เห็น")
        // The whole point of the separate accessor: these take the ROUND. A song the filter
        // hides must still be in the package and still be checked.
        let pkg = Handoff.package(round: round, paths: paths, store: st, by: "diag")
        check("round.json มีทุกเพลงในรอบ (\(paths.count))",
              pkg.songs.count == paths.count, "\(pkg.songs.count)")
        check("รวมเพลงที่ตัวกรองจะซ่อน",
              pkg.songs[Library.baseName(paths[3])] != nil)
        // Missing files, so every row is `missingFile` — which is exactly what proves coverage.
        let pf = Preflight.fast(round: round, paths: paths, store: st)
        check("pre-flight ตรวจทุกเพลงในรอบ",
              Set(pf.map(\.path)) == Set(paths), "\(Set(pf.map(\.path)).count)/\(paths.count)")
        // And the counterfactual: had the filter leaked into the accessor those two would shrink.
        let leaked = Handoff.package(round: round, paths: p90, store: st, by: "diag")
        check("ถ้าเผลอเอา visibleSongs ไปให้ → ส่งต่อหาย \(paths.count - p90.count) เพลง (คือสิ่งที่ต้องกัน)",
              leaked.songs.count == p90.count, "\(leaked.songs.count)")

        print("\n3) ค้นหาจากชื่อไฟล์")
        // Real YouTube filenames — the shape the matcher actually meets.
        let sp = ["EP09/101_THE TOYS - ลาลาลอย (100%)  [Official Music Video].mp3",
                  "EP09/202_Ooh! - Palmy【OFFICIAL MV】.mp3",
                  "EP09/107_PROXIE - ขี้แง (Boys Don’t Cry)   Official MV.mp3"]
        func find(_ q: String) -> [String] {
            Library.visible(sp, tag: "", search: q, store: st).map(Library.baseName)
        }
        check("คำค้นว่าง = ไม่กรอง (เหมือนแท็กว่าง)", find("") .count == sp.count)
        check("ไม่สนตัวพิมพ์เล็ก/ใหญ่", find("palmy").count == 1 && find("PALMY").count == 1)
        // The raw basename, not displayTitle: displayTitle strips the leading number, so
        // searching the digits you can SEE in the column only works if the haystack is raw.
        check("ค้นเลขหัวเพลงที่เห็นในคอลัมน์ได้", find("107") == [Library.baseName(sp[2])],
              find("107").joined(separator: ", "))
        // ...and the boilerplate displayTitle removes is still searchable, same reason.
        check("ค้นคำที่ displayTitle ตัดทิ้งก็ยังเจอ", find("official mv").count == 2,
              "\(find("official mv").count)")
        check("ภาษาไทย", find("ลาลาลอย").count == 1 && find("ขี้แง").count == 1)
        // NFC on both sides. Two visually identical Thai strings compare unequal otherwise —
        // §8g's lesson for the note, in the one place a human types the comparison by hand.
        let decomposed = "ขี้แง".decomposedStringWithCanonicalMapping
        check("สะกดแบบ decomposed ก็ต้องเจอ (NFC ทั้งสองฝั่ง)", find(decomposed).count == 1)
        check("หลายคำ = AND ไม่สนลำดับ",
              find("palmy ooh").count == 1 && find("ooh palmy").count == 1)
        check("เว้นวรรคซ้ำ ๆ ถูกยุบ", find("  palmy   ooh  ").count == 1)
        check("ไม่เจอ = ว่าง ไม่ใช่ทั้งหมด", find("ไม่มีเพลงนี้").isEmpty)
        check("ทุกคำต้องเจอ — คำเดียวตรงไม่พอ", find("palmy ลาลาลอย").isEmpty)

        print("\n4) ค้นหาก็ห้ามรั่วเข้าไปในการส่งต่อ เหมือนตัวกรองแท็ก")
        // The same separation, and the same counterfactual with a number: `songsIn` is the
        // round, `visibleSongs` is what the list shows. 23 of the 26 call sites are the former.
        let found = Library.visible(paths, tag: "", search: "101", store: st)
        check("ค้นแล้วเหลือ \(found.count) จาก \(paths.count) ในลิสต์", found.count == 1,
              names(found))
        let pkgS = Handoff.package(round: round, paths: paths, store: st, by: "diag")
        check("round.json ยังมีครบทุกเพลง (\(paths.count))", pkgS.songs.count == paths.count)
        let leakedS = Handoff.package(round: round, paths: found, store: st, by: "diag")
        check("ถ้าเผลอส่ง visibleSongs ไป → หาย \(paths.count - found.count) เพลง",
              leakedS.songs.count == found.count, "\(leakedS.songs.count)")
        check("pre-flight ยังตรวจทั้งรอบ",
              Set(Preflight.fast(round: round, paths: paths, store: st).map(\.path)) == Set(paths))

        print("\n5) ไม่เก็บลงไฟล์ — กรองต้องตายพร้อม process")
        st.settingsChanged()
        let keys = Set(((st.raw["_settings"] as? [String: Any]) ?? [:]).keys)
        let suspect = keys.filter {
            let k = $0.lowercased()
            return k.contains("filter") || k.contains("tagfilter") || k.contains("search")
        }
        check("_settings ไม่มีคีย์เกี่ยวกับตัวกรองหรือคำค้น", suspect.isEmpty,
              suspect.isEmpty ? "\(keys.count) คีย์ ไม่มีอันไหนเกี่ยว"
                              : suspect.sorted().joined(separator: ", "))

        print("\nผ่าน \(pass)  ตก \(fail)")
        print("\n★) กรองเฉพาะติดดาว")
        let starred = Library.visible(paths, tag: "", starred: true, store: st)
        check("เห็นเฉพาะที่ติดดาว", names(starred) == "102_b.mp3, 201_c.mp3", names(starred))
        check("ไม่กรองดาว = ครบทุกเพลง",
              Library.visible(paths, tag: "", starred: false, store: st).count == paths.count)
        // Both narrowings at once must INTERSECT, not replace one another.
        let both = Library.visible(paths, tag: "ยุค 90", starred: true, store: st)
        check("ดาว + แท็ก — ตัดกัน ไม่ใช่แทนกัน", names(both) == "102_b.mp3", names(both))
        let bothSearch = Library.visible(paths, tag: "", search: "201", starred: true, store: st)
        check("ดาว + คำค้น — ตัดกัน", names(bothSearch) == "201_c.mp3", names(bothSearch))
        // The counterfactual as a number — §8g's rule that the cost of handing a VIEW to the
        // handover is written down rather than argued about.
        let starPkg = Handoff.package(round: round, paths: starred, store: st, by: "")
        check("ถ้าส่งต่อด้วยรายการที่กรองดาวไว้ จะหาย 2 จาก 4 เพลง",
              starPkg.songs.count == 2, "ได้ \(starPkg.songs.count)")
        // The star crosses the handover, additively.
        var sent = Handoff.package(round: round, paths: paths, store: st, by: "")
        check("round.json พาดาวไปด้วย",
              sent.songs["102_b.mp3"]?.starred == true
              && sent.songs["301_d.mp3"]?.starred == false)
        sent.songs["301_d.mp3"]?.starred = true
        let recv = Store(rawForTest: [paths[3]: song([])])
        let pl = Handoff.plan(sent, round: round, paths: [paths[3]], store: recv)
        check("ดาวที่เข้ามาใหม่ = มีแถวให้เลือก", pl.rows.contains { $0.field == .starred })
        var noStar = sent
        noStar.songs["102_b.mp3"]?.starred = false
        let recv2 = Store(rawForTest: [paths[1]: song([], star: true)])
        let pl2 = Handoff.plan(noStar, round: round, paths: [paths[1]], store: recv2)
        check("ฝั่งส่งไม่มีดาว = เงียบ ไม่ใช่สั่งให้เอาดาวออก",
              !pl2.rows.contains { $0.field == .starred })
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    // MARK: - tags

    /// `SongConfig.tags` — short reusable labels, the derived registry, and the UNION merge.
    ///
    /// **READ-ONLY**, by the same mechanism as `--notetest`: every `Store` is built with
    /// `init(rawForTest:)`, which cannot write.
    static func tagTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }
        func show(_ ts: [String]) -> String { ts.isEmpty ? "—" : ts.joined(separator: " · ") }

        // 1 ------------------------------------------------------------------- clampTag
        print("1) clampTag — หนึ่งแท็ก")
        let tagCases: [(String, String, String?)] = [
            ("ธรรมดา",            "ยุค 90",     "ยุค 90"),
            ("ตัดช่องหน้าหลัง",     "  ยุค 90  ", "ยุค 90"),
            ("ยุบช่องว่างซ้อน",     "ยุค   90", "ยุค 90"),
            ("ขึ้นบรรทัดใหม่",    "a\nb",      "a b"),
            ("ตัด · ออก (ตัวคั่นของแถบกลาง)", "ยุค · 90", "ยุค 90"),
            ("ว่าง → nil",      "",           nil),
            ("มีแต่ช่องว่าง → nil", "   \n ",    nil),
            ("มีแต่ · → nil",      "·",          nil),
        ]
        for (label, input, want) in tagCases {
            let got = Store.clampTag(input)
            check(label, got == want, got.map { "\"\($0)\"" } ?? "nil")
        }
        let longTag = String(repeating: "ก", count: Store.tagMax + 10)
        check("ยาวเกิน → ตัดที่ \(Store.tagMax)",
              Store.clampTag(longTag)?.count == Store.tagMax,
              "\(Store.clampTag(longTag)?.count ?? -1)")

        // 2 ------------------------------------------------------------------ clampTags
        print("\n2) clampTags — ซ้อนกัน กับเพดานต่อเพลง")
        let dedup = Store.clampTags(["Pop", "pop", "POP", "ยุค 90", "ยุค 90"])
        check("Latin ต่างแค่ตัวพิมพ์เล็ก/ใหญ่ = แท็กเดียว การสะกดแรกชนะ",
              dedup == ["Pop", "ยุค 90"], show(dedup))
        let many = Store.clampTags((1...Store.tagsPerSong + 4).map { "t\($0)" })
        check("เกิน \(Store.tagsPerSong) → ตัด", many.count == Store.tagsPerSong, show(many))
        check("รักษาลำดับที่คนพิมพ์", many == ["t1", "t2", "t3", "t4", "t5", "t6"], show(many))

        // 3 ----------------------------------------------- the registry, and its cache
        print("\n3) ทะเบียน — ไม่เก็บ คิดจากของที่ใช้อยู่")
        func songDict(_ tags: [String]) -> [String: Any] {
            ["introStart": 0.0, "introEnd": 15.0, "configured": true, "tags": tags]
        }
        let reg = Store(rawForTest: [
            "EP/a.mp3": songDict(["ยุค 90", "ผู้หญิงร้อง"]),
            "EP/b.mp3": songDict(["ยุค 90"]),
            "EP/c.mp3": songDict(["ยุค 90", "เพลงเร็ว"]),
        ])
        check("เรียงตามความถี่ แล้วค่อยตามชื่อ",
              reg.tagsInUse.first == "ยุค 90" && reg.tagsInUse.count == 3, show(reg.tagsInUse))
        // The cache is the only reason this is cheap enough to read from `body`, and a stale one
        // would keep offering a tag nobody carries any more.
        var ra = reg.config(for: "EP/a.mp3"); ra.tags = []
        reg.set(ra, for: "EP/a.mp3")
        check("set → ทะเบียนอัพเดต",
              !reg.tagsInUse.contains("ผู้หญิงร้อง"), show(reg.tagsInUse))
        reg.removeConfig(for: "EP/c.mp3")
        check("removeConfig → ทะเบียนอัพเดต",
              !reg.tagsInUse.contains("เพลงเร็ว"), show(reg.tagsInUse))
        _ = reg.pruneOrphans(existing: [])
        check("pruneOrphans → ทะเบียนว่าง", reg.tagsInUse.isEmpty, show(reg.tagsInUse))
        // First spelling wins, so nothing silently rewrites what somebody typed.
        let spell = Store(rawForTest: ["EP/a.mp3": songDict(["Rock"]),
                                       "EP/b.mp3": songDict(["rock"])])
        check("สะกดแรกชนะ และนับรวมเป็นอันเดียว",
              spell.tagsInUse == ["Rock"], show(spell.tagsInUse))
        check("songsTagged ไม่สนตัวพิมพ์เล็ก/ใหญ่",
              spell.songsTagged("ROCK").count == 2, "\(spell.songsTagged("ROCK").count)")
        // Pins the RULE, not the hash seed. This is what the flake was: `tagsInUse` walks
        // `songs.values`, whose order is seeded per process, so "the first spelling we see"
        // picked a different winner on different launches.
        let majority = Store(rawForTest: [
            "EP/a.mp3": songDict(["rock"]), "EP/b.mp3": songDict(["rock"]),
            "EP/c.mp3": songDict(["rock"]), "EP/d.mp3": songDict(["Rock"]),
        ])
        check("สะกดที่ใช้มากสุดชนะ (3 ต่อ 1)",
              majority.tagsInUse == ["rock"], show(majority.tagsInUse))
        let minority = Store(rawForTest: [
            "EP/a.mp3": songDict(["Rock"]), "EP/b.mp3": songDict(["Rock"]),
            "EP/c.mp3": songDict(["Rock"]), "EP/d.mp3": songDict(["rock"]),
        ])
        check("สลับข้างก็ได้คำตอบกลับกัน",
              minority.tagsInUse == ["Rock"], show(minority.tagsInUse))

        // 4 ------------------------------------------------------- not a marker, again
        print("\n4) แท็กไม่ใช่ marker")
        var guessed = SongConfig(); guessed.auto = true
        guessed.tags = ["ยุค 90"]
        check("ติดแท็กแล้ว isConfigured ยัง false", !guessed.isConfigured)
        var signed = SongConfig(); signed.configured = true; signed.base = signed.current
        signed.tags = ["แก้ทีหลัง"]
        check("แท็กไม่ขึ้นป้าย แก้ที่กอง", signed.onsiteEdits.isEmpty)

        // 5 ------------------------------------------------------------- union on merge
        print("\n5) การส่งต่อ — union เท่านั้น")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagtest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = "EP00/x.mp3"

        /// local, incoming, expect a row?, result if accepted, result if rejected
        let table: [([String], [String], Bool, [String], [String])] = [
            ([],        [],        false, [],             []),
            ([],        ["A"],     true,  ["A"],          []),
            (["B"],     [],        false, ["B"],          ["B"]),      // removed-locally stays
            (["B"],     ["B"],     false, ["B"],          ["B"]),
            (["B"],     ["A"],     true,  ["B", "A"],     ["B"]),      // UNION, not replace
            (["B"],     ["b"],     false, ["B"],          ["B"]),      // case is not new
            (["B"],     ["A", "B"], true, ["B", "A"],     ["B"]),
        ]
        for (mine, theirs, wantRow, ifYes, ifNo) in table {
            for accept in [true, false] {
                let s = Store(rawForTest: [key: ["introStart": 0.0, "introEnd": 15.0,
                                                 "configured": true, "played": true,
                                                 "tags": mine]])
                var pkg = RoundPackage()
                var e = RoundPackage.Entry()
                e.b = s.config(for: key).current
                e.tags = theirs
                pkg.songs[Library.baseName(key)] = e
                guard (try? pkg.write(to: tmp)) != nil, let back = RoundPackage.read(tmp) else {
                    check("round.json เขียน/อ่าน", false); continue
                }
                let plan = Handoff.plan(back, round: "EP00", paths: [key], store: s)
                let rows = plan.rows.filter { $0.field == .tags }
                if accept {
                    check("นี่ \(show(mine))  รับ \(show(theirs)) → แถว \(wantRow ? "ใช่" : "ไม่")",
                          rows.count == (wantRow ? 1 : 0), "\(rows.count)")
                }
                Handoff.apply(plan, accepted: accept ? Set(plan.rows.map(\.id)) : [], store: s)
                let got = s.config(for: key)
                check("   └ \(accept ? "รับ" : "ไม่รับ") → \(show(got.tags))",
                      got.tags == (accept ? ifYes : ifNo),
                      "ควรเป็น \(show(accept ? ifYes : ifNo))")
                check("   └ ไม่แตะ played", got.played)
            }
        }
        // Accepting cannot blow the per-song cap however many arrive.
        do {
            let s = Store(rawForTest: [key: ["introStart": 0.0, "introEnd": 15.0,
                                             "tags": ["a", "b", "c"]]])
            var pkg = RoundPackage(); var e = RoundPackage.Entry()
            e.b = s.config(for: key).current
            e.tags = (1...Store.tagsPerSong + 5).map { "z\($0)" }
            pkg.songs[Library.baseName(key)] = e
            let plan = Handoff.plan(pkg, round: "EP00", paths: [key], store: s)
            Handoff.apply(plan, accepted: Set(plan.rows.map(\.id)), store: s)
            let n = s.config(for: key).tags.count
            check("รับมาเยอะก็ไม่เกิน \(Store.tagsPerSong)", n <= Store.tagsPerSong, "\(n)")
        }
        // A song the receiving side has never seen takes the sender's tags outright.
        do {
            let s = Store(rawForTest: [:])
            var pkg = RoundPackage(); var e = RoundPackage.Entry()
            e.b = SongBase(introStart: 2, introEnd: 20, hook: 70, trimDb: 0, ignoreEnd: false)
            e.tags = ["ยุค 90", "เพลงเร็ว"]
            pkg.songs[Library.baseName(key)] = e
            let plan = Handoff.plan(pkg, round: "EP00", paths: [key], store: s)
            Handoff.apply(plan, accepted: [], store: s)
            check("เพลงใหม่ (fresh) รับแท็กมาเลย",
                  s.config(for: key).tags == e.tags, show(s.config(for: key).tags))
        }

        // 6 ------------------------------------------------------------- the layout claim
        print("\n6) กล่องในแถบกลาง — โน้ต + แท็ก แชร์ 2 บรรทัดกัน")
        let avail: CGFloat = 520 - 10 - 10 - 3
        func measure(_ c: SongConfig) -> (CGFloat, Double) {
            let a = NSAttributedString(CenterView.noteText(c))
            let w = a.size().width
            return (w, Double((w / avail).rounded(.up)))
        }
        var typical = SongConfig()
        typical.note = "ฝั่งซ้ายน่าจะได้เปรียบ คนรุ่น 40+ รู้แน่"
        typical.tags = ["ยุค 90", "ผู้หญิงร้อง"]
        let (w1, l1) = measure(typical)
        check("กรณีปกติ (โน้ต \(typical.note.count) ตัว + 2 แท็ก) อ่านครบ", l1 <= 2,
              String(format: "%.0f pt → %.0f บรรทัด", w1, l1))
        var worst = SongConfig()
        worst.note = String(repeating: "ก", count: Store.noteMax)
        worst.tags = (1...Store.tagsPerSong).map { _ in String(repeating: "ก", count: Store.tagMax) }
        let (w2, l2) = measure(worst)
        // Expected to overflow, and that is the documented trade: `.lineLimit(2)` keeps the box
        // at its height and the TAGS are what get cut, because the note is drawn first.
        print(String(format: "   (กรณีเลวร้ายสุด: โน้ตเต็ม + %d แท็กเต็ม = %.0f pt → %.0f บรรทัด"
                     + " — โน้ตมาก่อน แท็กจึงเป็นสิ่งที่ถูกตัด)",
                     Store.tagsPerSong, w2, l2))
        check("โน้ตมาก่อนแท็กเสมอ",
              NSAttributedString(CenterView.noteText(typical)).string.hasPrefix(typical.note))
        check("ไม่มีอะไรเลย → กล่องว่าง (ไม่วาด)",
              NSAttributedString(CenterView.noteText(SongConfig())).string.isEmpty)
        // The tags in that box are FILLED like the chips in the list (§8g), and a fill that
        // nothing measures is a fill that can be deleted silently.
        let cols = ["ยุค 90": 2, "ผู้หิงร้อง": 4]
        let audit = CenterView.noteTagFillAudit(typical, colors: cols)
        check("แท็กทุกอันมีสีพื้นหลัง", audit.filled == typical.tags.count,
              "ได้ \(audit.filled) ควร \(typical.tags.count)")
        check("ตัวโน้ตเองไม่มีสีพื้นหลัง", !audit.noteFilled)
        check("ไม่รู้สีแท็ก → ไม่ใส่พื้นหลังเลย",
              CenterView.noteTagFillAudit(typical, colors: [:]).filled == 0)
        // `noteText` is built from `body`, which re-renders at the player's tick rate (§8f's
        // memoised-cover lesson). Measured so the decision not to memoise it is a measurement
        // and not a shrug. Anything approaching the 20 ms guard tick would need a cache.
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<1000 { _ = CenterView.noteText(worst) }
            let us = (CFAbsoluteTimeGetCurrent() - t0) * 1_000_000 / 1000
            check(String(format: "noteText กรณีเลวร้ายสุด %.1f µs — สร้างใหม่ทุก frame ได้", us),
                  us < 500, String(format: "%.1f µs", us))
        }

        // ---------------------------------------------------- the colour per tag (§8g)
        print("\nสีประจำแท็ก — ต้องคนละสี และต้องเหมือนเดิมทุกครั้ง")
        var raw: [String: Any] = [:]
        // Exactly `Palette.tagSlots` words, so "every tag gets a colour of its own" is a
        // property the automatic half can actually deliver. The over-subscribed case has its
        // own block below, because it is a DIFFERENT promise.
        let words = ["ยุค 90", "ยุค 2000", "ผู้หญิงร้อง", "ผู้ชายร้อง", "แร็ป", "ช้า"]
        for (n, w) in words.enumerated() { raw["EP/\(n).mp3"] = ["tags": [w]] }
        let cs = Store(rawForTest: raw)
        let slots = cs.tagColors
        check("แท็ก \(words.count) แบบ ได้สีครบทุกตัว", slots.count == words.count)
        check("ไม่มีสองแท็กใช้สีเดียวกัน (เท่ากับจำนวนสีพอดี)",
              Set(slots.values).count == words.count,
              "ใช้ไป \(Set(slots.values).count) จาก \(Palette.tagSlots) สี")
        check("ทุกสลอตอยู่ในช่วงของจานสี",
              slots.values.allSatisfy { $0 >= 0 && $0 < Palette.tagSlots })
        // The determinism that `tagsInUse` already had to learn once: Swift seeds Dictionary
        // hashing per process, so anything derived by walking `songs.values` must not depend on
        // the order it comes back in. Rebuilding from a DIFFERENT insertion order must agree.
        var raw2: [String: Any] = [:]
        for (n, w) in words.enumerated().reversed() { raw2["EP/z\(n).mp3"] = ["tags": [w]] }
        let slots2 = Store(rawForTest: raw2).tagColors
        check("ใส่เข้ามาคนละลำดับ ได้สีเดิมทุกตัว", slots == slots2)
        // ...and a different library that happens to share a tag gives that tag the same colour,
        // which is what makes the setter's screen and the operator's screen agree without
        // anything travelling in round.json. True only while nothing is over-subscribed and
        // nobody has CHOSEN a colour — both of those make the automatic half depend on which
        // slots are already claimed, which is exactly why a choice travels (§8g).
        let lone = Store(rawForTest: ["EP/only.mp3": ["tags": ["ผู้หญิงร้อง"]]]).tagColors
        check("ไลบรารีอื่นที่มีแท็กเดียวกัน ได้สีเดียวกัน",
              lone[Store.tagKey("ผู้หญิงร้อง")] == slots[Store.tagKey("ผู้หญิงร้อง")])
        check("ตัวพิมพ์เล็ก/ใหญ่ถือเป็นแท็กเดียวกัน",
              Store(rawForTest: ["a.mp3": ["tags": ["Pop"]]]).tagColor("pop")
                == Store(rawForTest: ["a.mp3": ["tags": ["pop"]]]).tagColor("POP"))
        // NOT equality any more. The cap used to BE the palette size, so that every tag had a
        // colour of its own; once the operator picks the colours, two tags sharing one is their
        // decision, and tying the numbers together would mean naming six colours REFUSED tags
        // that work today. Fewer colours than tags is allowed; more would be dead slots.
        check("เพดานแท็ก >= จำนวนสี", Store.tagsMaxDistinct >= Palette.tagSlots,
              "เพดาน \(Store.tagsMaxDistinct) / สี \(Palette.tagSlots)")
        // Over-subscribed: more distinct tags than colours. Every tag must still GET a colour —
        // the failure to avoid is a tag with no slot at all, or a crash from indexing past the
        // ramp, which is what the `% tagSlots` wrap in `Palette.tagFillAt` is for.
        var rawMany: [String: Any] = [:]
        let overSub = words + ["เร็ว", "ฮิตมาก", "เพลงประกอบ"]
        for (n, w) in overSub.enumerated() { rawMany["EP/m\(n).mp3"] = ["tags": [w]] }
        let manyStore = Store(rawForTest: rawMany)
        check("แท็กมากกว่าสี: ทุกแท็กยังได้สี", manyStore.tagColors.count == overSub.count,
              "\(manyStore.tagColors.count)/\(overSub.count)")
        check("แท็กมากกว่าสี: สีซ้ำได้ แต่ไม่หลุดช่วง",
              manyStore.tagColors.values.allSatisfy { $0 >= 0 && $0 < Palette.tagSlots })

        // ------- the operator's own choice
        print("\nเลือกสีเองได้ — และต้องไม่แตะอย่างอื่น")
        check("ชื่อสี = จำนวนช่อง", TagColor.allCases.count == Palette.tagSlots,
              "\(TagColor.allCases.count)/\(Palette.tagSlots)")
        let pick = Store(rawForTest: ["EP/1.mp3": ["tags": ["ยุค 90", "แร็ป"], "hook": 42.0]])
        let autoSlot = pick.tagColor("ยุค 90")
        let wanted = (autoSlot + 3) % Palette.tagSlots
        pick.setTagColor("ยุค 90", wanted)
        check("เลือกแล้วได้สีที่เลือก", pick.tagColor("ยุค 90") == wanted,
              "ขอ \(wanted) ได้ \(pick.tagColor("ยุค 90"))")
        check("สีที่เลือกถูกจดไว้", pick.tagColorChoice[Store.tagKey("ยุค 90")] == wanted)
        // The whole safety story for this field: it is a `_settings` write. `updateConfig`
        // stamps `configured = true, auto = false`, which would certify an unreviewed machine
        // guess as reviewed and drop the song out of the Return/Tab sweep and both pre-flight
        // warnings — §8g records that trap for the note, and a chip's colour is further still
        // from a decision about what goes to air.
        let after = pick.config(for: "EP/1.mp3")
        check("เลือกสีแล้วเพลงไม่ถูกแตะ",
              after.hook == 42.0 && !after.configured && after.tags.count == 2,
              "hook \(after.hook) configured \(after.configured) tags \(after.tags.count)")
        // A chosen slot is claimed BEFORE the hash runs, so the automatic half cannot sit on it.
        check("สีที่เลือกถูกจอง — แท็กอื่นไม่มาทับ",
              pick.tagColor("แร็ป") != wanted,
              "แร็ป ได้ \(pick.tagColor("แร็ป")) / จองไว้ \(wanted)")
        pick.setTagColor("ยุค 90", nil)
        check("ล้างแล้วกลับไปเป็นอัตโนมัติ", pick.tagColor("ยุค 90") == autoSlot
              && pick.tagColorChoice[Store.tagKey("ยุค 90")] == nil)
        pick.setTagColor("ยุค 90", Palette.tagSlots)         // one past the end
        pick.setTagColor("ยุค 90", -1)
        check("สลอตนอกช่วงถูกปฏิเสธ", pick.tagColorChoice[Store.tagKey("ยุค 90")] == nil)
        // The index is the wire format, so a file from a build with a longer ramp must not be
        // able to point past the end of ours.
        let fromFile = Store(rawForTest: [
            "_settings": ["tagColors": ["ยุค 90": 1, "แร็ป": 99, "ช้า": "x"]],
            "EP/1.mp3": ["tags": ["ยุค 90", "แร็ป", "ช้า"]],
        ])
        check("อ่านสีจากไฟล์: ค่าที่ใช้ได้ผ่าน, ค่าเพี้ยนถูกทิ้ง",
              fromFile.tagColorChoice == [Store.tagKey("ยุค 90"): 1],
              "\(fromFile.tagColorChoice)")
        check("ค่าเพี้ยนไม่ทำให้แท็กนั้นไม่มีสี",
              fromFile.tagColor("แร็ป") >= 0 && fromFile.tagColor("แร็ป") < Palette.tagSlots)

        // ------- across the handover (§8e)
        print("\nสีเดินทางไปกับ round.json — เติมเท่านั้น ไม่ลบของปลายทาง")
        let sender = Store(rawForTest: [
            "EP/a.mp3": ["tags": ["ยุค 90"]], "EP/b.mp3": ["tags": ["แร็ป"]],
            "EP/c.mp3": ["tags": ["ไม่อยู่ในรอบนี้"]],
        ])
        sender.setTagColor("ยุค 90", 2)
        sender.setTagColor("ไม่อยู่ในรอบนี้", 5)
        let pkg = Handoff.package(round: "EP", paths: ["EP/a.mp3", "EP/b.mp3"],
                                  store: sender, by: "test")
        check("ส่งสีของแท็กที่อยู่ในรอบ", pkg.tagColors[Store.tagKey("ยุค 90")] == 2)
        check("ไม่ส่งสีของแท็กที่ไม่ได้อยู่ในรอบ",
              pkg.tagColors[Store.tagKey("ไม่อยู่ในรอบนี้")] == nil, "\(pkg.tagColors)")
        check("ไม่ส่งแท็กที่ไม่ได้เลือกสีไว้ (สีจากชื่อคิดเองได้ทั้งสองเครื่อง)",
              pkg.tagColors[Store.tagKey("แร็ป")] == nil, "\(pkg.tagColors)")
        // Additive in one direction only: a local choice wins, and a tag MISSING from the
        // incoming set means "I have nothing to say", never "clear yours" (§8g).
        let receiver = Store(rawForTest: [
            "EP/a.mp3": ["tags": ["ยุค 90"]], "EP/b.mp3": ["tags": ["แร็ป"]],
        ])
        receiver.setTagColor("ยุค 90", 4)
        receiver.setTagColor("แร็ป", 1)
        let took = receiver.mergeTagColors(pkg.tagColors)
        check("ปลายทางเลือกไว้แล้ว ของตัวเองชนะ", receiver.tagColor("ยุค 90") == 4
              && took == 0, "ได้ \(receiver.tagColor("ยุค 90")) รับมา \(took)")
        check("แท็กที่ไม่ได้ส่งมา ไม่ถูกล้าง", receiver.tagColor("แร็ป") == 1)
        let blank = Store(rawForTest: ["EP/a.mp3": ["tags": ["ยุค 90"]]])
        check("ปลายทางยังไม่เลือก รับสีของผู้ส่ง",
              blank.mergeTagColors(pkg.tagColors) == 1 && blank.tagColor("ยุค 90") == 2,
              "ได้ \(blank.tagColor("ยุค 90"))")
        check("สลอตนอกช่วงที่มาจากไฟล์รอบ ถูกทิ้งตอน merge",
              Store(rawForTest: ["EP/a.mp3": ["tags": ["ยุค 90"]]])
                  .mergeTagColors([Store.tagKey("ยุค 90"): 99]) == 0)
        // The wire format itself, through real JSON. The one thing this suite writes, and it is
        // a file in the SYSTEM temp dir — never the project, never config.json.
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("rgf-tagtest-\(UUID().uuidString).json")
            try pkg.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let back = RoundPackage.read(tmp)
            check("round.json ไป-กลับ สีไม่หาย", back?.tagColors == pkg.tagColors,
                  "\(back?.tagColors ?? [:])")
        } catch {
            check("round.json ไป-กลับ สีไม่หาย", false, "\(error)")
        }

        print("\nผ่าน \(pass)  ตก \(fail)")
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }

    /// `--logotest`: the header logo's memo, and that it can be dropped.
    ///
    /// `ShowLogo.prepared` is memoised per process for a measured reason — `ContentView` is
    /// re-initialised on every model publish and the header re-renders at the player's tick
    /// rate, so reading the disk from `body` would `stat` and decode 50 times a second (§6e).
    /// It was a `static let`, which made that memo permanent, and on a FIRST run on a machine
    /// with no library the memo is taken BEFORE `Seeding.run` has anywhere to copy the logo to
    /// — so the logo did not appear until the app was relaunched. Reported from the first
    /// install on a second machine.
    ///
    /// Two properties, pulling in opposite directions, which is why both are asserted: the memo
    /// must HOLD across reads, and `invalidate()` must genuinely RE-READ. Neither is visible in
    /// a screenshot, and quietly losing the first one is a 50 Hz disk read in the header.
    ///
    /// Identity is the discriminator: `Prepared.image` is an `NSImage`, a class, so getting the
    /// same instance back proves nothing was loaded again.
    ///
    /// What this does NOT cover is the end-to-end path — no library, choose a folder, logo
    /// appears without a relaunch. Pointing the real data root at a fixture is the one thing
    /// `--roottest` refuses to do on purpose, so that half stays a hand-test on a fresh machine.
    static func logoTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }
        print("ไฟล์โลโก้: \(ShowLogo.brandFile.path)")
        guard let first = ShowLogo.prepared else {
            // NOT a pass. A data folder with no `brand/logo.png` cannot answer the question this
            // suite exists for, and §12's rule is that "I could not check this" must not exit 0.
            cannotRun("ไม่มี brand/logo.png ในโฟลเดอร์งานนี้ — ตรวจ memo ไม่ได้")
            return
        }

        print("\n1) จำไว้แล้วต้องไม่อ่านดิสก์ซ้ำ")
        let again = ShowLogo.prepared
        check("อ่านครั้งที่สองได้ instance เดิม", again?.image === first.image)
        check("ขนาดที่จะวาดเท่าเดิม", again?.size == first.size,
              String(format: "%.1f x %.1f pt", first.size.width, first.size.height))
        check("สูงไม่เกินกรอบ header", first.size.height <= ShowLogo.height + 0.5)
        check("กว้างไม่เกินเพดาน", first.size.width <= ShowLogo.maxWidth + 0.5)

        print("\n2) invalidate() ต้องทำให้อ่านใหม่จริง")
        ShowLogo.invalidate()
        let after = ShowLogo.prepared
        check("ได้ instance ใหม่ = อ่านไฟล์ซ้ำจริง", after?.image !== first.image)
        check("ยังหาไฟล์เจอ ได้ขนาดเดิม", after?.size == first.size)

        print("\n3) memo กลับมาทำงานหลัง invalidate")
        check("อ่านอีกครั้งได้ instance เดิม", ShowLogo.prepared?.image === after?.image)

        verdict(fail == 0, "\n✓ ผ่าน \(pass)",
                "\n✗ ไม่ผ่าน — ผ่าน \(pass) ตก \(fail)")
    }

    /// `--foldtest`: the column-fold decision table (§8c).
    ///
    /// `ColumnFold.decide` is pure for the reason `MarkerGrab.decide` and
    /// `FocusRelease.shouldRelease` are — a click on a column header cannot be driven headlessly,
    /// and §6c forbids synthetic keystrokes against the running app. So the decision is what gets
    /// proved; that the UI calls it is not something a check here can establish.
    static func foldTest() {
        var pass = 0, fail = 0
        func check(_ label: String, _ got: ColumnFold.Outcome, _ want: ColumnFold.Outcome) {
            let ok = got == want
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(ok ? "" : "  — ได้ \(got) ควรเป็น \(want)")")
        }
        func d(_ i: Int, _ collapsed: Bool, _ folded: Set<Int>, sel: Int?) -> ColumnFold.Outcome {
            ColumnFold.decide(index: i, collapsed: collapsed, folded: folded,
                              selectionColumn: sel, columns: 3)
        }

        print("1) ปกติ")
        check("พับคอลัมน์ว่าง ไม่มี selection", d(1, true, [], sel: 0), .fold)
        check("เปิดคืนคอลัมน์ที่พับไว้", d(1, false, [1], sel: 0), .unfold)
        check("พับหนึ่ง เหลืออีกสอง", d(2, true, [1], sel: 0), .fold)

        print("\n2) ห้ามพับคอลัมน์ที่มีเพลงที่เลือก (§8g)")
        check("selection อยู่ในคอลัมน์นั้น", d(0, true, [], sel: 0), .refuseHoldsSelection)
        check("แม้มีอีกสองคอลัมน์เปิดอยู่ก็ห้าม", d(2, true, [], sel: 2), .refuseHoldsSelection)
        check("ไม่มี selection เลย พับได้", d(0, true, [], sel: nil), .fold)

        print("\n3) ห้ามพับคอลัมน์สุดท้ายที่เปิดอยู่")
        check("พับไปสองแล้ว พับที่สามไม่ได้", d(2, true, [0, 1], sel: nil), .refuseLastExpanded)
        check("เหตุผล selection มาก่อน เพราะแก้ได้", d(2, true, [0, 1], sel: 2),
              .refuseHoldsSelection)
        check("เปิดคืนไม่เคยถูกห้าม แม้พับหมด", d(0, false, [0, 1, 2], sel: nil), .unfold)

        print("\n4) สั่งซ้ำสิ่งที่เป็นอยู่แล้ว = ไม่ทำอะไร")
        check("พับสิ่งที่พับไว้อยู่", d(1, true, [1], sel: 0), .noop)
        check("เปิดสิ่งที่เปิดอยู่", d(1, false, [], sel: 0), .noop)
        check("index นอกช่วง", d(7, true, [], sel: nil), .noop)
        check("index ติดลบ", d(-1, true, [], sel: nil), .noop)

        print("\n5) ความกว้างคอลัมน์ (ColumnLayout)")
        let total: CGFloat = 898, rail = AppModel.collapsedColWidth
        func W(_ fr: [Double], _ fo: Set<Int>) -> [CGFloat] {
            ColumnLayout.widths(fractions: fr, folded: fo, total: total, railWidth: rail,
                                columns: 3)
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.05) -> Bool { abs(a - b) < eps }
        func ck(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok  " : "✗   ")\(label)\(detail.isEmpty ? "" : "  — " + detail)")
        }
        let even = ColumnLayout.evenFractions(3)
        let w0 = W(even, [])
        ck("สามส่วนเท่ากัน รวมเต็มแผง", near(w0.reduce(0, +), total) && near(w0[0], w0[2]),
           String(format: "%.1f / %.1f / %.1f", w0[0], w0[1], w0[2]))
        let wf = W(even, [1])
        ck("พับกลาง — รางเท่าราง ที่เหลือหารสอง",
           near(wf[1], rail) && near(wf[0], wf[2]) && near(wf.reduce(0, +), total),
           String(format: "%.1f / %.1f / %.1f", wf[0], wf[1], wf[2]))
        ck("พับสอง — อีกอันได้ที่เหลือหมด",
           near(W(even, [1, 2])[0], total - 2 * rail))
        ck("ไม่มีคอลัมน์ไหนแคบกว่าพื้น", w0.allSatisfy { $0 >= ColumnLayout.minWidth - 0.01 })

        for dx in [CGFloat(50), -50, 400, -400] {
            guard let nf = ColumnLayout.drag(after: 0, dx: dx, fractions: even, folded: [],
                                             total: total, railWidth: rail, columns: 3) else {
                ck("ลาก \(Int(dx)) pt — คืนค่ามา", false, "ได้ nil"); continue
            }
            let w = W(nf, [])
            let want = min(max(ColumnLayout.minWidth, w0[0] + dx), w0[0] + w0[1] - ColumnLayout.minWidth)
            ck("ลาก \(Int(dx)) pt — กว้างขึ้นเท่าที่ลาก", near(w[0], want, 0.2),
               String(format: "ได้ %.1f ควร %.1f", w[0], want))
            ck("ลาก \(Int(dx)) pt — อีกคอลัมน์ไม่ขยับ", near(w[2], w0[2], 0.2),
               String(format: "ได้ %.1f ควร %.1f", w[2], w0[2]))
            ck("ลาก \(Int(dx)) pt — รวมยังเต็มแผง", near(w.reduce(0, +), total, 0.2))
        }
        ck("ด้ามกลางพับ — ไม่มีหูจับข้างมัน",
           !ColumnLayout.handleAfter(0, folded: [1], columns: 3)
           && !ColumnLayout.handleAfter(1, folded: [1], columns: 3))
        ck("ด้านหน้าพับ — หูจับ 1|2 ยังอยู่",
           ColumnLayout.handleAfter(1, folded: [0], columns: 3)
           && !ColumnLayout.handleAfter(0, folded: [0], columns: 3))
        ck("หูจับสุดท้ายไม่มี", !ColumnLayout.handleAfter(2, folded: [], columns: 3))
        ck("ลากหูจับที่ไม่มี — คืน nil",
           ColumnLayout.drag(after: 0, dx: 50, fractions: even, folded: [1], total: total,
                             railWidth: rail, columns: 3) == nil)

        print("\n6) ความกว้างสามแผง (PaneLayout)")
        let edges = ColumnEdge.width * 2
        func P(_ win: CGFloat, _ fr: [Double] = PaneLayout.defaultFractions) -> [CGFloat] {
            PaneLayout.widths(fractions: fr, total: win - edges)
        }
        for win in [CGFloat(1100), 1440, 1900, 2518] {
            let w = P(win)
            ck("หน้าต่าง \(Int(win)) — รวมพอดีและไม่ต่ำกว่าพื้น",
               near(w.reduce(0, +), win - edges, 0.2)
               && (0..<3).allSatisfy { w[$0] >= PaneLayout.floors[$0] - 0.01 },
               String(format: "%.0f / %.0f / %.0f", w[0], w[1], w[2]))
        }
        // The declared minimum window must leave every floor intact, or AppKit can produce a
        // window this layout cannot honour.
        ck("พื้นรวมกัน + หูจับ ≤ minWidth 1100",
           PaneLayout.floors.reduce(0, +) + edges <= 1100,
           String(format: "%.0f", PaneLayout.floors.reduce(0, +) + edges))
        // **LITERALS, deliberately.** The per-window checks above compare each width against
        // `PaneLayout.floors`, i.e. against the constant they are meant to be testing — so
        // setting the floors to zero moved the goalposts and the whole suite stayed green at
        // 52/52. Found by running the negative control. The `Palette.audit` lesson in a third
        // costume: an assertion that reads the value it checks cannot fail.
        //
        // These numbers are the measured minimums, written out: a list row's 2-line clamped
        // title with its tag chips and note line (240), §12's 378 pt centre pane that was broken
        // with the floor set above it (480), and the SETUP marker cards (300).
        ck("พื้นของแต่ละแผงไม่ต่ำกว่าที่วัดไว้",
           PaneLayout.floors.count == 3 && PaneLayout.floors[0] >= 240
           && PaneLayout.floors[1] >= 480 && PaneLayout.floors[2] >= 300,
           String(format: "%.0f / %.0f / %.0f", PaneLayout.floors[0], PaneLayout.floors[1],
                  PaneLayout.floors[2]))
        let wMin = P(1100)
        ck("ที่หน้าต่างแคบสุด ไม่มีแผงไหนแคบกว่าค่าที่วัดไว้",
           wMin[0] >= 240 && wMin[1] >= 480 && wMin[2] >= 300,
           String(format: "%.0f / %.0f / %.0f", wMin[0], wMin[1], wMin[2]))
        // Same shape for the drag: a literal bound, so a floor of zero cannot let a pane vanish.
        if let nf = PaneLayout.drag(after: 0, dx: 5000, fractions: PaneLayout.defaultFractions,
                                    total: 1100 - edges) {
            let w = P(1100, nf)
            ck("ลากสุดแรง — แผงกลางยังไม่ต่ำกว่า 480", w[1] >= 480,
               String(format: "%.0f / %.0f / %.0f", w[0], w[1], w[2]))
        } else {
            ck("ลากสุดแรง — แผงกลางยังไม่ต่ำกว่า 480", false, "ได้ nil")
        }

        let w19 = P(1900)
        for dx in [CGFloat(120), -120, 900, -900] {
            guard let nf = PaneLayout.drag(after: 0, dx: dx, fractions: PaneLayout.defaultFractions,
                                           total: 1900 - edges) else {
                ck("ลากแผง \(Int(dx)) pt", false, "ได้ nil"); continue
            }
            let w = P(1900, nf)
            let want = min(max(PaneLayout.floors[0], w19[0] + dx),
                           w19[0] + w19[1] - PaneLayout.floors[1])
            ck("ลากแผง \(Int(dx)) pt — กว้างตามที่ลาก", near(w[0], want, 0.3),
               String(format: "ได้ %.1f ควร %.1f", w[0], want))
            ck("ลากแผง \(Int(dx)) pt — แผงขวาไม่ขยับ", near(w[2], w19[2], 0.3))
            ck("ลากแผง \(Int(dx)) pt — ไม่ต่ำกว่าพื้น",
               (0..<3).allSatisfy { w[$0] >= PaneLayout.floors[$0] - 0.01 })
        }
        ck("หูจับสุดท้ายไม่มี",
           PaneLayout.drag(after: 2, dx: 50, fractions: PaneLayout.defaultFractions,
                           total: 1900 - edges) == nil)
        ck("fraction เสีย/ไม่ครบ → คืนค่าเริ่มต้น",
           PaneLayout.normalised([Double.nan, 1, 1]) == PaneLayout.normalised([0, 1, 1])
           && PaneLayout.normalised(nil) == PaneLayout.defaultFractions
           && PaneLayout.normalised([1, 2]) == PaneLayout.defaultFractions)

        verdict(fail == 0, "\n✓ ผ่าน \(pass)",
                "\n✗ ไม่ผ่าน — ผ่าน \(pass) ตก \(fail)")
    }

}

// MARK: - Verdict, and the process exit code

extension Diagnostics {
    /// Set by any suite that prints a FAILING verdict. Read by `App` to pick the exit code.
    nonisolated(unsafe) static var sawFailure = false

    /// Every suite's verdict goes through here, so the PROCESS EXIT CODE can reflect it.
    ///
    /// `App.swift` had 32 `exit(0)` and zero `exit(1)`: every diagnostic in this project exited
    /// 0 whatever it found. `INTROPLAYER_DIAG=1 $BIN --remodetest && echo ok` printed `ok` with
    /// the intro-end guard deliberately broken, so none of these checks could fail a script, a
    /// release step or a pre-push hook — they could only be read by a human who remembered to
    /// look. §12's `--loudtest` lesson is that a suite which cannot report its verdict reads
    /// exactly like one that passed; this was the same hole one level out, for all of them.
    ///
    /// The strings are passed through untouched so no suite's wording, leading newline or
    /// trailing explanation changes.
    @discardableResult
    static func verdict(_ ok: Bool, _ good: String, _ bad: String) -> Bool {
        if !ok { sawFailure = true }
        print(ok ? good : bad)
        return ok
    }

    /// "I could not check this" — which is NOT "this is fine", and must not exit 0.
    ///
    /// `--remodetest` and `--overview` are the only end-to-end checks of the intro-end stop and
    /// of the waveform the markers are placed on, and both opened with
    /// `guard let s = songs.first else { print("no songs"); return }`. On a fresh clone, in CI,
    /// or on a `/Applications` install before the operator has pointed the app at a library,
    /// they printed one line and exited 0 — indistinguishable from a pass, on the two checks it
    /// matters most to have actually run.
    static func cannotRun(_ why: String) {
        sawFailure = true
        print("✗ ตรวจไม่ได้ — \(why)")
    }

    static var exitCode: Int32 { sawFailure ? 1 : 0 }
}
