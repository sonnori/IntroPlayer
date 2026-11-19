import Foundation

/// What a feed told us about a newer build.
struct UpdateInfo: Equatable {
    var version: String
    var notes: String
    /// Where the zip is. An `https://` URL, or an absolute path inside a synced folder.
    var download: String
    /// Minimum macOS the new build needs, or "" if the manifest didn't say.
    var minMacOS: String

    /// This machine's macOS as a comparable dotted string.
    static var runningOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The new build needs a newer macOS than this machine has.
    ///
    /// Displaying `minMacOS` and leaving it at that was a trap: the operator would run the
    /// installer, which replaces a WORKING bundle with one that cannot launch, on the machine
    /// that plays audio on camera — and the way back is a `backups/<timestamp>/` folder a
    /// non-technical person will not find unaided.
    var needsNewerOS: Bool {
        !minMacOS.isEmpty && AppVersion.compare(minMacOS, UpdateInfo.runningOS) > 0
    }

    /// Is `download` something we are willing to hand to the system?
    ///
    /// The manifest is a file from outside this app, so the guard lives HERE rather than at the
    /// call site. It used to be split: the URL branch checked the scheme, the path branch
    /// checked nothing — so `download: "/Applications/Anything.app"` was openable, and the only
    /// thing making that safe was `openUpdateDownload` happening to use
    /// `activateFileViewerSelecting` for file URLs. The comment claimed the type was safe while
    /// the safety lived in the caller; anyone simplifying the caller would have followed the
    /// comment straight into "a manifest can launch an arbitrary app".
    ///
    /// A local path must therefore be a `.zip` — a release, not an executable. Remote links are
    /// `http`/`https` only.
    var openable: URL? {
        if isLocalFile {
            let p = (download as NSString).expandingTildeInPath
            guard (p as NSString).pathExtension.lowercased() == "zip" else { return nil }
            return URL(fileURLWithPath: p)
        }
        guard let u = URL(string: download), let s = u.scheme?.lowercased(),
              s == "https" || s == "http" else { return nil }
        return u
    }
    var isLocalFile: Bool { download.hasPrefix("/") || download.hasPrefix("~") }
}

/// Checking whether a newer build exists.
///
/// **This never downloads and never installs.** Replacing an unsigned app bundle while it is
/// running is a Gatekeeper and reliability minefield, and doing it unattended on a taping machine
/// is unthinkable — the app plays audio on camera. The check only ever raises a banner; the swap
/// is a deliberate double-click on the installer, with the app quit (§15).
///
/// The feed is channel-agnostic on purpose: a crew will use whatever they already have. An
/// `https://` URL works, and so does an absolute path into a synced Drive/Dropbox folder, which
/// needs no network at all — and the machine this runs on is offline on set by design (§2).
enum Updater {
    /// Short, because a dead feed must never be something the operator waits on.
    static let timeout: TimeInterval = 5

