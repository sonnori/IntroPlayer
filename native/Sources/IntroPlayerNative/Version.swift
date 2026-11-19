import Foundation

/// What build is this?
///
/// Before this existed, an operator reporting "it's broken" gave no way to tell WHICH build they
/// were on — and once the folder is handed to other people there is more than one answer. The
/// version is stamped into Info.plist by `build.sh` from the repo's `VERSION` file, so it cannot
/// drift from the source it was built out of.
enum AppVersion {
    /// "1.1.0" — the number people say out loud.
    static let short = info("CFBundleShortVersionString") ?? "0.0.0"
    /// Short git sha of the commit it was built from, or "" for an unstamped local build.
    static let commit = info("RGFGitCommit") ?? ""
    /// ISO date it was built.
    static let date = info("RGFBuildDate") ?? ""

    private static func info(_ k: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: k) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "v1.1.0" for the UI. The commit is deliberately NOT in here: it is the line the operator
    /// reads out over the phone, and a sha makes it unreadable. It lives in the About sheet.
    static var display: String { "v\(short)" }

    /// "1.1.0 (a1b2c3d, 2026-11-19)" — the full identity, for About and `--version`.
    static var full: String {
        var s = short
        var extra: [String] = []
        if !commit.isEmpty { extra.append(commit) }
        if !date.isEmpty { extra.append(date) }
        if !extra.isEmpty { s += " (\(extra.joined(separator: ", ")))" }
        return s
    }

    /// Compares dotted numeric versions: -1 / 0 / 1.
    ///
    /// Must be numeric per component, not a string compare: `"1.10.0" < "1.9.0"` lexically, which
    /// would hide every update after the ninth. Non-numeric suffixes ("1.2.0-beta") compare on
    /// their leading digits, and a component that parses to nothing counts as 0, so a malformed
    /// manifest degrades to "not newer" instead of nagging forever.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { seg in
            Int(seg.prefix { $0.isNumber }) ?? 0
        }
    }

    /// Is `other` strictly newer than this build?
    static func isNewer(_ other: String) -> Bool { compare(other, short) > 0 }
}
