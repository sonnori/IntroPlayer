import SwiftUI

// Must not be named main.swift — SwiftPM treats that as top-level code and it clashes with @main.
@main
struct IntroPlayerApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Headless diagnostics. Some of these WRITE to the operator's real config.json and
        // log.json, so they are gated behind an env var rather than a bare flag — a stray
        // argument must not be able to reset a taping.
        let diag = ProcessInfo.processInfo.environment["INTROPLAYER_DIAG"] == "1"
        let flags = ["--analyse", "--rescantest", "--resetflow", "--resettest", "--playtest",
                     "--columns", "--handoff", "--preflight", "--titles",
                     "--previewtest", "--timefmt", "--overview", "--remodetest"]
        if !diag, let f = CommandLine.arguments.first(where: flags.contains) {
            FileHandle.standardError.write("\(f) needs INTROPLAYER_DIAG=1\n".data(using: .utf8)!)
            exit(2)
        }
        // headless mode for verifying the ported analysis against the web version
        if CommandLine.arguments.contains("--analyse") {
            Diagnostics.analyseAll()
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
        if CommandLine.arguments.contains("--remodetest") {
            Diagnostics.remodeTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--previewtest") {
            Diagnostics.previewTest()
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
        }
        .defaultSize(width: 1600, height: 900)
        .commands { CommandGroup(replacing: .newItem) {} }   // no File > New
    }
}
