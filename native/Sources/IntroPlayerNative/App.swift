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
        // Headless diagnostics. Some of these WRITE to the operator's real config.json and
        // log.json, so they are gated behind an env var rather than a bare flag — a stray
        // argument must not be able to reset a taping.
        let diag = ProcessInfo.processInfo.environment["INTROPLAYER_DIAG"] == "1"
        let flags = ["--analyse", "--rescantest", "--resetflow", "--resettest", "--playtest",
                     "--columns", "--handoff", "--preflight", "--titles",
                     "--revealtest", "--grabtest", "--palettetest", "--autodetect", "--artwork", "--timefmt", "--overview", "--remodetest", "--takes",
                     "--updatecheck", "--updatestage", "--loudtest", "--guesstest"]
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
        }
        .defaultSize(width: 1600, height: 900)
        .commands { CommandGroup(replacing: .newItem) {} }   // no File > New
    }
}
