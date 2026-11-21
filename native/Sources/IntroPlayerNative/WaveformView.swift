import AppKit
import SwiftUI

/// Measured, not picked by eye. The app runs on a 2560x1080 LG WFHD at **scale 1.0, ~81 PPI** —
/// there is no Retina margin, so the old ladder's 4.2-4.4 ΔL* steps read as a single flat field
/// under studio light. These steps are 5.5-6.9 ΔL*, and `float` sits 19 L* above `panel` so a
/// sheet finally reads as being above its pane rather than level with it.
///
/// Each hue now means exactly ONE thing. Before this, green meant four (configured badge, Intro
/// End marker, intro-range fill, Correct), amber meant six (Wrong badge, free mode, played,
/// Ignore Intro End, save failure, Hook marker) and cyan four. The state that can put a whole
/// song on camera cannot share a colour with "this song was played".
enum Palette {
    // surfaces — dark L* 3.3/9.2/16.0/23.0/28.4, light 82.1/88.6/94.1/100 (panel3 recessed)
    static let bg         = dyn(0x0A0C10, 0xC7CDD3)
    static let panel      = dyn(0x161A22, 0xD9DFE6)
    static let panel2     = dyn(0x222834, 0xE8EFF5)
    /// Controls inside a card. In dark it comes FORWARD (lighter); in light it is RECESSED
    /// (8.0 L* below the card), which is how a light-theme control reads — the requirement is
    /// a step of at least 5.5 L*, not a direction.
    static let panel3     = dyn(0x2F3747, 0xD2D8DF)
    static let float      = dyn(0x3A4358, 0xFFFFFF)
    static let hair       = dyn(0x272E3A, 0xC1C7CE)
    static let line       = dyn(0x3C4659, 0xABB1B8)
    static let lineStrong = dyn(0x5A6880, 0x81878D)

    // text — dark 12.49/6.83/4.07 on panel2, light 13.48/6.00/4.00
    static let text  = dyn(0xEAECF0, 0x1F2429)
    static let muted = dyn(0xA7B1C2, 0x555A60)
    static let dim   = dyn(0x7C8799, 0x70757B)
    /// Text ON a saturated fill. The fills invert between themes — bright in dark, dark in
    /// light — so this has to invert with them or every button legend disappears.
    static let ink   = dyn(0x0A0C10, 0xFFFFFF)
    /// A DARK hairline, in both themes. Not `ink`, even though they were the same value before
    /// there was a light theme: the playhead is a dark outline under a white core, so an `ink`
    /// that follows the theme turned the playhead white-on-white — invisible, on the one element
    /// every marker is placed against.
    static let outline = Color(hex: 0x0A0C10)
    /// Drawn ON the waveform bed and nothing else, so it must INVERT: white against the dark
    /// bed, near-black against the light one. Distinct from `outline`, which is fixed dark
    /// because it is the hairline the playhead's white core is drawn on top of — that pair
    /// works in both themes precisely because only one of the two moves.
    static let onWave = dyn(0xFFFFFF, 0x0A0C10)
    /// The header bar is a saturated dark red in BOTH themes, so whatever sits on it sits on
    /// dark and must not flip. Measured: the light theme's amber on the light header is 1.2:1,
    /// and the thing drawn in it is the save-failure warning — the single condition that
    /// silently loses a day of markers.
    static let onHeader = Color.white
    static let onHeaderWarn = Color(hex: 0xFFC53D)

