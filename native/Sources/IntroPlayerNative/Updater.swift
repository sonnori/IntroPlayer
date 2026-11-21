import CryptoKit
import Foundation

/// What a feed told us about a newer build.
struct UpdateInfo: Equatable {
    var version: String
    var notes: String
    /// Where the zip is. An `https://` URL, or an absolute path inside a synced folder.
    var download: String
    /// Minimum macOS the new build needs, or "" if the manifest didn't say.
    var minMacOS: String
    /// Optional SHA-256 of the zip. Checked before anything is unpacked — it catches the
    /// realistic failure, which is a truncated download or a half-synced Drive file, not an
    /// attacker (whoever can replace the zip can replace the manifest beside it).
    var sha256: String = ""

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
        case noRelease(String)

        var errorDescription: String? {
            switch self {
            case .noFeed: return "ยังไม่ได้ตั้งที่อยู่สำหรับเช็กเวอร์ชั่น"
            case .unreadable(let s): return "อ่านไม่ได้: \(s)"
            case .badManifest(let s): return "ไฟล์เวอร์ชั่นผิดรูปแบบ: \(s)"
            case .noRelease(let s): return "GitHub: \(s)"
            }
        }
    }

    /// What the feed string points at.
    ///
    /// GitHub Releases is its own kind rather than a `manifest.json` URL because the shape of the
    /// answer is different — a release object, not our schema — and because it removes the step
    /// that is easiest to get wrong by hand: there is no manifest to keep in step with the zip.
    /// `gh release create` publishes both at once (see `release.sh --github`).
    enum Feed {
        case manifest(URL)
        case github(owner: String, repo: String)

        /// What to show the operator under the field.
        var describe: String {
            switch self {
            case .manifest(let u): return u.isFileURL ? u.path : u.absoluteString
            case .github(let o, let r): return "GitHub Releases ของ \(o)/\(r)"
            }
        }
    }

    /// Accepts `owner/repo`, `github.com/owner/repo`, or a full
    /// `https://github.com/owner/repo[/releases...]` URL.
    ///
    /// Two components exactly for the bare shorthand, and only a `github.com` URL may carry
    /// more. Without that rule a Drive path pasted without its leading slash —
    /// `Users/someone/Library/CloudStorage/…` — parsed as the repo `Users/someone`, which is a
    /// plausible typo that would have sent every version check to a stranger's repository.
    static func githubRepo(_ feed: String) -> (owner: String, repo: String)? {
        var t = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("/"), !t.hasPrefix("~") else { return nil }

        var sawHost = false
        for p in ["https://", "http://"] where t.lowercased().hasPrefix(p) {
            t = String(t.dropFirst(p.count))
        }
        for p in ["www.github.com/", "github.com/"] where t.lowercased().hasPrefix(p) {
            t = String(t.dropFirst(p.count))
            sawHost = true
            break
        }
        // Any other scheme or host is not a GitHub shorthand — let the manifest forms have it.
        if !sawHost && (t.contains("://") || t.split(separator: "/").first?.contains(".") == true) {
            return nil
        }

        let parts = t.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, sawHost || parts.count == 2 else { return nil }
        var owner = parts[0], repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        owner = owner.trimmingCharacters(in: .whitespaces)
        repo = repo.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !repo.isEmpty, !owner.contains(".") else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard owner.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              repo.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return (owner, repo)
    }

    static func feedKind(_ feed: String) -> Feed? {
        if let gh = githubRepo(feed) { return .github(owner: gh.owner, repo: gh.repo) }
        if let u = manifestLocation(feed) { return .manifest(u) }
        return nil
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
        switch feedKind(feed) {
        case .none: throw Failure.noFeed
        case .github(let owner, let repo): return try await checkGitHub(owner: owner, repo: repo)
        case .manifest(let loc): return try await checkManifest(at: loc)
        }
    }

    /// GitHub Releases. Public repos only — a private one would need a token, and a token on a
    /// crew machine is a credential nobody is managing.
    static func checkGitHub(owner: String, repo: String) async throws -> UpdateInfo? {
        let api = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let u = URL(string: api) else { throw Failure.noFeed }
        var r = URLRequest(url: u)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub rejects requests with no User-Agent. Deliberately just the app and its version:
        // no machine name, no account, nothing about who is running it.
        r.setValue("IntroPlayer/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (d, resp) = try await session.data(for: r)
            if let h = resp as? HTTPURLResponse {
                switch h.statusCode {
                case 200...299: break
                case 404: throw Failure.noRelease("ไม่พบ repo \(owner)/\(repo) หรือยังไม่มี release")
                case 403, 429:
                    throw Failure.noRelease("ถูกจำกัดจำนวนครั้ง (GitHub rate limit) — ลองใหม่อีกชั่วโมง")
                default: throw Failure.unreadable("HTTP \(h.statusCode)")
                }
            }
            data = d
        } catch let e as Failure { throw e }
        catch { throw Failure.unreadable(error_message(error)) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badManifest("GitHub ตอบมาไม่ใช่ JSON")
        }
        guard let tag = (obj["tag_name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !tag.isEmpty else {
            throw Failure.noRelease("release ล่าสุดไม่มี tag")
        }
        // `v1.2.0` and `1.2.0` are both normal ways to tag a release.
        var v = tag
        if v.lowercased().hasPrefix("v") { v = String(v.dropFirst()) }
        v = String(v.prefix(24))
        guard AppVersion.isNewer(v) else { return nil }

        // The .zip asset. A release may also carry SHA256SUMS or other files, and asset order
        // is whatever the API feels like — so prefer one that names this app before falling back
        // to "the first zip".
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        let zips = assets.filter {
            (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip")
        }
        let zip = zips.first {
            (($0["name"] as? String) ?? "").lowercased().contains("introplayer")
        } ?? zips.first
        guard let dl = (zip?["browser_download_url"] as? String), !dl.isEmpty else {
            throw Failure.noRelease("release \(tag) ไม่มีไฟล์ .zip แนบมา")
        }
        // GitHub reports asset digests as "sha256:<hex>" where available. Optional either way.
        var sha = ""
        if let d = zip?["digest"] as? String, d.lowercased().hasPrefix("sha256:") {
            sha = String(d.dropFirst("sha256:".count))
        }
        return UpdateInfo(version: v,
                          notes: String(((obj["body"] as? String) ?? "")
                              .trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200)),
                          download: String(dl.prefix(500)),
                          minMacOS: "13.0",
                          sha256: sha.trimmingCharacters(in: .whitespaces))
    }

    private static func checkManifest(at loc: URL) async throws -> UpdateInfo? {
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
                          minMacOS: String((obj["minMacOS"] as? String ?? "").prefix(16)),
                          sha256: String((obj["sha256"] as? String ?? "").prefix(64))
                              .trimmingCharacters(in: .whitespaces))
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

// MARK: - installing from inside the app (§15)

/// Download → verify → hand the swap to the installer → quit → it relaunches us.
///
/// The app cannot replace its own running bundle, so the last step has to be another process.
/// That process is the SAME `ติดตั้ง-อัปเดต.command` the manual path uses, run with
/// `--unattended`: the backups, the checked `rm`, the full rollback and the
/// "ask the installed binary its version before claiming success" check are all reused rather
/// than reimplemented, and they are what the 79 assertions cover.
///
/// One happy side effect worth knowing: this path **has no Gatekeeper step at all**. Quarantine
/// is applied by whatever downloads a file — a browser, Drive's client — not by the kernel. A zip
/// that this app's own `URLSession` writes carries no flag, so the staged bundle runs and the
/// installed one opens with no right-click → Open and no trip to System Settings.
extension Updater {
    enum Install: LocalizedError {
        case noDownload
        case unpack(String)
        case wrongVersion(got: String, want: String)
        case badChecksum
        case missingInstaller
        case launch(String)

        var errorDescription: String? {
            switch self {
            case .noDownload:   return "ชุดอัปเดตนี้ไม่ได้บอกที่อยู่ไฟล์"
            case .unpack(let s): return "แตกไฟล์ไม่ได้ — \(s)"
            case .wrongVersion(let g, let w):
                return "ไฟล์ที่โหลดมาเป็นเวอร์ชั่น \(g.isEmpty ? "ที่อ่านไม่ออก" : g) ไม่ใช่ \(w) — ยกเลิกแล้ว"
            case .badChecksum:  return "ไฟล์ที่โหลดมาไม่ครบ (checksum ไม่ตรง) — โหลดใหม่"
            case .missingInstaller: return "ในชุดอัปเดตไม่มีตัวติดตั้ง"
            case .launch(let s): return "เรียกตัวติดตั้งไม่ได้ — \(s)"
            }
        }
    }

    static let installerName = "ติดตั้ง-อัปเดต.command"
    /// Where the installer writes what it did, so a failed unattended run is not silent.
    static var installLog: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/IntroPlayer-update.log")
    }

    /// A fresh scratch directory for one attempt. Under the system temp dir, so a crash mid-way
    /// leaves nothing in the operator's folder.
    static func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntroPlayerUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Gets the zip into `dir`. A feed in a synced folder is already on disk, so that case is a
    /// copy and needs no network — the same reason the folder form is the recommended channel.
    /// `onProgress` is deliberately **not** `@MainActor`. `fetchZip` is a non-isolated async
    /// func, so it runs on the generic executor — and a main-actor callback from here would
    /// deadlock any caller that is blocking the main thread waiting for the download, which is
    /// exactly what a headless diagnostic does. The UI caller hops to main itself.
    static func fetchZip(_ info: UpdateInfo, into dir: URL,
                         onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard let src = info.openable else { throw Install.noDownload }
        let dest = dir.appendingPathComponent("release.zip")

        if src.isFileURL {
            onProgress(-1)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw Install.unpack("ยังไม่มีไฟล์ในโฟลเดอร์นั้น — รอ sync ให้เสร็จ")
            }
            try FileManager.default.copyItem(at: src, to: dest)
            onProgress(1)
            return dest
        }

        var r = URLRequest(url: src)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        // A download is minutes, not seconds, so it does NOT use the 5 s check session.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 900
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let (stream, resp) = try await session.bytes(for: r)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            throw Install.unpack("HTTP \(h.statusCode)")
        }
        let total = resp.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dest) else {
            throw Install.unpack("เขียนไฟล์ชั่วคราวไม่ได้")
        }
        defer { try? fh.close() }

        var buf = Data(capacity: 1 << 16)
        var got: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in stream {
            buf.append(byte)
            if buf.count >= 1 << 16 {
                try fh.write(contentsOf: buf)
                got += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                // Throttled: the progress bar is in a sheet whose body is already re-evaluated by
                // every model publish, and reporting per 64 KB chunk of a 2 MB file is plenty.
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    let f = total > 0 ? Double(got) / Double(total) : -1
                    onProgress(f)
                }
            }
            try Task.checkCancellation()
        }
        if !buf.isEmpty { try fh.write(contentsOf: buf); got += Int64(buf.count) }
        onProgress(1)
        return dest
    }

    /// Unpacks, then **proves the thing we are about to install is what the manifest promised**.
    ///
    /// This is the check that makes a one-click update defensible: a truncated download, a stale
    /// zip left in a Drive folder, or a manifest pointing at the wrong file all end here with the
    /// operator's working app untouched, rather than at the swap.
    static func stage(zip: URL, in dir: URL, expecting info: UpdateInfo) throws -> URL {
        if !info.sha256.isEmpty {
            guard let data = try? Data(contentsOf: zip) else { throw Install.unpack("อ่านไฟล์ไม่ได้") }
            guard sha256Hex(data) == info.sha256.lowercased() else { throw Install.badChecksum }
        }
        let out = dir.appendingPathComponent("unpacked")
        // ditto, not unzip: it is what macOS itself uses and it preserves the bundle's modes.
        let (code, err) = try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard code == 0 else { throw Install.unpack(err.isEmpty ? "ditto \(code)" : err) }

        // The zip holds one top folder, `IntroPlayer-<ver>/`. Find it by looking for the bundle
        // rather than by rebuilding the name, so a renamed zip still works.
        let fm = FileManager.default
        var root = out
        if !fm.fileExists(atPath: root.appendingPathComponent("IntroPlayerNative.app").path) {
            let kids = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
            guard let hit = kids.first(where: {
                fm.fileExists(atPath: $0.appendingPathComponent("IntroPlayerNative.app").path)
            }) else { throw Install.unpack("ในไฟล์ไม่มี IntroPlayerNative.app") }
            root = hit
        }
        guard fm.isExecutableFile(atPath: root.appendingPathComponent(installerName).path) else {
            throw Install.missingInstaller
        }
        let exe = root.appendingPathComponent("IntroPlayerNative.app/Contents/MacOS/IntroPlayerNative")
        guard fm.isExecutableFile(atPath: exe.path) else {
            throw Install.unpack("ในไฟล์ไม่มีตัวโปรแกรม")
        }
        let (vc, vout) = try run(exe.path, ["--version"])
        let got = vc == 0 ? String(vout.split(separator: " ").first ?? "") : ""
        guard got == info.version else { throw Install.wrongVersion(got: got, want: info.version) }
        return root
    }

    /// Launches the staged installer and returns at once. The caller must then quit: the script
    /// waits for `waitPid` to disappear before it touches anything, so the swap never races a
    /// running app.
    static func apply(staged: URL, target: URL, waitPid: Int32) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [staged.appendingPathComponent(installerName).path,
                       "--unattended",
                       "--target", target.path,
                       "--wait-pid", String(waitPid),
                       "--relaunch"]
        // Detached: no pipes to fill and nothing for the dying parent to hold open.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw Install.launch(error.localizedDescription) }
    }

    // MARK: helpers

    private static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a command and returns (status, trimmed output). Reads the pipe BEFORE waiting, or a
    /// child that outruns the 64 KB pipe buffer deadlocks us.
    private static func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
