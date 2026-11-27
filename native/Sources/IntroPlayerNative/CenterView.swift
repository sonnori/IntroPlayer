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
                Spacer(minLength: 12)
                noteBox
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
                    if model.centreIsWide {
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
                        .foregroundStyle(Palette.dim.opacity(0.7))
                        // Furniture: it means "no cover art", which the absence of a picture
                        // already says. Labelling it would announce a decoration as content.
                        .accessibilityHidden(true))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line)
            .allowsHitTesting(false))
    }

    /// The setter's note, where the operator reads it: beside the title, at the moment they open
    /// the question. Read-only here — it is typed in SETUP.
    ///
    /// **It costs zero height, and that is the reason it is HERE.** This row is already 52 pt
    /// tall because of `coverFrame`, and the title is `lineLimit(1)`, so a box up to two 13 pt
    /// lines (46 pt with its padding) fits inside the row's existing height. §15 is why that
    /// matters: the only flexible child of this pane is the waveform, with a hard
    /// `minHeight: 160` floor, and past that floor content that overruns the window centres and
    /// clips BOTH ends — the title off the top and ✓ Correct / ✗ Wrong off the bottom, with no
    /// scroller. `App.swift`'s declared `minHeight: 640` is already 13–67 pt short of what this
    /// pane needs with no banners up. A free-text field of unbounded length in the centre pane
    /// is the one shape that could push the scoring buttons off the screen.
    ///
    /// `.lineLimit(2)` below is what makes that impossible rather than unlikely, and it is NOT
    /// the length cap doing it: `Store.noteMax` is tuned for Thai, and 120 Latin capitals are
    /// far wider than 120 Thai clusters. The cap keeps truncation rare; the line limit is the
    /// guarantee. Don't remove it on the grounds that the text is already bounded.
    ///
    /// No hue. A note is not a warning and it sits ~60 pt from the guard strip, where amber has
    /// exactly one meaning (§6d). The edge bar is `lineStrong`, the same neutral the focused
    /// marker card uses.
    ///
    /// Rendered only when there IS a note. Absence then means "this song has no note", which is
    /// unambiguous — and an always-present empty frame in the operator's eyeline is the same
    /// decoration §6e removed when it took out the green dot. Nothing below or beside it moves
    /// when it appears: the title truncates rather than reflows, and truncating a title is not a
    /// hit target (which is what the cover frame's always-rendered rule is actually protecting).
    @ViewBuilder
    private var noteBox: some View {
        if model.current != nil {
            let c = model.config()
            if !c.note.isEmpty || !c.tags.isEmpty {
                Text(CenterView.noteText(c, colors: model.store.tagColors))
                    .multilineTextAlignment(.leading)
                    // Two lines is the height budget above, for ANY content. Nothing else
                    // bounds it: not `Store.noteMax`, not `tagsPerSong`.
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(Palette.panel2)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.lineStrong).frame(width: 3)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(CenterView.plainNoteText(c))
                    .accessibilityLabel(CenterView.plainNoteText(c))
            }
        }
    }

    /// One paragraph, two styles. The note and the tags share the same two lines rather than
    /// taking a line each, because a separate tag row costs ~15 pt of real height and the
    /// argument above is that this box costs none.
    ///
    /// **The note comes first and the tags trail**, and that order is the whole decision: with
    /// `.lineLimit(2)` something has to truncate, and losing the sentence the setter wrote is
    /// worse than losing the last of a list the setter can also see in SETUP.
    ///
    /// `static` so `--tagtest` can measure exactly what the pane will draw — §6d's rule that a
    /// layout claim gets measured, not asserted.
    static func noteText(_ c: SongConfig, colors: [String: Int] = [:]) -> AttributedString {
        var out = AttributedString("")
        if !c.note.isEmpty {
            var a = AttributedString(c.note)
            a.font = Typo.font(13)
            a.foregroundColor = Palette.text
            out += a
        }
        if !c.tags.isEmpty {
            if !c.note.isEmpty {
                var gap = AttributedString("   ")
                gap.font = Typo.font(12)
                out += gap
            }
            // Each tag in its own ink (§8g). It used to be one muted run for the lot, on the
            // rule that a tag has no state to report — which is still true, and is exactly why
            // this is safe: the WORD is always there, so the colour is a second cue on
            // something already named, never the only carrier. `--palettetest` holds the other
            // half, that no tag ink can be mistaken for green, red or amber.
            for (n, tag) in c.tags.enumerated() {
                if n > 0 {
                    // A plain space, not " · ": with the tag runs now carrying a FILL, the
                    // separator's own job is done by the gap between two fills, and a dot
                    // floating between two chips reads as a third thing.
                    var sep = AttributedString(" ")
                    sep.font = Typo.font(12)
                    out += sep
                }
                // Filled like the chips in the song list, asked for as "UI สีของ Tag เป็นแบบสีๆ
                // ที่แสดงใน list เพลง".
                //
                // **An attributed run with a `backgroundColor`, not a real `TagChip`.** A chip is
                // a view, so a row of them needs `FlowRow` beside the note's `Text`, and §8g
                // measures a separate tag row at ~15 pt of REAL height — which this box does not
                // have. The whole argument for the note living in the centre pane is that it
                // costs nothing: the title row is already 52 pt because of `coverFrame`, and
                // `.lineLimit(2)` on one `Text` is what makes overflow impossible rather than
                // unlikely. Two sibling views cannot carry that guarantee between them, and past
                // the waveform's `minHeight: 160` floor the overrun clips the song title off the
                // top and ✓/✗ off the bottom (§15).
                //
                // So: same colours, same meaning, and the line-limit guarantee intact. What it
                // gives up against a real chip is the rounded corner.
                //
                // The thin spaces (U+2009) are the chip's horizontal padding — without them the
                // fill stops at the glyph edges and the words run into each other.
                var t = AttributedString("\u{2009}\(tag)\u{2009}")
                t.font = Typo.font(12)
                if colors.isEmpty {
                    t.foregroundColor = Palette.muted
                } else {
                    let i = colors[Store.tagKey(tag)] ?? 0
                    t.foregroundColor = Palette.tagInkAt(i)
                    t.backgroundColor = Palette.tagFillAt(i)
                }
                out += t
            }
        }
        return out
    }

    /// How many runs of `noteText` carry a tag FILL, and whether the note's own run does.
    ///
    /// Exists so `--tagtest` can assert the thing the eye is supposed to see, from a file that
    /// imports AppKit rather than SwiftUI — reading `run.backgroundColor` needs the SwiftUI
    /// attribute scope, and the conversion to `NSAttributedString` does not carry it. Without
    /// this the fill could be deleted and all 25 suites would stay green: the `Palette.audit`
    /// lesson, which §6d records costing a palette its deutan separation.
    static func noteTagFillAudit(_ c: SongConfig, colors: [String: Int]) -> (filled: Int,
                                                                            noteFilled: Bool) {
        let at = noteText(c, colors: colors)
        var filled = 0
        var noteFilled = false
        for run in at.runs {
            let hasFill = run.backgroundColor != nil
            if hasFill { filled += 1 }
            // The note is the first run when there is one, and it must stay unfilled: a
            // highlighted sentence in the operator's eyeline reads as a warning, and §6d gives
            // every hue exactly one meaning.
            if !c.note.isEmpty, run.range.lowerBound == at.startIndex, hasFill {
                noteFilled = true
            }
        }
        return (filled, noteFilled)
    }

    /// The same text for a tooltip and for VoiceOver, which take a plain `String`.
    static func plainNoteText(_ c: SongConfig) -> String {
        [c.note, c.tags.joined(separator: " · ")]
            .filter { !$0.isEmpty }.joined(separator: " — ")
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
            // Moved to sit immediately right of Reveal, as asked — it is pressed once per
            // question, which Reset is not. Two things about that are worth writing down.
            //
            // The order is FIXED, and changing it moves muscle memory: §12 records that sliding
            // transport buttons meant "a click aimed at Reset could land on Reveal". This swap
            // makes Reveal's right-hand neighbour the harmless toggle instead of Reset, which is
            // the better of the two arrangements for a slip rightwards — and it makes Played's
            // left-hand neighbour Reveal, which is the worse one for a slip leftwards. Net: the
            // button pressed most often is now next to the one that costs a take. Accepted
            // knowingly; the 12 pt gap is all that separates them.
            //
            // **Amber, never green.** This read `Palette.green` when set, which is a live §6d
            // violation — green means "a human answered correctly" and nothing else, and §12
            // records that `✓` once meant both "played" and "correct" with two near-identical
            // glyphs. The SETUP card for the same flag has always been `tintWarn`; these two
            // now agree.
            actionButton(c.played ? "✓ เล่นแล้ว" : "ทำเครื่องหมายเล่นแล้ว", "T",
                         c.played ? Palette.tintWarn : Palette.panel2,
                         c.played ? Palette.amberOnTint : Palette.text,
                         width: 190) {
                model.updateConfigQuiet { $0.played.toggle() }
            }
            .pulseTarget(PulseID.played)
            actionButton("⟲ Reset", "S", Palette.panel2, Palette.text, width: 150) {
                model.cancelPending()
                model.player.reset(config: c)
            }
            .pulseTarget(PulseID.reset)
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