    /// Transport, and "playing the intro". Note accent vs purple collide at deutan ΔE ~1 in
    /// BOTH themes — they are the same colour to a deutan viewer — so blue-vs-purple must never
    /// be the only carrier of the armed/disarmed state. That is why the guard uses amber plus
    /// a word. `--palettetest` pins the collision so nobody "fixes" it by accident.
    static let accent = dyn(0x4A8CFF, 0x0063D6)
    /// The Intro bracket: BOTH ends. They are two ends of one range, told apart by which edge
    /// their flag sits on, which also makes two markers on the same time individually grabbable.
    static let cyan = dyn(0x1FC8E8, 0x007A93)
    /// Only ever "a human answered correctly".
    static let green = dyn(0x2FD17A, 0x1F5534)
    static let greenText = dyn(0x7DE9AF, 0x0A4C2F)
    /// Wrong / burned question, and destructive controls. The outcome pair is the one separation
    /// that must never be traded away: measured deutan ΔE 11.9 dark / 23.9 light for the fills,
    /// 21.3 / 27.5 for the badge text. The light values came out BETTER because the light fills
    /// have more lightness spread available under a white ground.
    static let red = dyn(0xF4374E, 0xE1123E)
    /// Only ever "the intro-end stop is not armed, or something is wrong".
    ///
    /// The light value could not satisfy §6d's "~24 ΔL* from accent and purple" — on a white
    /// ground the usable range is too narrow, and the search came back empty. That rule was a
    /// bonus property, not the mechanism: amber is YELLOW against a BLUE accent, and deutan
    /// leaves the blue-yellow axis intact, so the real separation is ΔE 67 in light (74 in dark)
    /// and the carrier of last resort is still the word next to it.
    static let amber = dyn(0xFFC53D, 0x926800)
    /// Reveal, and the Hook marker it jumps to — one meaning, two places.
    static let purple = dyn(0xA06BFF, 0x6E3FCD)
    static let hook = dyn(0xA06BFF, 0x6E3FCD)
    /// Only ever "changed after the handover".
    static let onsite = dyn(0xF763B8, 0xC82C8D)
    /// White on it: 4.97:1 dark, 6.22:1 light. The old #E25232 was 3.83:1 at 15px bold — below
    /// 4.5 and too small for the large-text exemption.
    static let header = dyn(0xC8402A, 0xBA2616)

    // ---- tinted chips -------------------------------------------------------------------
    // These were hardcoded `Color(red:...)` darks scattered through SetupPanel, LogPanel and the
    // column headers. Under a light theme `Palette.text` goes near-black and lands on them: dark
    // cyan on dark teal measured 1.6:1. A chip whose own label is unreadable is worse than no
    // theme at all, so each tint is named by ROLE and resolved per theme.
    /// "automatic / this control is on" — the 🎯 and the toggles.
    static let tintCyan = dyn(0x12303F, 0xBDE3EE)
    static let tintCyanLine = dyn(0x2A6B80, 0x6AAABB)
    /// "played / Ignore Intro End" — amber's meaning, as a background wash.
    static let tintWarn = dyn(0x2A2418, 0xF3D9B0)
    static let tintWarnLine = dyn(0x6B5A33, 0xBB9C64)
    /// "this is the active column / the row you are on".
    static let tintSelect = dyn(0x243049, 0xD3D9F7)
    static let tintSelectText = dyn(0xCFE0FF, 0x214583)
    /// Log rows: answered vs burned. The row text is `Palette.text`, so these carry it.
    static let tintGood = dyn(0x121F22, 0xC0E6CA)
    static let tintBad = dyn(0x2E2412, 0xFFD2CF)
    static let tintGoodLine = dyn(0x2F5B41, 0x78AC88)
    /// The level bar's fill.
    static let levelBar = dyn(0x5BD6FF, 0x0190A9)

    /// Text drawn ON a tint of its OWN hue. Putting `cyan` on `tintCyan` is the natural thing
    /// to write and it does not reach 4.5:1 in either theme (measured 3.66:1 light, and
    /// `red` on `tintBad` only 4.00:1 in dark) — a tint and its accent are by construction
    /// close in hue, so only lightness can separate them and the tint has already spent it
    /// staying distinct from the surface behind it. Same hue, pushed to the legible end.
    static let cyanOnTint = dyn(0x00E2FF, 0x00697F)
    static let amberOnTint = dyn(0xFFCD00, 0x815700)
    static let redOnTint = dyn(0xFF495B, 0xC20024)

    // waveform envelope: inside vs outside the intro, 14.5 ΔL* apart in dark, 14.4 in light
    static let waveOut = dyn(0x3E4A61, 0xA2ACB9)
    static let waveIn = dyn(0x5C6D8C, 0x7C8693)

