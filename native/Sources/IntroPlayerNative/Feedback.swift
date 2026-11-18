import AppKit
import SwiftUI

/// Press feedback for every button in the app. `.buttonStyle(.plain)` strips AppKit's own
/// highlight, so without this a click gives no confirmation at all — unacceptable when the GM is
/// driving a live taping and needs to know the press registered.
struct PressStyle: ButtonStyle {
    var corner: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.16 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .fill(.white.opacity(configuration.isPressed ? 0.10 : 0))
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Identifiers for the on-screen buttons a keyboard shortcut maps to. A key press has to *look*
/// like a click, otherwise the GM can't tell a dead shortcut from a working one.
enum PulseID {
    static let start = "start", reveal = "reveal", reset = "reset", played = "played"
    static let correct = "correct", wrong = "wrong", log = "log"
    static let preview = "preview"
    static let zoomIn = "zin", zoomOut = "zout", zoomFit = "zfit", zoomIntro = "zintro"
    static let ignoreEnd = "ignore"
    static func mark(_ label: String) -> String { "mark:" + label }
}

extension View {
    /// Flashes a ring when `model.pulseID` matches — driven by the keyboard handler.
    func pulseTarget(_ id: String, corner: CGFloat = 10) -> some View {
        modifier(PulseTarget(id: id, corner: corner))
    }
}

private struct PulseTarget: ViewModifier {
    @EnvironmentObject var model: AppModel
    let id: String
    let corner: CGFloat

    func body(content: Content) -> some View {
        let on = model.pulseID == id
        content
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(.white.opacity(on ? 0.85 : 0), lineWidth: on ? 2.5 : 0)
            )
            .brightness(on ? 0.22 : 0)
            .scaleEffect(on ? 0.975 : 1)
            .animation(.easeOut(duration: on ? 0.05 : 0.28), value: on)
    }
}


/// Blocking yes/no for the handful of buttons that throw work away.
///
/// An NSAlert, not SwiftUI's `.confirmationDialog`: these buttons live in three different views,
/// and during a taping a destructive press should freeze everything until it is answered rather
/// than animate a sheet the GM can click past.
@MainActor
func confirmDestructive(title: String, body: String, ok: String) -> Bool {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = title
    a.informativeText = body
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "ยกเลิก")
    a.buttons.first?.hasDestructiveAction = true
    return a.runModal() == .alertFirstButtonReturn
}