    /// `URLRequest.timeoutInterval` is an **idle** timeout, and `URLSession.shared` inherits
    /// `timeoutIntervalForResource` = 7 days — so a server that dribbles a byte every few seconds
    /// keeps the request alive indefinitely. That left `updateChecking` stuck true for the rest
    /// of the session, with both check buttons disabled and no recovery short of a relaunch.
    /// This session puts a real deadline on the whole call.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldUsePipelining = true
        return URLSession(configuration: c)
    }()

    enum Failure: LocalizedError {
        case noFeed
        case unreadable(String)
        case badManifest(String)

        var errorDescription: String? {
            switch self {
            case .noFeed: return "ยังไม่ได้ตั้งที่อยู่สำหรับเช็กเวอร์ชั่น"
            case .unreadable(let s): return "อ่านไม่ได้: \(s)"
            case .badManifest(let s): return "ไฟล์เวอร์ชั่นผิดรูปแบบ: \(s)"
            }
        }
    }

    /// Resolves a feed string to the manifest's location.
    ///
    /// **Purely syntactic — it must not touch the filesystem.** `AboutPanel` calls this from
    /// `body` to show the "จะอ่านจาก:" preview, and that body is invalidated by every `AppModel`
    /// publish, i.e. ~50x/s while playing (the guard timer, §8b). The earlier version probed with
    /// `fileExists(atPath:isDirectory:)` to decide folder-vs-file, which on the headline use case
    /// — a path into `~/Library/CloudStorage/GoogleDrive-…` — is a `stat()` serviced by a
    /// userspace FileProvider extension. A stalled or re-authenticating extension would have
    /// blocked the MAIN THREAD once per frame: frozen UI, dead key monitor, no pause, no scoring.
    /// It also meant a Drive folder that was unmounted at launch resolved differently than when
    /// the operator saved it.
    ///
    /// The rule: a path or URL already ending in `.json` is the manifest; **a URL carrying a
    /// query or fragment is left exactly as given** — that is a share or direct-download link and
    /// appending a path component to it produces nonsense (a Dropbox `?rlkey=…` link became
    /// `…/abc/manifest.json?rlkey=…` → 404, with nothing telling the operator we had rewritten
    /// their URL); anything else is treated as a folder. The About sheet shows the result, so a
    /// wrong guess is visible rather than silent.
    static func manifestLocation(_ feed: String) -> URL? {
        let f = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return nil }
        if f.hasPrefix("/") || f.hasPrefix("~") {
            let p = (f as NSString).expandingTildeInPath
            let u = URL(fileURLWithPath: p)
            if u.pathExtension.lowercased() == "json" { return u }
            return u.appendingPathComponent("manifest.json")
        }
        guard var u = URL(string: f), let s = u.scheme?.lowercased(),
              s == "https" || s == "http", u.host != nil else { return nil }
        if u.pathExtension.lowercased() == "json" { return u }
        // A query or fragment means the operator pasted a link, not a folder. Leave it alone.
        if let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
           c.query != nil || c.fragment != nil { return u }
        u.appendPathComponent("manifest.json")
        return u
    }

    /// Fetches the manifest and returns it only when it names a build newer than this one.
    /// `nil` means "already up to date" — a quiet, expected result, not an error.
    static func check(feed: String) async throws -> UpdateInfo? {
        guard let loc = manifestLocation(feed) else { throw Failure.noFeed }
        let data: Data
        if loc.isFileURL {
            // Missing and unreadable need different answers from the operator — one is "the feed
            // folder hasn't synced yet", the other is a permissions problem. Naming the file
            // (`lastPathComponent`) told them neither.
            guard FileManager.default.fileExists(atPath: loc.path) else {
                throw Failure.unreadable("ไม่พบไฟล์ manifest.json ตามที่อยู่นี้ (โฟลเดอร์ sync เสร็จแล้วหรือยัง?)")
            }
            do { data = try Data(contentsOf: loc) }
            catch { throw Failure.unreadable("เปิดไฟล์ไม่ได้ — สิทธิ์โฟลเดอร์?") }
        } else {
            var r = URLRequest(url: loc)
            r.timeoutInterval = timeout
            // A CDN or Drive cache would otherwise keep serving the version we already have.
            r.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (d, resp) = try await Updater.session.data(for: r)
                if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
                    throw Failure.unreadable("HTTP \(h.statusCode)")
                }
                data = d
            } catch let e as Failure { throw e }
            catch { throw Failure.unreadable(error_message(error)) }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badManifest("ไม่ใช่ JSON")
        }
        // Capped like the rest. `parts()` ignores trailing junk, so "9.0.0" + a megabyte of
        // padding compared as NEWER and that megabyte was interpolated straight into
        // `UpdateBanner`'s Text — in the MAIN window, over the transport.
        guard let raw = (obj["version"] as? String)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else {
            throw Failure.badManifest("ไม่มี version")
        }
        let v = String(raw.prefix(24))
        guard AppVersion.isNewer(v) else { return nil }
        // Capped: the notes are text from outside the app and go straight into a sheet. A runaway
        // string must not be able to push the buttons off screen.
        let notes = String((obj["notes"] as? String ?? "").prefix(1200))
        return UpdateInfo(version: v,
                          notes: notes,
                          download: String((obj["download"] as? String ?? "").prefix(500)),
                          minMacOS: String((obj["minMacOS"] as? String ?? "").prefix(16)))
    }

    private static func error_message(_ e: Error) -> String {
        (e as? URLError).map { u -> String in
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "ไม่มีอินเทอร์เน็ต"
            case .timedOut: return "หมดเวลารอ"
            case .cannotFindHost, .cannotConnectToHost: return "ต่อเซิร์ฟเวอร์ไม่ได้"
            default: return u.localizedDescription
            }
        } ?? e.localizedDescription
    }
}

/// A breadcrumb so the installer can find the folder with no questions asked.
///
/// The installer has to replace the bundle *inside* the operator's project folder — the one with
/// their `songs/` and `config.json` next to it (§5) — and it arrives from a zip knowing nothing
/// about where that is. A folder picker would work and is the fallback, but asking a non-technical
/// operator to navigate to the right directory is exactly the step that puts a new app beside the
/// wrong data. Written on every launch, because the folder can be moved.
enum InstallLocation {
    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntroPlayer")
        return base.appendingPathComponent("location")
    }

    /// Temp roots. A build run from one of these is a test or a throwaway copy, never the
    /// operator's install — and this is not hypothetical: a sandboxed verification run of this
    /// very feature pointed the breadcrumb at a scratch folder which, because the fixture had
    /// both `config.json` and `songs/`, passed the installer's `valid_target` check. The
    /// installer would then have offered to update a temp directory, written the backup there,
    /// and left the real folder stale — exactly the "I installed the new one but nothing
    /// changed" symptom §15 exists to kill.
    private static let transientRoots = ["/private/tmp/", "/tmp/", "/private/var/folders/",
                                         "/var/folders/", "/Volumes/"]

    static func record() {
        let root = AppPaths.root.path
        guard !transientRoots.contains(where: { root.hasPrefix($0) }) else { return }
        // A bundle opened from a Downloads folder or an unzipped release has neither of these.
        // The installer writes the breadcrumb itself on a fresh install, so nothing is lost by
        // declining to guess here.
        let fm = FileManager.default
        guard fm.fileExists(atPath: AppPaths.config.path)
                || fm.fileExists(atPath: AppPaths.songs.path) else { return }
        let f = file
        do {
            try fm.createDirectory(at: f.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try (root + "\n").write(to: f, atomically: true, encoding: .utf8)
        } catch {
            // Entirely best-effort: the installer falls back to asking. Nothing in the app
            // depends on this file existing, so a sandboxed or read-only home is not an error
            // worth putting in front of the operator.
        }
    }
}