    /// One definition, two themes. A dynamic `NSColor` is resolved by AppKit against whatever
    /// appearance is current, so nothing in the app has to know which theme is on and no view
    /// needs to observe the setting to repaint.
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: 1)
    }

    /// Every value above, by name, so `--palettetest` can measure the real thing rather than a
    /// copy of it that drifts.
    static let audit: [(String, UInt32, UInt32)] = [
        ("bg", 0x0A0C10, 0xC7CDD3), ("panel", 0x161A22, 0xD9DFE6),
        ("panel2", 0x222834, 0xE8EFF5), ("panel3", 0x2F3747, 0xD2D8DF),
        ("float", 0x3A4358, 0xFFFFFF), ("hair", 0x272E3A, 0xC1C7CE),
        ("line", 0x3C4659, 0xABB1B8), ("lineStrong", 0x5A6880, 0x81878D),
        ("text", 0xEAECF0, 0x1F2429), ("muted", 0xA7B1C2, 0x555A60),
        ("dim", 0x7C8799, 0x70757B), ("ink", 0x0A0C10, 0xFFFFFF),
        ("accent", 0x4A8CFF, 0x0063D6), ("cyan", 0x1FC8E8, 0x007A93),
        ("green", 0x2FD17A, 0x1F5534), ("greenText", 0x7DE9AF, 0x0A4C2F),
        ("red", 0xF4374E, 0xE1123E), ("amber", 0xFFC53D, 0x926800),
        ("purple", 0xA06BFF, 0x6E3FCD), ("onsite", 0xF763B8, 0xC82C8D),
        ("header", 0xC8402A, 0xBA2616),
        ("waveOut", 0x3E4A61, 0xA2ACB9), ("waveIn", 0x5C6D8C, 0x7C8693),
        ("hook", 0xA06BFF, 0x6E3FCD),
        ("tintCyan", 0x12303F, 0xBDE3EE), ("tintCyanLine", 0x2A6B80, 0x6AAABB),
        ("tintWarn", 0x2A2418, 0xF3D9B0), ("tintWarnLine", 0x6B5A33, 0xBB9C64),
        ("tintSelect", 0x243049, 0xD3D9F7), ("tintSelectText", 0xCFE0FF, 0x214583),
        ("tintGood", 0x121F22, 0xC0E6CA), ("tintBad", 0x2E2412, 0xFFD2CF),
        ("tintGoodLine", 0x2F5B41, 0x78AC88), ("levelBar", 0x5BD6FF, 0x0190A9),
        ("onWave", 0xFFFFFF, 0x0A0C10), ("outline", 0x0A0C10, 0x0A0C10),
        ("cyanOnTint", 0x00E2FF, 0x00697F), ("amberOnTint", 0xFFCD00, 0x815700),
        ("redOnTint", 0xFF495B, 0xC20024),
        ("onHeader", 0xFFFFFF, 0xFFFFFF), ("onHeaderWarn", 0xFFC53D, 0xFFC53D),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Scroll wheel and trackpad pinch, neither of which SwiftUI exposes on macOS.
///
/// The obvious route — an NSView overriding `scrollWheel(with:)` — cannot work on this surface.
/// AppKit routes scroll events by hit-testing, so the view must claim the cursor; but the same
/// surface carries click-to-seek, panning and marker drags from a SwiftUI gesture, which that
/// NSView would then swallow. Returning nil from `hitTest` kept the clicks working and silently
/// killed the zoom. So this view only reports where it is, and a local NSEvent monitor filters
/// scroll/magnify events down to that rect.
struct WheelCatcher: NSViewRepresentable {
    var onWheel: (_ dx: CGFloat, _ dy: CGFloat, _ locationX: CGFloat, _ width: CGFloat, _ precise: Bool) -> Void
    var onMagnify: (_ mag: CGFloat, _ locationX: CGFloat, _ width: CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView { let v = ProbeView(); v.owner = self; return v }
    func updateNSView(_ v: ProbeView, context: Context) { v.owner = self }
    static func dismantleNSView(_ v: ProbeView, coordinator: ()) { v.teardown() }

    final class ProbeView: NSView {
        var owner: WheelCatcher?
        private var monitors: [Any] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard window != nil else { return }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
                guard let self, let p = self.localPoint(e) else { return e }
                self.owner?.onWheel(e.scrollingDeltaX, e.scrollingDeltaY, p.x,
                                    self.bounds.width, e.hasPreciseScrollingDeltas)
                return nil
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] e in
                guard let self, let p = self.localPoint(e) else { return e }
                self.owner?.onMagnify(e.magnification, p.x, self.bounds.width)
                return nil
            }) { monitors.append(m) }
        }

        func teardown() {
            for m in monitors { NSEvent.removeMonitor(m) }
            monitors = []
        }
        deinit { teardown() }

        /// nil unless the event belongs to our window and landed inside our rect.
        private func localPoint(_ e: NSEvent) -> NSPoint? {
            guard let w = window, e.window === w else { return nil }
            let p = convert(e.locationInWindow, from: nil)
            return bounds.contains(p) ? p : nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks belong to SwiftUI
        override var acceptsFirstResponder: Bool { false }
    }
}

