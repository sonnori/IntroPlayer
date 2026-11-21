import AppKit
import AVFoundation
import Foundation

/// Cover art for the song list and the player, fetched once at a desk and read from disk
/// thereafter.
///
/// **Three constraints shaped this, and they are the whole design:**
///
/// 1. §1/§2: the app runs **100% offline on set**. So nothing here is ever on the path of a
///    taping. Art is fetched by an explicit button, cached as a file, and every later read is a
///    disk read. With no network and no cache you get a blank frame and no error — on a show
///    day a missing picture must not produce a spinner, a dialog, or a retry.
///
/// 2. **No credential.** The request was "search Spotify", and Spotify's Web API needs a client
///    ID and secret. That secret would have to live on every crew machine, or in `config.json`,
///    which travels with a round folder (§8e) — a credential nobody manages, in a file designed
///    to be copied around. The iTunes Search API returns the same artwork for the same query
///    with no key, no registration and no account, so that is what this uses. If Spotify is
///    specifically wanted later, only `search` changes.
///
/// 3. **The file usually already has the picture.** Every one of the nine songs in the real
///    library carries an embedded ID3 `APIC` frame, because they came from music videos. That
///    source is offline, needs no key, and cannot be the wrong song — so it is tried FIRST and
///    the network is never touched for a library like this one. The online lookup is a fallback
///    for files with no embedded art.
///
///    This matters because the online lookup is weak here: measured against the real nine
///    titles, iTunes Search returned 2 clean matches, 5 nothing, and **2 confidently wrong
///    songs** (searching BOWKYLION's "วาดไว้" returned a different BOWKYLION track). Wrong
///    cover art on a quiz song is worse than none, so a result whose track name shares nothing
///    with the query is rejected rather than shown.
///
/// 4. The cache lives **inside the round folder** (`songs/<round>/.covers/`), not beside the
///    app. §8e makes the round folder the unit of handover, so art fetched by the setter travels
///    to the operator with the audio instead of being re-fetched on a machine that is offline by
///    design. `Library.scan` passes `.skipsHiddenFiles`, so the dot-folder is invisible to it.
enum Artwork {

