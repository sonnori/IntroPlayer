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
    // surfaces
    static let bg = Color(hex: 0x0A0C10)          // L* 3.3  — window
    static let panel = Color(hex: 0x161A22)       // L* 9.2  — the three panes
    static let panel2 = Color(hex: 0x222834)      // L* 16.0 — cards, waveform bed
    static let panel3 = Color(hex: 0x2F3747)      // L* 23.0 — controls inside a card
    static let float = Color(hex: 0x3A4358)       // L* 28.4 — sheets, popovers, toast
    static let hair = Color(hex: 0x272E3A)        // row dividers
    static let line = Color(hex: 0x3C4659)        // card and pane borders
    static let lineStrong = Color(hex: 0x5A6880)  // focus ring, floating-surface edge

    // text
    static let text = Color(hex: 0xEAECF0)        // 12.49:1 on panel2
    static let muted = Color(hex: 0xA7B1C2)       // 6.83:1
    static let dim = Color(hex: 0x7C8799)         // 4.07:1
    static let ink = Color(hex: 0x0A0C10)         // on a saturated fill

    /// Transport, and "playing the intro". Note accent vs violet collide at **deutan ΔE 1.2** —
    /// they are the same colour to a deutan viewer — so blue-vs-violet must never be the only
    /// carrier of the armed/disarmed state. That is why the guard uses amber plus a word.
    static let accent = Color(hex: 0x4A8CFF)
    /// The Intro bracket: BOTH ends. They are two ends of one range, told apart by which edge
    /// their flag sits on, which also makes two markers on the same time individually grabbable.
    static let cyan = Color(hex: 0x1FC8E8)
    /// Only ever "a human answered correctly".
    static let green = Color(hex: 0x2FD17A)
    static let greenText = Color(hex: 0x7DE9AF)
    /// Wrong / burned question, and destructive controls. Paired with `greenText` the outcome
    /// badges separate at **deutan ΔE 35.5**; the old #2ECC71 / #FF5566 pair was ΔE 7.3.
    static let red = Color(hex: 0xF4374E)
    /// Only ever "the intro-end stop is not armed, or something is wrong".
    static let amber = Color(hex: 0xFFC53D)
    /// Reveal, and the Hook marker it jumps to — one meaning, two places.
    static let purple = Color(hex: 0xA06BFF)
    static let hook = Color(hex: 0xA06BFF)
    /// Only ever "changed after the handover".
    static let onsite = Color(hex: 0xF763B8)
    /// White on the old #E25232 was **3.83:1** at 15px bold — below 4.5 and too small for the
    /// large-text exemption. This is 4.97:1.
    static let header = Color(hex: 0xC8402A)

    // waveform envelope: inside vs outside the intro, 14.5 ΔL* apart
    static let waveOut = Color(hex: 0x3E4A61)
    static let waveIn = Color(hex: 0x5C6D8C)
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

struct WaveformView: View {
    @EnvironmentObject var model: AppModel

    /// Which marker a drag grabbed, if any. Away from a marker a drag pans and a click seeks.
    @State private var dragKey: WritableKeyPath<SongConfig, Double>?
    @State private var panning = false
    @State private var panLast: CGFloat = 0
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard model.player.duration > 0 else { return }
                        if dragKey == nil && !panning {
                            // grab a marker if the press landed within 8pt of one
                            var best: WritableKeyPath<SongConfig, Double>?
                            var bd: CGFloat = 8
                            for m in Markers.all {
                                let mx = timeToX(c[keyPath: m.key], w)
                                // `<=`, not `<`: with two markers on the same time the later one
                                // could never win, so Intro End was unreachable on the waveform.
                                // config.json has song 102 in exactly that state.
                                if abs(mx - g.startLocation.x) <= bd { bd = abs(mx - g.startLocation.x); best = m.key }
                            }
                            if let best {
                                dragKey = best
                                // The nudge target follows the hand: whatever was just dragged is
                                // what Shift+arrow should refine.
                                if let f = MarkerField.times.first(where: { $0.timeKey == best }) {
                                    model.focus(f)
                                }
                            } else { panLast = g.startLocation.x }
                        }
                        if let k = dragKey {
                            let t = max(0, min(model.player.duration, xToTime(g.location.x, w)))
                            // commit:false — re-levelling the gain per frame steps and clicks.
                            model.updateConfig(commit: false) { $0[keyPath: k] = (t * 100).rounded() / 100 }
                        } else {
                            let dx = g.location.x - panLast
                            if !panning && abs(g.translation.width) < panSlop { return }
                            panning = true
                            model.pan(by: -Double(dx / max(1, w)) * model.viewSpan)
                            panLast = g.location.x
                        }
                    }
                    .onEnded { g in
                        let wasMarker = dragKey != nil
                        defer { dragKey = nil; panning = false }
                        guard model.player.duration > 0 else { return }
                        if wasMarker {
                            model.commitConfig()      // re-level and re-schedule now the drag is over
                        } else if !panning {
                            model.player.seek(to: xToTime(g.location.x, w), config: c)
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

        // The window a hook audition will play, while one is running. Drawn under the markers so
        // the HOOK flag stays on top of its own band.
        if model.previewArmed {
            let s0 = timeToX(c.hook, w)
            let s1 = timeToX(min(model.player.duration, c.hook + Player.previewSec), w)
            ctx.fill(Path(CGRect(x: s0, y: 0, width: max(1, s1 - s0), height: h)),
                     with: .color(Palette.hook.opacity(0.16)))
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
        ctx.fill(Path(CGRect(x: px - 2, y: 0, width: 4, height: h)), with: .color(Palette.ink))
        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(.white))
        var cap = Path()
        cap.move(to: CGPoint(x: px - 5, y: mid - 6))
        cap.addLine(to: CGPoint(x: px + 5, y: mid - 6))
        cap.addLine(to: CGPoint(x: px, y: mid + 2))
        cap.closeSubpath()
        ctx.fill(cap, with: .color(.white))
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
            ctx.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
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
        ctx.fill(Path(CGRect(x: px - 1.5, y: 0, width: 3, height: h)), with: .color(Palette.ink))
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
        .init(key: \.introEnd, label: "Intro End", hot: "O", color: Palette.green),
        .init(key: \.hook, label: "Hook", hot: "H", color: Palette.hook),
    ]
}