/// What a press on the waveform means for the markers. Pure on purpose: the rule has two
/// load-bearing details that are invisible in a screenshot and silently breakable, so
/// `--grabtest` proves them without driving the UI.
///
///  1. **Two stages.** A marker must already be the active one before a press can drag it.
///     Otherwise the press only activates it. These are values the setter signed off, on the same
///     surface the operator pans and seeks on, and the old one-stage grab moved whichever line a
///     press happened to land within 8pt of.
///  2. **`<=`, not `<`, on the distance tie-break.** With two markers on the same time the later
///     one could never win, so Intro End was unreachable — which is exactly song 102's real state
///     in `config.json` (`introStart == introEnd`).
enum MarkerGrab {
    enum Outcome: Equatable {
        case drag(MarkerField)      // it was already active — move it
        case activate(MarkerField)  // make it active and consume the gesture
        case away                   // no marker near the press: pan or seek as before
    }

    static func decide(pressX: CGFloat,
                       positions: [(field: MarkerField, x: CGFloat)],
                       active: MarkerField,
                       slop: CGFloat = 8) -> Outcome {
        var best: MarkerField?
        var bd = slop
        for m in positions {
            let d = abs(m.x - pressX)
            if d < bd {
                bd = d; best = m.field
            } else if d == bd {
                // TIE. `<=` (later wins) is what makes Intro End reachable when two markers
                // sit on the same time — song 102's real state. But applied blindly it also
                // made Intro Start **permanently undraggable** while stacked: every press
                // returned Intro End, which merely moved focus OFF Intro Start, and `M` could
                // not help because the next press moved it off again. The active marker wins a
                // tie; otherwise the later one still does.
                if m.field == active { best = m.field }
                else if best != active { best = m.field }
            }
        }
        guard let best else { return .away }
        return best == active ? .drag(best) : .activate(best)
    }
}

struct WaveformView: View {
    @EnvironmentObject var model: AppModel

    /// Which marker a drag grabbed, if any. Away from a marker a drag pans and a click seeks.
    @State private var dragKey: WritableKeyPath<SongConfig, Double>?
    /// Set when a press landed on a marker that was NOT the active one. That press only ACTIVATES
    /// it — see the two-stage rule in the gesture below — and the rest of the gesture is consumed
    /// so it can neither move the marker, pan the view, nor seek.
    @State private var arming = false
    @State private var armedExplained = false
    @State private var panning = false
    @State private var panLast: CGFloat = 0
    /// The whole question as it stood when the drag grabbed a marker, so "did anything change"
    /// is answered over every field rather than the one being dragged — `updateConfig` also
    /// nudges `introEnd` to keep `minIntro`, so a drag out and back changed the config while
    /// the dragged field finished where it started.
    @State private var dragFrom: SongBase?
    /// Marker time minus cursor time at the moment of the grab. Dragging RELATIVE to where the
    /// line was grabbed is what makes "a press that moves nothing writes nothing" true by
    /// construction: writing the cursor's own time instead teleported the marker by up to the
    /// 8 pt slop, which at full-song zoom is over a second.
    @State private var dragOffset: Double = 0
    private let panSlop: CGFloat = 4

