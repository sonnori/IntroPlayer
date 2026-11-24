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
                     "--notetest", "--tagtest", "--filtertest", "--roottest", "--incomingtest"]
        if !diag, let f = CommandLine.arguments.first(where: flags.contains) {
            FileHandle.standardError.write("\(f) needs INTROPLAYER_DIAG=1\n".data(using: .utf8)!)
            exit(2)
        }
        // headless mode for verifying the ported analysis against the web version
        if CommandLine.arguments.contains("--analyse") {
            Diagnostics.analyseAll()
            exit(0)
        }
        // Read-only. Is the intro auto-gain actually levelling what the audience hears?
        if CommandLine.arguments.contains("--loudtest") {
            Diagnostics.loudTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--rescantest") {
            MainActor.assumeIsolated { Diagnostics.rescanTest() }
            exit(0)
        }
        if CommandLine.arguments.contains("--resetflow") {
            MainActor.assumeIsolated { Diagnostics.resetFlow() }
            exit(0)
        }
        if CommandLine.arguments.contains("--resettest") {
            Diagnostics.resetTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--playtest") {
            Diagnostics.playTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--handoff") {
            Diagnostics.handoffTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--titles") {
            Diagnostics.titles()
            exit(0)
        }
        if CommandLine.arguments.contains("--preflight") {
            Diagnostics.preflightReport()
            exit(0)
        }
        if CommandLine.arguments.contains("--takes") {
            Diagnostics.takesReport()
            exit(0)
        }
        if CommandLine.arguments.contains("--remodetest") {
            Diagnostics.remodeTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--artwork") {
            Diagnostics.artworkReport()
            exit(0)
        }
        if CommandLine.arguments.contains("--guessflow") {
            Diagnostics.guessFlow()
            exit(0)
        }
        if CommandLine.arguments.contains("--snapshot") {
            Diagnostics.snapshotReport()
            exit(0)
        }
        if CommandLine.arguments.contains("--guesstest") {
            Diagnostics.guessSafety()
            exit(0)
        }
        if CommandLine.arguments.contains("--autodetect") {
            Diagnostics.autoDetectReport()
            exit(0)
        }
        if CommandLine.arguments.contains("--palettetest") {
            Diagnostics.paletteTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--grabtest") {
            Diagnostics.grabTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--revealtest") {
            Diagnostics.revealTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--updatecheck") {
            Diagnostics.updateCheck()
            exit(0)
        }
        if CommandLine.arguments.contains("--updatestage") {
            Diagnostics.updateStage()
            exit(0)
        }
        // Read-only: every Store it builds is `init(rawForTest:)`, which cannot write.
        if CommandLine.arguments.contains("--notetest") {
            Diagnostics.noteTest()
            exit(0)
        }
        // Read-only: temp fixtures only, and it never reads or writes the stored data root.
        if CommandLine.arguments.contains("--roottest") {
            Diagnostics.rootTest()
            exit(0)
        }
        // Read-only, same as --notetest.
        if CommandLine.arguments.contains("--incomingtest") {
            Diagnostics.incomingTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--filtertest") {
            Diagnostics.filterTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--tagtest") {
            Diagnostics.tagTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--timefmt") {
            Diagnostics.timeFmt()
            exit(0)
        }
        if CommandLine.arguments.contains("--overview") {
            Diagnostics.overviewTest()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--columns") {
            Diagnostics.columns(match: CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "")
            exit(0)
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
        .defaultSize(width: 1600, height: 900)
        .commands { CommandGroup(replacing: .newItem) {} }   // no File > New
    }
}
