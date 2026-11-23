import CryptoKit
import Foundation

/// A copy of the questions, taken at launch.
///
/// §13 names this the one real data gap left. `config.json` and `log.json` are deliberately
/// untracked (§5b, so that a code-side `git checkout .` or `git stash` can never wipe a
/// setter's markers — the one thing in this project with no other copy), and the installer's
/// `backups/` only fires during an update, which makes it an undo for the update rather than a
/// backup. **Between updates the questions live in exactly one place.**
///
/// What this covers and what it does not, stated plainly — §13 warns that anything which says
/// "it always backs up for you" must be bounded or it makes the gap *feel* closed:
///
/// - **Covers:** `git clean -xdf` (which §5b measures as deleting `config.json`, `log.json`
///   AND `songs/`), a bad hand-edit, a bug in this app, an operator hitting `🗑 ล้าง log` or
///   `↺ รีเซ็ตเล่นแล้ว` by mistake, and an import that turns out to be the wrong round.
/// - **Does NOT cover** losing the folder or the disk, because the snapshots sit *inside* the
///   very folder whose loss is the risk. That half is closed by `_settings.backupDir`: set it
///   to a path in a synced folder (Drive, Dropbox, iCloud) and every snapshot is copied there
///   too. It is empty by default because where an operator's questions are allowed to travel
///   is their decision, not ours.
///
/// Three properties this has to have, each for a reason the rest of the app already records:
///
/// 1. **It reads the bytes synchronously at launch and writes them in the background.** The
///    point of a launch snapshot is the state *before* this run touched anything; doing the
///    read async would race `AppModel`'s own first save and could snapshot the result instead
///    of the input. The writing is what takes time, and that part is off the main thread.
/// 2. **It never alarms and never blocks.** A failure here is reported in About and in
///    `--snapshot`, and nowhere else. On a show day a backup that cannot write must not produce
///    a dialog, a toast or a retry — the same rule §8f applies to a missing cover.
/// 3. **It skips a snapshot identical to the newest one it already has.** Without that, twenty
///    launches on a quiet day would push the twenty real ones out of the ring.
enum Snapshot {

    /// How many to keep. Twenty launches is comfortably more than a taping week, and two small
    /// JSON files per snapshot is a few hundred KB in total.
    static let keep = 20

    static var dir: URL { AppPaths.root.appendingPathComponent("backups/snapshots") }

    struct Report {
        var wrote: String?          // the stamp directory name, when one was created
        var skipped = false         // identical to the newest snapshot
        var pruned = 0
        var mirrored: String?       // where `backupDir` received a copy
        var problems: [String] = []
    }

    private static func sha(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static var stampFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// The bytes to preserve, read on the calling thread. Returns nil when there is nothing
    /// worth keeping — a first run with no config yet is not a problem to report.
    static func capture() -> (config: Data, log: Data?)? {
        guard let cfg = try? Data(contentsOf: AppPaths.config), !cfg.isEmpty else { return nil }
        return (cfg, try? Data(contentsOf: AppPaths.log))
    }

    /// Existing snapshot directories, newest first. Named by timestamp, so a lexical sort is a
    /// chronological one — and it stays correct if the filesystem's own dates are rewritten by
    /// a sync client, which is exactly where these may end up living.
    static func existing() -> [URL] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        return kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Write one snapshot. Blocking — call it off the main thread with bytes captured earlier.
    @discardableResult
    static func write(_ shot: (config: Data, log: Data?), version: String,
                      mirrorTo mirror: String) -> Report {
        var r = Report()
        let fm = FileManager.default
        // Nothing to snapshot, and nowhere safe to put it: with no library resolved this would
        // create `backups/snapshots/` beside the app. See `Store.saveNow`.
        guard AppPaths.hasRoot else { r.skipped = true; return r }

        // Identical to the newest one we already hold? Then this launch changed nothing.
        if let newest = existing().first,
           let prev = try? Data(contentsOf: newest.appendingPathComponent("config.json")),
           sha(prev) == sha(shot.config) {
            r.skipped = true
            return r
        }

        let stamp = stampFormatter.string(from: Date())
        let target = dir.appendingPathComponent(stamp)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try shot.config.write(to: target.appendingPathComponent("config.json"), options: .atomic)
            if let l = shot.log {
                try l.write(to: target.appendingPathComponent("log.json"), options: .atomic)
            }
            // A plain-text stamp, because the person reading this folder in two months is
            // looking for "which of these is the one from before the EP05 taping" and a
            // directory name alone does not say which build wrote it.
            let note = "IntroPlayer \(version)\nสำรองเมื่อเปิดโปรแกรม \(stamp)\n"
                + "config.json \(shot.config.count) bytes"
                + (shot.log.map { "\nlog.json \($0.count) bytes" } ?? "")
                + "\n\nคืนค่า: คัดลอกไฟล์ในโฟลเดอร์นี้กลับไปไว้ข้าง ๆ แอป (ปิดแอปก่อน)\n"
            try? note.data(using: .utf8)?.write(to: target.appendingPathComponent("อ่านก่อน.txt"))
            r.wrote = stamp
        } catch {
            r.problems.append("เขียนสำรองในเครื่องไม่ได้ — \(error.localizedDescription)")
            return r
        }

        // Prune. Only ever removes directories this function created, and only inside `dir`.
        for old in existing().dropFirst(keep) {
            if (try? fm.removeItem(at: old)) != nil { r.pruned += 1 }
        }

        // The half that actually survives losing this folder.
        let m = mirror.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty {
            let base = URL(fileURLWithPath: (m as NSString).expandingTildeInPath)
                .appendingPathComponent("IntroPlayer-snapshots")
            let dest = base.appendingPathComponent(stamp)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try shot.config.write(to: dest.appendingPathComponent("config.json"), options: .atomic)
                if let l = shot.log {
                    try l.write(to: dest.appendingPathComponent("log.json"), options: .atomic)
                }
                r.mirrored = dest.path
                // Pruned on the same rule, so a synced folder cannot grow without bound either.
                let kids = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? [])
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                for old in kids.dropFirst(keep) { try? fm.removeItem(at: old) }
            } catch {
                // Named separately from the local failure: "the Drive folder has not synced /
                // is not signed in" and "this disk is read-only" need different answers, and
                // reporting one as the other is the `saveNow()` lesson in §12.
                r.problems.append("สำรองไปโฟลเดอร์ sync ไม่ได้ — \(error.localizedDescription)")
            }
        }
        return r
    }

    /// One line for About. nil when there is nothing an operator needs to know.
    static func summary(_ r: Report) -> String? {
        if !r.problems.isEmpty { return r.problems.joined(separator: " · ") }
        if let w = r.wrote { return "สำรองโจทย์ไว้แล้ว \(w)" + (r.mirrored != nil ? " (+ โฟลเดอร์ sync)" : "") }
        return nil
    }
}