    private func timeToX(_ t: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((t - model.viewStart) / model.viewSpan) * w
    }
    private func xToTime(_ x: CGFloat, _ w: CGFloat) -> Double {
        model.viewStart + Double(x / max(1, w)) * model.viewSpan
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let c = model.config()
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size, c: c)
                }
                if model.analysing {
                    Text("กำลังวิเคราะห์คลื่นเสียง…")
                        .font(Typo.font(13)).foregroundStyle(Palette.muted)
                        .frame(width: w, height: h)
                } else if model.analysis == nil {
                    Text("— ยังไม่ได้เลือกเพลง —")
                        .font(Typo.font(13)).foregroundStyle(Palette.muted)
                        .frame(width: w, height: h)
                }
                WheelCatcher(onWheel: { dx, dy, lx, width, precise in
                    guard model.player.duration > 0 else { return }
                    if abs(dx) > abs(dy) {
                        model.pan(by: Double(-dx / max(1, width)) * model.viewSpan)
                    } else {
                        // AppKit's scrollingDeltaY is positive scrolling UP; the web's DOM deltaY
                        // is positive scrolling DOWN. Negate, or the zoom runs backwards from the
                        // version the GM learned on.
                        let k = precise ? 1.0022 : 1.06
                        model.zoom(factor: pow(k, Double(-dy)), focus: xToTime(lx, width))
                    }
                }, onMagnify: { mag, lx, width in
                    guard model.player.duration > 0 else { return }
                    model.zoom(factor: 1 / (1 + Double(mag)), focus: xToTime(lx, width))
                })
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // SwiftUI does not guarantee `onEnded` for a cancelled gesture (a sheet opening
            // mid-press, for instance). `arming` is the one flag that blocks ALL THREE things
            // this surface does — drag, pan and seek — so if it stuck true the waveform went
            // completely dead with no way back. Clear it whenever the song changes.
            .onChange(of: model.current) { _ in
                arming = false; dragKey = nil; panning = false; dragFrom = nil
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard model.player.duration > 0 else { return }
                        if arming {
                            // Explain the no-op, but only once the hand actually tried to drag —
                            // a plain select-click needs no toast, a drag that did nothing does.
                            if abs(g.translation.width) >= panSlop && !armedExplained {
                                armedExplained = true
                                model.flash("เลือก \(model.focusMarker.label) แล้ว — ลากอีกครั้งเพื่อเลื่อน")
                            }
                            return
                        }
                        if dragKey == nil && !panning {
                            let pos = MarkerField.times.compactMap { f -> (field: MarkerField, x: CGFloat)? in
                                guard let k = f.timeKey else { return nil }
                                return (f, timeToX(c[keyPath: k], w))
                            }
                            switch MarkerGrab.decide(pressX: g.startLocation.x, positions: pos,
                                                     active: model.focusMarker) {
                            case .activate(let f):
                                model.focus(f)
                                arming = true
                                armedExplained = false
                                return
                            case .drag(let f):
                                guard let k = f.timeKey else { return }
                                dragKey = k
                                let live = model.config()
                                dragFrom = live.current
                                dragOffset = live[keyPath: k] - xToTime(g.startLocation.x, w)
                            case .away:
                                panLast = g.startLocation.x
                            }
                        }
                        if let k = dragKey {
                            let t = max(0, min(model.player.duration,
                                               xToTime(g.location.x, w) + dragOffset))
                            let v = (t * 100).rounded() / 100
                            // A press that moves nothing must WRITE nothing — `updateConfig`
                            // stamps `configured` and pushes an undo snapshot, so a click
                            // merely to pick the marker up would mark an unreviewed guess as
                            // reviewed and drop the song out of the Return/Tab sweep and the
                            // pre-flight. With the grab offset above, a still cursor gives back
                            // exactly the stored value and this comparison is what it says.
                            if v != model.config()[keyPath: k] {
                                // commit:false — re-levelling the gain per frame steps and clicks.
                                model.updateConfig(commit: false) { $0[keyPath: k] = v }
                            }
                        } else {
                            let dx = g.location.x - panLast
                            if !panning && abs(g.translation.width) < panSlop { return }
                            panning = true
                            model.pan(by: -Double(dx / max(1, w)) * model.viewSpan)
                            panLast = g.location.x
                        }
                    }
                    .onEnded { g in
                        // The WHOLE question, not just the dragged field: `updateConfig` clamps
                        // `introEnd >= introStart + minIntro`, so dragging Intro Start out and
                        // back leaves Intro End pushed out while the dragged value matches.
                        // Skipping the commit then skips `remode` and the re-level.
                        let moved = dragFrom.map { model.config().current != $0 } ?? false
                        let wasMarker = dragKey != nil
                        let wasArming = arming
                        defer { dragKey = nil; panning = false; arming = false; dragFrom = nil }
                        guard model.player.duration > 0 else { return }
                        if wasArming {
                            return                    // the press only activated a marker
                        } else if wasMarker {
                            // Only when the value actually moved: `commitConfig` re-levels,
                            // re-schedules the node and ends the undo coalescing window.
                            if moved { model.commitConfig() }
                        } else if !panning {
                            // The LIVE config: `seek` hands it to `modeForPosition`, so a stale
                            // `introEnd` would decide whether the intro-end guard stays armed.
                            model.player.seek(to: xToTime(g.location.x, w), config: model.config())
                        }
                    }
            )
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, c: SongConfig) {
        let w = size.width, h = size.height
        guard let a = model.analysis, a.isReady, w > 1 else { return }
        let cols = a.columnPeaks(viewStart: model.viewStart, viewEnd: model.viewEnd, width: Int(w))
        let mid = h / 2
        let x1 = timeToX(c.introStart, w), x2 = timeToX(c.introEnd, w)
        let introHi = c.ignoreEnd ? w : x2

        // Envelope, brighter INSIDE the intro. The intro then reads as the selected material
        // without a translucent tint fighting the ink on top of it.
        var inside = Path(), outside = Path()
        for x in 0..<cols.count {
            let amp = CGFloat(cols[x]) * h * 0.46
            if amp <= 0 { continue }
            let r = CGRect(x: CGFloat(x), y: mid - amp, width: 1, height: amp * 2)
            if CGFloat(x) >= x1 && CGFloat(x) <= introHi { inside.addRect(r) } else { outside.addRect(r) }
        }
        ctx.fill(outside, with: .color(Palette.waveOut))
        ctx.fill(inside, with: .color(Palette.waveIn))

        // The intro range, bracketed by rules on BOTH edges. A tint alone does not survive the
        // progress wash drawn over it.
        ctx.fill(Path(CGRect(x: x1, y: 0, width: introHi - x1, height: h)),
                 with: .color(Palette.cyan.opacity(0.10)))
        ctx.fill(Path(CGRect(x: x1, y: 0, width: introHi - x1, height: 2)),
                 with: .color(Palette.cyan.opacity(0.75)))
        ctx.fill(Path(CGRect(x: x1, y: h - 2, width: introHi - x1, height: 2)),
                 with: .color(Palette.cyan.opacity(0.75)))

        // Progress is one-dimensional, so it gets one edge. The old full-height accent rect sat
        // ON TOP of the intro zone, so the zone changed colour as the playhead crossed it and
        // both read as "some kind of range".
        let px = timeToX(model.player.position, w)
        ctx.fill(Path(CGRect(x: 0, y: h - 6, width: px, height: 6)),
                 with: .color(Palette.accent.opacity(0.7)))

        // Where the setter left each marker, when it has moved since the handover: a faint ghost
        // stem plus a connector, so both the old position and the distance read at a glance.
        if let b = c.base {
            onsiteGhost(ctx, b.introStart, c.introStart, w, h)
            onsiteGhost(ctx, b.introEnd, c.introEnd, w, h)
            onsiteGhost(ctx, b.hook, c.hook, w, h)
        }

        // Opposite edges, so two markers on the same time can never occlude each other — which
        // is exactly song 102's real state (introStart == introEnd).
        let fm = model.focusMarker
        marker(ctx, x1, Palette.cyan, h, "IN", top: true, focused: fm == .introStart)
        marker(ctx, x2, c.ignoreEnd ? Palette.cyan.opacity(0.3) : Palette.cyan, h, "OUT",
               top: false, focused: fm == .introEnd)
        if c.hook > 0 {
            marker(ctx, timeToX(c.hook, w), Palette.hook, h, "HOOK", top: true, dashed: true,
                   focused: fm == .hook)
        }

        // A proposal awaiting its second press: dashed stem, HOLLOW cap, frozen at the position
        // of the first press. The playhead keeps moving away from it, which is what makes "this
        // is the value you would commit" legible.
        if let pm = model.pending, pm.field != .ignoreEnd {
            let gx = timeToX(pm.t, w)
            var dash = Path()
            var y: CGFloat = 0
            while y < h { dash.addRect(CGRect(x: gx - 1, y: y, width: 2, height: 3)); y += 6 }
            ctx.fill(dash, with: .color(Palette.cyan.opacity(0.7)))
            var tri = Path()
            tri.move(to: CGPoint(x: gx - 7, y: 1))
            tri.addLine(to: CGPoint(x: gx + 7, y: 1))
            tri.addLine(to: CGPoint(x: gx, y: 12))
            tri.closeSubpath()
            ctx.stroke(tri, with: .color(Palette.cyan), lineWidth: 1.5)
        }

        // Hairlines either side keep the playhead readable over both envelope shades, and the cap
        // stops it reading as a fourth marker when parked on one.
        ctx.fill(Path(CGRect(x: px - 2, y: 0, width: 4, height: h)), with: .color(Palette.outline))
        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(.white))
        var cap = Path()
        cap.move(to: CGPoint(x: px - 5, y: mid - 6))
        cap.addLine(to: CGPoint(x: px + 5, y: mid - 6))
        cap.addLine(to: CGPoint(x: px, y: mid + 2))
        cap.closeSubpath()
        // The cap sits above the waveform on bare panel, where white measures 1.16:1 in light.
        // The playhead's own hairline is `outline` for the same reason.
        ctx.fill(cap, with: .color(Palette.onWave))
    }

    private func onsiteGhost(_ ctx: GraphicsContext, _ was: Double, _ now: Double,
                             _ w: CGFloat, _ h: CGFloat) {
        guard !SongConfig.same(was, now) else { return }
        let gx = timeToX(was, w), nx = timeToX(now, w)
        let c = Palette.onsite.opacity(0.5)
        var dash = Path()
        var y: CGFloat = 0
        while y < h { dash.addRect(CGRect(x: gx - 0.5, y: y, width: 1, height: 2)); y += 8 }
        ctx.fill(dash, with: .color(c))
        ctx.fill(Path(CGRect(x: min(gx, nx), y: h / 2 - 0.5, width: abs(nx - gx), height: 1)),
                 with: .color(c))
    }

    /// `label` goes ON the flag: the legend lives in another view and only renders when the window
    /// is wide, and two 3pt coloured lines are not a distinction under studio light at 1x.
    /// `focused` marks the one `Shift+←/→` will nudge. It is carried by WIDTH and an outline, not
    /// by a different hue: every hue in this app already means exactly one thing, and "which of
    /// these three am I nudging" is not worth a fourth meaning for cyan.
    private func marker(_ ctx: GraphicsContext, _ x: CGFloat, _ color: Color, _ h: CGFloat,
                        _ label: String, top: Bool, dashed: Bool = false, focused: Bool = false) {
        let stem: CGFloat = focused ? 3 : 2
        if dashed {
            var p = Path()
            var y: CGFloat = 0
            while y < h { p.addRect(CGRect(x: x - stem / 2, y: y, width: stem, height: 5)); y += 8 }
            ctx.fill(p, with: .color(color))
        } else {
            ctx.fill(Path(CGRect(x: x - stem / 2, y: 0, width: stem, height: h)), with: .color(color))
        }
        let yBase: CGFloat = top ? 0 : h
        let dir: CGFloat = top ? 1 : -1
        var tri = Path()
        tri.move(to: CGPoint(x: x - 6, y: yBase))
        tri.addLine(to: CGPoint(x: x + 6, y: yBase))
        tri.addLine(to: CGPoint(x: x, y: yBase + 9 * dir))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(color))
        if focused {
            var ring = Path()
            ring.move(to: CGPoint(x: x - 9, y: yBase + 0.5 * dir))
            ring.addLine(to: CGPoint(x: x + 9, y: yBase + 0.5 * dir))
            ring.addLine(to: CGPoint(x: x, y: yBase + 13 * dir))
            ring.closeSubpath()
            // `outline`, not white: this is the focus ring on the marker Shift+←/→ will move,
            // and §11 says that state is carried by "width AND an outline". White on the light
            // theme's bed is 1.14:1 — half the cue gone, leaving a 3pt-vs-2pt stem.
            ctx.stroke(ring, with: .color(Palette.onWave.opacity(0.9)), lineWidth: 1.5)
        }
        // `.foregroundStyle` on Text is macOS 14+; this app targets 13.
        ctx.draw(Text(label).font(Typo.font(10, .bold, latinOnly: true)).foregroundColor(color),
                 at: CGPoint(x: x + 4, y: top ? 15 : h - 15), anchor: .leading)
    }
}

