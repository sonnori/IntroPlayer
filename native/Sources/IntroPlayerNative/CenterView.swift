import SwiftUI

struct CenterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // Always rendered, even with no art. A frame that appears and disappears moves
                // the title and everything under it sideways — the same defect §12 records for
                // the focus hint and the transport buttons.
                coverFrame
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.current.map(Library.displayTitle) ?? "No song selected")
                        .font(Typo.display)
                        .lineLimit(1).foregroundStyle(Palette.text)
                    Text(subtitle).font(Typo.font(13)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }

            guardStrip

            VStack(spacing: 0) {
                HStack {
                    // 0.01 s, because that is the precision markers are stored at: with only
                    // `m:ss` the setter could not verify what I/O/H had just placed.
                    Text(fmtTime(model.player.position))
                    Text(String(format: ".%02d", Int((model.player.position * 100).rounded()) % 100))
                        .foregroundStyle(Palette.muted.opacity(0.7))
                    Spacer()
                    Text(fmtTime(model.player.duration))
                }
                .font(Typo.font(13, mono: true)).foregroundStyle(Palette.muted)
                .padding(.bottom, 6)

                // Was pinned at 140pt with ~580pt of empty Spacer below it. A quiet lead-in
                // rendered 3-4px tall, so "where does the music start" was unreadable — and the
                // marker drag target was a sliver.
                WaveformView()
                    // The strip below takes 40pt of fixed height out of this VStack, and the
                    // waveform is its only flexible child — with no floor it absorbs the whole
                    // shortfall and can reach 0, where the Canvas draws nothing and the marker
                    // drag targets vanish. Worst case is the minimum window with the save-failure
                    // bar and the receive banner both showing and the transport wrapped to 3 rows.
                    .frame(maxHeight: .infinity).frame(minHeight: 160)
                    .background(Palette.panel2)
                    // A stroke overlay is hit-testable, so this 1pt ring was eating seek clicks
                    // along the very edge of the waveform.
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(disarmed ? Palette.amber : Palette.line,
                                lineWidth: disarmed ? 2 : 1)
                        .allowsHitTesting(false))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                OverviewStrip().padding(.top, 6)

                HStack(spacing: 14) {
                    if model.isWide {
                        legend(Palette.cyan, "Intro start / end")
                        legend(Palette.hook, "Hook")
                    }
                    Spacer(minLength: 0)
                    zoomButton("−") { model.zoomBy(1.6) }.pulseTarget(PulseID.zoomOut, corner: 6)
                    zoomButton("+") { model.zoomBy(1 / 1.6) }.pulseTarget(PulseID.zoomIn, corner: 6)
                    zoomButton("ช่วง Intro") { model.zoomIntro() }.pulseTarget(PulseID.zoomIntro, corner: 6)
                    zoomButton("เต็มเพลง") { model.zoomFit() }.pulseTarget(PulseID.zoomFit, corner: 6)
                    Text(model.isZoomed ? "เห็น \(fmtSec(model.viewSpan))" : "เต็มเพลง")
                        .font(Typo.font(11, mono: true))
                        .foregroundStyle(Palette.muted).frame(width: 82, alignment: .trailing)
                }
                .padding(.top, 6)
            }
            .frame(maxHeight: .infinity)

            transport

            // 56pt apart, and each button runs to its pane edge: an edge is an infinitely large
            // target, so the operator can slam the cursor into it without looking. 12pt between
            // two ~700pt buttons meant a slip near the midline played the wrong sting on camera.
            HStack(spacing: 56) {
                bigButton("✓ Correct", "1", Palette.green, Palette.ink) { model.score("correct") }
                    .pulseTarget(PulseID.correct)
                bigButton("✗ Wrong", "2", Palette.red, .white) { model.score("wrong") }
                    .pulseTarget(PulseID.wrong)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - the intro-end guard, made structural

    /// The single most consequential state in the app: when this is true nothing stops playback
    /// at the end of the intro, and the whole song goes out on camera.
    ///
    /// The old status chip only rendered WHILE playing, so pausing past Intro End — or a stray
    /// `E` — left this invisible in exactly the moment the operator decides to press Space.
    ///
    private var disarmed: Bool {
        model.current != nil && !model.introGuardArmed
    }

    /// 52pt of reserved space for the cover. Empty is a faint outline, never nothing: see the
    /// note at the call site about layout shift.
    private var coverFrame: some View {
        let img = model.current.flatMap { model.cover(for: $0) }
        return Group {
            if let img {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
            } else {
                Rectangle().fill(Palette.panel2)
                    .overlay(Text("♪").font(Typo.font(17, latinOnly: true))
                        .foregroundStyle(Palette.dim.opacity(0.7)))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line)
            .allowsHitTesting(false))
    }

    private var guardStrip: some View {
        let c = model.config()
        let pending = model.pending
        return HStack(spacing: 14) {
            if let pm = pending {
                // A proposal, not a change. Nothing has been written yet.
                Text("กด \(keyHint(pm.field)) อีกครั้ง")
                    .font(Typo.font(17, .bold)).foregroundStyle(Palette.cyan)
                Text("→ \(pm.field.label) = \(String(format: "%.2f", pm.t))s")
                    .font(Typo.font(15, mono: true)).foregroundStyle(Palette.text)
                Text("(\(pm.field.label) เดิม \(MarkerField.text(pm.field, c)))")
                    .font(Typo.font(11)).foregroundStyle(Palette.muted)
            } else if disarmed {
                // `amberOnTint`, not `amber`: this text sits on an amber wash of its own hue,
                // which measured 2.70:1 in light — on the single most consequential state in
                // the app (§6d). A tint and its accent are close in hue by construction, so
                // only lightness can separate them, and the wash has already spent it.
                Text("⚠ ไม่หยุดเอง").font(Typo.font(20, .bold))
                    .foregroundStyle(Palette.amberOnTint)
                Text(c.ignoreEnd ? "ติ๊ก \"ข้าม Intro End\" อยู่ — กด E เพื่อปิด"
                                 : "หัวเล่นอยู่หลัง Intro End แล้ว")
                    .font(Typo.font(13)).foregroundStyle(Palette.amberOnTint)
            } else if model.current != nil {
                Text("หยุดเองที่").font(Typo.font(13)).foregroundStyle(Palette.muted)
                Text(String(format: "%.2fs", c.introEnd))
                    .font(Typo.font(13, mono: true)).foregroundStyle(Palette.text)
                Text("· \(model.player.mode.chipText)")
                    .font(Typo.font(13)).foregroundStyle(Palette.muted)
            }
            Spacer()
            // Armed has to be PROVEN by a moving number, not asserted by a label.
            if let left = model.secondsToStop, pending == nil {
                Text(String(format: "%.1f", left))
                    .font(Typo.font(28, .semibold, mono: true))
                    .foregroundStyle(left < 3 ? Palette.amber : Palette.text)
                Text("วิ").font(Typo.font(13)).foregroundStyle(Palette.muted)
            } else if pending == nil {
                Text("—").font(Typo.font(28, .semibold))
                    .foregroundStyle(Palette.muted.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(pending != nil ? Palette.tintCyan
                    : disarmed ? Palette.tintWarn : Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(pending != nil ? Palette.tintCyanLine
                    : disarmed ? Palette.tintWarnLine : Palette.line,
                    lineWidth: pending != nil || disarmed ? 2 : 1)
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func keyHint(_ f: MarkerField) -> String { f.hotKey }

    private var subtitle: String {
        guard let cur = model.current else { return "เลือกเพลงจากรายการด้านซ้าย" }
        let c = model.config()
        // Intro LENGTH was displayed nowhere, yet it is what the GM actually picks (§7a1) and
        // what the "shorter than 3 s" warning is about.
        var s = String(format: "ช่วง Intro %.1f วิ", max(0, c.introEnd - c.introStart))
        s += " · ยาว " + fmtTime(model.player.duration)
        let pl = Library.playlist(of: cur)
        if !pl.isEmpty { s += " · รอบ " + pl }
        if model.needsReview(cur) { s += " · ยังไม่ยืนยัน (กด Return)" }
        return s
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t).font(Typo.font(11)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .fixedSize()
    }

    private func zoomButton(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(11)).foregroundStyle(Palette.text)
                .padding(.horizontal, 10).frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var transport: some View {
        let c = model.config()
        let playing = model.player.isPlaying
        // wraps instead of compressing — a squeezed button renders its label as vertical text
        return FlowRow(spacing: 12) {
            // Fixed widths. `.fixedSize()` alone meant "▶ Start" -> "❚❚ Pause" changed the
            // button's width, so Reveal / Reset / Played slid sideways every time playback
            // started — and a click aimed at Reset could land on Reveal.
            //
            // Pause is `accent`, not amber: amber now means "the auto-stop is disarmed" and
            // nothing else, so it cannot also be the normal colour of the Pause button.
            actionButton(playing ? "❚❚ Pause" : "▶ Start", "Space", Palette.accent, .white,
                         width: 200) {
                model.cancelPending()
                model.player.toggleStart(config: c)
            }
            .pulseTarget(PulseID.start)
            actionButton("↪ Reveal (Hook)", "R", Palette.purple, .white, width: 210) {
                model.cancelPending()
                model.player.reveal(config: c)   // deliberately does not mark the song used
            }
            .pulseTarget(PulseID.reveal)
            actionButton("⟲ Reset", "S", Palette.panel2, Palette.text, width: 150) {
                model.cancelPending()
                model.player.reset(config: c)
            }
            .pulseTarget(PulseID.reset)
            actionButton(c.played ? "✓ Played" : "Mark Played", "P",
                         c.played ? Palette.green : Palette.panel2,
                         c.played ? Palette.ink : Palette.text,
                         width: 190) {
                model.updateConfigQuiet { $0.played.toggle() }
            }
            .pulseTarget(PulseID.played)
        }
        .disabled(model.current == nil)
    }

    private func actionButton(_ t: String, _ key: String, _ bg: Color, _ fg: Color,
                              width: CGFloat, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(t).font(Typo.font(15, .semibold))
                Text(key).font(Typo.micro).opacity(0.7)
            }
            .lineLimit(1)
            .frame(width: width).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(fg)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func bigButton(_ t: String, _ key: String, _ bg: Color, _ fg: Color,
                           _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(t).font(Typo.font(18, .semibold))
                Text(key).font(Typo.micro).opacity(0.7)
            }
            .frame(maxWidth: .infinity).frame(minHeight: 56).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(fg).background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
