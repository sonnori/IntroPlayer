import AppKit
import SwiftUI

/// Press feedback for every button in the app. `.buttonStyle(.plain)` strips AppKit's own
/// highlight, so without this a click gives no confirmation at all — unacceptable when the GM is
/// driving a live taping and needs to know the press registered.
struct PressStyle: ButtonStyle {
    var corner: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        // The environment is read inside a real View, NOT via an `@Environment` property on the
        // style itself. SwiftUI installs dynamic properties on Views and ViewModifiers; a
        // `ButtonStyle` is neither, so the property can silently read the EnvironmentValues
        // default (`.light`) — which would have given every button in the dark theme a black
        // wash and a negative brightness, i.e. no visible press at all.
        PressBody(corner: corner, configuration: configuration)
    }

    private struct PressBody: View {
        let corner: CGFloat
        let configuration: Configuration
        /// The press wash and the brightness shift both reverse with the theme. A white wash
        /// and a POSITIVE brightness on a light theme's near-white button is no feedback — and
        /// in a taping the difference between "the press registered" and "nothing happened" is
        /// the only thing telling the operator whether to press it again.
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            let light = scheme == .light
            return configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? (light ? -0.10 : 0.16) : 0)
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    // Black in light, white in dark. Works on BOTH kinds of button in each
                    // theme: light mode's plain buttons are near-white and its saturated fills
                    // are mid-dark, and a 10% black wash is visible on either.
                    .fill((light ? Color.black : Color.white)
                        .opacity(configuration.isPressed ? 0.10 : 0))
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Identifiers for the on-screen buttons a keyboard shortcut maps to. A key press has to *look*
/// like a click, otherwise the GM can't tell a dead shortcut from a working one.
enum PulseID {
    static let start = "start", reveal = "reveal", reset = "reset", played = "played"
    static let correct = "correct", wrong = "wrong", log = "log"
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
    @Environment(\.colorScheme) private var scheme
    let id: String
    let corner: CGFloat

    func body(content: Content) -> some View {
        let on = model.pulseID == id
        let light = scheme == .light
        return content
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    // The ring is drawn ON the button's edge, so it is seen against the fill and
                    // the surround at once; near-black reads against both in light mode, white
                    // against both in dark. A fixed white ring simply vanished in light.
                    .stroke((light ? Color.black : Color.white).opacity(on ? 0.85 : 0),
                            lineWidth: on ? 2.5 : 0)
                    // §6c: an overlay is hit-testable. This one covers the button's edge for
                    // 260 ms after every shortcut — i.e. exactly while the operator may be
                    // reaching for it with the mouse.
                    .allowsHitTesting(false)
            )
            .brightness(on ? (light ? -0.14 : 0.22) : 0)
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
    // Return and Space must land on CANCEL, not on the destructive button. NSAlert makes the
    // first-added button the default, and two of these alerts are now reached through a `⋯` menu
    // — where Space activates the highlighted item, so one Space could open the alert AND confirm.
    a.buttons.first?.keyEquivalent = ""
    a.buttons.last?.keyEquivalent = "\r"
    return a.runModal() == .alertFirstButtonReturn
}

// MARK: - Handing the keyboard back

/// Should a mouse-down here end text editing?
///
/// AppKit does **not** resign first responder when you click empty space, so a field kept focus
/// until Esc or Return — and while it has focus the key monitor's `typing` branch is on, which
/// means `S`, `R`, `P`, `I`/`O`/`H` and `L` are all dead with nothing on screen saying so. On a
/// shoot the keyboard IS the instrument, so "I clicked away, surely I'm out of the box" has to
/// be true. §12 already records the same trap having no exit at all before Esc was wired up.
///
/// A pure function over the hit-test result so `--focustest` can assert it without a window —
/// the alternative is a click nobody can drive headlessly.
enum FocusRelease {
    static func shouldRelease(firstResponder fr: NSResponder?, hit: NSView?) -> Bool {
        // Nothing is being typed into: every ordinary click takes this branch and changes nothing.
        guard fr is NSTextView else { return false }
        // Outside every view (title bar, off the content view) — let go.
        guard let hit else { return true }
        // Clicking ANOTHER text field must MOVE focus, not drop it. AppKit does that itself, and
        // stealing first responder here would fight it.
        return !isTextInput(hit)
    }

    /// The hit view may be a subview of the field (its border, its clip view), so walk up.
    static func isTextInput(_ v: NSView) -> Bool {
        var cur: NSView? = v
        while let c = cur {
            if c is NSTextView || c is NSTextField { return true }
            cur = c.superview
        }
        return false
    }
}
