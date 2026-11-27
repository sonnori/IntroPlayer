import SwiftUI

// Must not be named main.swift — SwiftPM treats that as top-level code and it clashes with @main.
@main
struct IntroPlayerApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Read-only, writes nothing, and the one flag someone may be asked to run while being
        // supported over the phone — so it is answered before the diagnostics gate below.
        if CommandLine.arguments.contains("--version") {
            print(AppVersion.full)
            exit(0)
        }
        // Also ungated, and for the same reason: it writes nothing, and "which folder is the app
        // actually reading" is the second question of every support call now that the program
        // and the questions are two places (§5d). An app pointed at the wrong folder looks
        // exactly like an app that lost its settings.
        if CommandLine.arguments.contains("--whereami") {
            print("program : \(AppPaths.programRoot.path)")
            print("data    : \(AppPaths.hasRoot ? AppPaths.root.path : "— ยังไม่ได้เลือก")")
            print("source  : \(AppPaths.rootSource.rawValue)")
            let fm = FileManager.default
            print("songs/  : \(fm.fileExists(atPath: AppPaths.songs.path) ? "มี" : "ไม่มี")")
            print("config  : \(fm.fileExists(atPath: AppPaths.config.path) ? "มี" : "ไม่มี")")
            print("seed    : \(Seeding.sourceDir != nil ? "มีในแอป (crew build)" : "ไม่มี (บิลด์สาธารณะ)")")
            exit(0)
        }
        // Headless diagnostics. Some of these WRITE to the operator's real config.json and
        // log.json, so they are gated behind an env var rather than a bare flag — a stray
        // argument must not be able to reset a taping.
        let diag = ProcessInfo.processInfo.environment["INTROPLAYER_DIAG"] == "1"
        let flags = ["--analyse", "--rescantest", "--resetflow", "--resettest", "--playtest",
                     "--columns", "--handoff", "--preflight", "--titles",
                     "--revealtest", "--grabtest", "--palettetest", "--autodetect", "--artwork", "--timefmt", "--overview", "--remodetest", "--takes",
                     "--updatecheck", "--updatestage", "--loudtest", "--guesstest", "--snapshot", "--guessflow",
                     "--notetest", "--tagtest", "--filtertest", "--roottest", "--incomingtest", "--focustest",
                     "--logotest", "--foldtest"]
        if !diag, let f = CommandLine.arguments.first(where: flags.contains) {
            FileHandle.standardError.write("\(f) needs INTROPLAYER_DIAG=1\n".data(using: .utf8)!)
            exit(2)
        }
        // headless mode for verifying the ported analysis against the web version
        if CommandLine.arguments.contains("--analyse") {
            Diagnostics.analyseAll()
            exit(Diagnostics.exitCode)
        }
        // Read-only. Is the intro auto-gain actually levelling what the audience hears?
        if CommandLine.arguments.contains("--loudtest") {
            Diagnostics.loudTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--rescantest") {
            MainActor.assumeIsolated { Diagnostics.rescanTest() }
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--resetflow") {
            MainActor.assumeIsolated { Diagnostics.resetFlow() }
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--resettest") {
            Diagnostics.resetTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--playtest") {
            Diagnostics.playTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--handoff") {
            Diagnostics.handoffTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--titles") {
            Diagnostics.titles()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--preflight") {
            Diagnostics.preflightReport()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--takes") {
            Diagnostics.takesReport()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--remodetest") {
            Diagnostics.remodeTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--artwork") {
            Diagnostics.artworkReport()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--guessflow") {
            Diagnostics.guessFlow()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--snapshot") {
            Diagnostics.snapshotReport()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--guesstest") {
            Diagnostics.guessSafety()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--autodetect") {
            Diagnostics.autoDetectReport()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--palettetest") {
            Diagnostics.paletteTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--grabtest") {
            Diagnostics.grabTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--revealtest") {
            Diagnostics.revealTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--updatecheck") {
            Diagnostics.updateCheck()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--updatestage") {
            Diagnostics.updateStage()
            exit(Diagnostics.exitCode)
        }
        // Read-only: every Store it builds is `init(rawForTest:)`, which cannot write.
        if CommandLine.arguments.contains("--notetest") {
            Diagnostics.noteTest()
            exit(Diagnostics.exitCode)
        }
        // Read-only: temp fixtures only, and it never reads or writes the stored data root.
        if CommandLine.arguments.contains("--roottest") {
            Diagnostics.rootTest()
            exit(Diagnostics.exitCode)
        }
        // Read-only, same as --notetest.
        if CommandLine.arguments.contains("--focustest") {
            Diagnostics.focusTest()
            exit(Diagnostics.exitCode)
        }
        // Read-only. Reads `brand/logo.png` from the data folder; writes nothing.
        if CommandLine.arguments.contains("--logotest") {
            Diagnostics.logoTest()
            exit(Diagnostics.exitCode)
        }
        // Read-only, pure: no model, no disk.
        if CommandLine.arguments.contains("--foldtest") {
            Diagnostics.foldTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--incomingtest") {
            Diagnostics.incomingTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--filtertest") {
            Diagnostics.filterTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--tagtest") {
            Diagnostics.tagTest()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--timefmt") {
            Diagnostics.timeFmt()
            exit(Diagnostics.exitCode)
        }
        if CommandLine.arguments.contains("--overview") {
            Diagnostics.overviewTest()
            exit(Diagnostics.exitCode)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--columns") {
            Diagnostics.columns(match: CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "")
            exit(Diagnostics.exitCode)
        }
    }

    var body: some Scene {
        WindowGroup("RGF Intro Player") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 640)
                // The stored theme has to reach NSApp before the first paint, or the window
                // chrome opens on the system appearance and snaps a frame later.
                .onAppear { model.applyTheme() }
                // Zero-size, draws nothing: it exists to stop AppKit handing first responder to
                // the first text field in the key-view loop when the window opens. See
                // `DropInitialFocus` — the app was opening with every letter shortcut dead.
                .background(DropInitialFocus().frame(width: 0, height: 0))
        }
        // 2000, not the old 1600. That change began as a fix for a real defect — `isWide`
        // needed a 1900 pt WINDOW before the three-column list and its controls existed at all,
        // so a 1600 default opened the app in the fallback layout even on the production
        // 2560x1080 panel, and the fold and edge-drag controls looked simply absent. Reported as
        // "ลากปรับขนาดไม่ได้ / collapse ไม่ทำงาน".
        //
        // That breakpoint is gone: every pane sizes itself from `PaneLayout` now and decides its
        // own internal layout from its OWN width, so there is no window size at which a feature
        // disappears. 2000 stays because a bigger default is simply better on a wide screen, and
        // macOS fits a default size down to the screen — a laptop gets its own width and a
        // narrower, still complete, layout. It applies only to a window with no saved frame.
        .defaultSize(width: 2000, height: 1000)
        .commands { CommandGroup(replacing: .newItem) {} }   // no File > New
    }
}