    /// 6 s, as a resource deadline rather than `URLRequest.timeoutInterval` — that one is an
    /// IDLE timeout, and `URLSession.shared` inherits a 7-day resource timeout, so a server
    /// dribbling a byte every few seconds keeps a request alive forever. Same trap §15 records
    /// for the update check.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 6
        c.httpAdditionalHeaders = ["User-Agent": "IntroPlayer/\(AppVersion.short)"]
        return URLSession(configuration: c)
    }()

    // MARK: - where a cover lives

    static func cacheDir(for path: String) -> URL {
        let round = Library.playlist(of: path)
        let base = round.isEmpty ? AppPaths.songs : AppPaths.songs.appendingPathComponent(round)
        return base.appendingPathComponent(".covers")
    }

    /// Named after the audio file, so a human opening `.covers/` can see what is what — and so
    /// renaming a song orphans its cover exactly the way it orphans its config entry (§9),
    /// rather than leaving a mystery file keyed by a hash.
    static func cacheURL(for path: String) -> URL {
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return cacheDir(for: path).appendingPathComponent(stem + ".jpg")
    }

    /// Artwork embedded in the audio file itself (ID3 `APIC`, MP4 covr, …). Offline, exact,
    /// and already present for every song in the real library.
    static func embedded(for path: String) -> NSImage? {
        let asset = AVURLAsset(url: Library.url(path))
        for item in asset.commonMetadata where item.commonKey == .commonKeyArtwork {
            if let d = item.dataValue, let img = NSImage(data: d) { return img }
            if let d = item.value as? Data, let img = NSImage(data: d) { return img }
        }
        return nil
    }

    /// Disk cache first (an online fetch is the only thing that cannot be re-derived offline),
    /// then the file's own metadata. Blocking — call it off the main actor.
    static func resolve(for path: String) -> NSImage? {
        let u = cacheURL(for: path)
        if FileManager.default.fileExists(atPath: u.path), let img = NSImage(contentsOf: u) {
            return img
        }
        return embedded(for: path)
    }

    /// Does this song already have art from SOME source? Drives which songs an online fetch
    /// even considers — a file with embedded art must never be looked up, both to save the
    /// request and because the lookup could only replace a certainly-right picture with a
    /// possibly-wrong one.
    static func hasCover(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: cacheURL(for: path).path) { return true }
        return embedded(for: path) != nil
    }

    // MARK: - fetching

    enum Failure: LocalizedError {
        case noMatch, badResponse, write(String)
        var errorDescription: String? {
            switch self {
            case .noMatch:       return "หาเพลงนี้ไม่เจอ"
            case .badResponse:   return "เซิร์ฟเวอร์ตอบไม่ถูกต้อง"
            case .write(let s):  return "เขียนไฟล์ไม่ได้ — \(s)"
            }
        }
    }

    /// The search term. Reuses the list's own cleaned title, so what is searched for is what the
    /// operator sees on screen — a mismatch between the two is impossible to debug from a
    /// screenshot.
    static func query(for path: String) -> String {
        Library.displayTitle(path)
    }

    /// Look the song up and return the best artwork URL, or nil.
    static func search(_ term: String) async throws -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
        ]
        guard let url = c.url else { return nil }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.badResponse
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let first = results.first,
              let art = first["artworkUrl100"] as? String
        else { return nil }
        // Reject a confident mismatch. The API always answers with its nearest guess, and for
        // Thai titles its nearest guess is often a different song by the same artist — which
        // would put the wrong sleeve on a quiz question with no indication anything was wrong.
        let track = (first["trackName"] as? String) ?? ""
        guard plausible(query: term, track: track) else { return nil }
        // The API hands back a 100px thumbnail; the same path serves larger sizes. 600 is what
        // a 2560x1080 panel can actually use without looking soft, and is ~40 KB.
        return URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
            ?? URL(string: art)
    }

    /// Fetch and cache one song's cover. Returns false when there was simply no match — that is
    /// an ordinary outcome for a local edit or an obscure track, not an error worth a dialog.
    @discardableResult
    static func fetch(for path: String) async throws -> Bool {
        guard let art = try await search(query(for: path)) else { throw Failure.noMatch }
        let (data, resp) = try await session.data(from: art)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 512 else {
            throw Failure.badResponse
        }
        // Must still decode as an image. A captive-portal login page returns 200 with HTML, and
        // writing that to cover.jpg would cache a permanent failure that looks like a corrupt
        // file forever after.
        guard NSImage(data: data) != nil else { throw Failure.badResponse }
        let dir = cacheDir(for: path)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: cacheURL(for: path), options: .atomic)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        return true
    }

    /// Words that carry no identity, so a shared one proves nothing. Without this the minimum
    /// token length would have to rise, and it cannot: see below.
    private static let stopWords: Set<String> = [
        "the", "and", "you", "for", "with", "feat", "ft", "official", "mv", "video", "audio",
        "lyrics", "lyric", "visualizer", "version", "ver", "cover", "full", "song", "original",
    ]

    /// Does the result look like the thing that was asked for? Compared on the TRACK name
    /// ONLY: a matching artist proves nothing, because every wrong answer observed was the
    /// right artist with the wrong song.
    ///
    /// The minimum token length is **3 grapheme clusters, not 4**. Thai combining marks fold
    /// into their base character, so "ขี้แง" is three Characters, not five — a 4-cluster floor
    /// rejected the one Thai title the API actually got right. "ooh" is three too. Three is
    /// short enough to admit English filler, hence the stop list.
    static func plausible(query: String, track: String) -> Bool {
        guard !track.isEmpty else { return false }
        let drop = CharacterSet(charactersIn: "()[]{}【】-–—_.,!?\"'“”/\\|&+")
        func tokens(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: drop.union(.whitespacesAndNewlines))
                .filter { $0.count >= 3 && !stopWords.contains($0) })
        }
        let q = tokens(query), t = tokens(track)
        if !q.isDisjoint(with: t) { return true }
        // Containment too, for a token that is punctuated differently on each side.
        let ql = query.lowercased(), tl = track.lowercased()
        return q.contains(where: { tl.contains($0) }) || t.contains(where: { ql.contains($0) })
    }

    /// Politeness gap between lookups. The iTunes Search API is documented as roughly 20 calls a
    /// minute; a 60-song round fetched flat out would be throttled part way and leave half a
    /// round done with no indication which half.
    static let gapSeconds: Double = 3.2
}