/// A fixed whole-song strip under the waveform.
///
/// `select()` now opens zoomed on the intro, which is right — but it meant nothing on screen said
/// WHERE in the song that window sat, so a hook at 1:40 and one at 3:10 looked identical and the
/// only way to orient yourself was to zoom out and lose the detail you came for.
///
/// It moves the VIEW and never the playhead. Two stacked surfaces where a click means different
/// things is how an intended pan becomes an accidental seek — and a seek while playing re-derives
/// the play mode, so that mistake can disarm the intro-end stop.
struct OverviewStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let c = model.config()
            Canvas { ctx, size in draw(ctx: ctx, size: size, c: c) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in centreView(at: g.location.x, w) }
                        .onEnded { g in centreView(at: g.location.x, w) }
                )
        }
        .frame(height: 34)
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("ทั้งเพลง — ลากเพื่อเลื่อนช่วงที่กำลังดู (ไม่ขยับหัวเล่น)")
    }

    private func centreView(at x: CGFloat, _ w: CGFloat) {
        let d = model.player.duration
        guard d > 0, w > 1 else { return }
        let t = Double(max(0, min(w, x)) / w) * d
        let span = model.viewSpan
        model.viewStart = t - span / 2
        model.viewEnd = model.viewStart + span
        model.clampView()
    }

    private func draw(ctx: GraphicsContext, size: CGSize, c: SongConfig) {
        let w = size.width, h = size.height
        let d = model.player.duration
        guard let a = model.analysis, a.isReady, w > 1, d > 0 else { return }
        func sx(_ t: Double) -> CGFloat { CGFloat(max(0, min(1, t / d))) * w }

        // Its own cache — see Analysis.overviewPeaks for why it cannot share the column cache.
        let cols = a.overviewPeaks(width: Int(w))
        let mid = h / 2
        var p = Path()
        for i in 0..<cols.count {
            let amp = max(0.5, CGFloat(cols[i]) * h * 0.42)
            p.addRect(CGRect(x: CGFloat(i), y: mid - amp, width: 1, height: amp * 2))
        }
        ctx.fill(p, with: .color(Palette.waveOut))

        let a0 = sx(c.introStart), a1 = sx(c.ignoreEnd ? d : c.introEnd)
        ctx.fill(Path(CGRect(x: a0, y: 0, width: max(1, a1 - a0), height: h)),
                 with: .color(Palette.cyan.opacity(0.28)))
        if c.hook > 0 {
            ctx.fill(Path(CGRect(x: sx(c.hook) - 1, y: 0, width: 2, height: h)),
                     with: .color(Palette.hook))
        }

        // The visible window, shown by dimming everything outside it rather than outlining it:
        // at 2560px wide a deep zoom is a 2px window, and a 2px outline is invisible while a
        // 2px gap in a dark wash is not.
        if model.isZoomed {
            let s = sx(model.viewStart), e = sx(model.viewEnd)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: s, height: h)),
                     with: .color(Palette.bg.opacity(0.62)))
            ctx.fill(Path(CGRect(x: e, y: 0, width: w - e, height: h)),
                     with: .color(Palette.bg.opacity(0.62)))
            ctx.stroke(Path(CGRect(x: s, y: 0.75, width: max(2, e - s), height: h - 1.5)),
                       with: .color(Palette.lineStrong), lineWidth: 1.5)
        }

        let px = sx(model.player.position)
        ctx.fill(Path(CGRect(x: px - 1.5, y: 0, width: 3, height: h)), with: .color(Palette.outline))
        ctx.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: h)), with: .color(.white))
    }
}

struct Markers {
    let key: WritableKeyPath<SongConfig, Double>
    let label: String
    let hot: String
    let color: Color
    /// Which stored field this marker is, for the on-site-edit badge and the revert button.
    var field: MarkerField? {
        switch key {
        case \SongConfig.introStart: return .introStart
        case \SongConfig.introEnd:   return .introEnd
        case \SongConfig.hook:       return .hook
        default: return nil
        }
    }

    static let all: [Markers] = [
        .init(key: \.introStart, label: "Intro Start", hot: "I", color: Palette.cyan),
        // CYAN, not green. §6d gives green exactly one meaning — "a human answered correctly" —
        // and names "Intro End marker" among the four it was supposed to have given up. The
        // waveform was already drawing both ends cyan, so the setup panel had been disagreeing
        // with the waveform about what colour this marker is. Invisible while both hues were
        // bright and cool; obvious the moment a light theme made them dark teal vs dark green.
        .init(key: \.introEnd, label: "Intro End", hot: "O", color: Palette.cyan),
        .init(key: \.hook, label: "Hook", hot: "H", color: Palette.hook),
    ]
}
