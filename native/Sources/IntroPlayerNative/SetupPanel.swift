import AppKit
import SwiftUI

struct SetupPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SETUP — ตั้งช่วงเพลง")
                    .font(Typo.font(13, .semibold)).foregroundStyle(Palette.muted)
                    .padding(.bottom, 2)

                if model.current == nil {
                    Text("ยังไม่ได้เลือกเพลง").font(Typo.font(14))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    body(for: model.config())
                }
            }
            .padding(18)
        }
        .frame(width: 340)
        .background(Palette.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
    }

    @ViewBuilder
    private func body(for c: SongConfig) -> some View {
        wideButton(c.played ? "✓ เล่นแล้ว — กดเพื่อยกเลิก" : "ทำเครื่องหมายว่าเล่นแล้ว",
                   bg: c.played ? Palette.tintWarn : Palette.panel2,
                   fg: c.played ? Palette.amberOnTint : Palette.text,
                   border: c.played ? Palette.amber : Palette.line) {
            model.updateConfigQuiet { $0.played.toggle() }
        }

        if let d = model.current.flatMap({ model.donor(for: $0) }), !c.isConfigured {
            wideButton("⤵ ดึงค่าจากรอบ \"\(Library.playlist(of: d).isEmpty ? Library.rootLabel : Library.playlist(of: d))\"",
                       bg: Palette.tintCyan,
                       fg: Palette.cyanOnTint, border: Palette.tintCyanLine) {
                model.copyConfig(from: d)
            }
        }

        wideButton("▶ Test Intro (ฟังช่วงโจทย์)", bg: Palette.purple, fg: .white, border: .clear) {
            model.player.testIntro(config: model.config())
        }

        Button {
            model.updateConfig { $0.ignoreEnd.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: c.ignoreEnd ? "checkmark.square.fill" : "square")
                    .foregroundStyle(c.ignoreEnd ? Palette.amberOnTint : Palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ignore Intro End").font(Typo.font(13))
                    Text("เล่นเลยจุดจบ ไม่หยุดอัตโนมัติ").font(Typo.font(11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("E").font(Typo.font(11)).foregroundStyle(Palette.muted)
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(Palette.text)
        .background(c.ignoreEnd ? Palette.tintWarn : Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.ignoreEnd ? Palette.amber : Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .pulseTarget(PulseID.ignoreEnd)

        ForEach(Array(Markers.all.enumerated()), id: \.offset) { _, m in
            markerBlock(m, c)
        }

        loudnessBlock(c)

        Text("เล่นเพลงฟัง พอถึงจุด กดปุ่ม Mark หรือคีย์ I / O / H ได้เลยขณะเล่น · พิมพ์เวลาลงช่องได้ตรงๆ (1:23.45 หรือ 83.45) · Shift+←/→ ขยับ marker ที่เลือกทีละ 0.01s, M สลับ marker · บนคลื่นเสียง: คลิก = เลื่อนหัวเล่น, กดเส้นสีให้ขึ้นก่อน แล้วลากถึงจะขยับ, ลากที่ว่าง = เลื่อนดู · หมุนล้อ = ซูม · แถบล่างสุด = ทั้งเพลง ลากเพื่อเลื่อนช่วงที่ดู · Space เล่นต่อจากตรงที่ค้างอยู่ ถ้าจะกลับต้น Intro กด S")
            .font(Typo.font(11)).foregroundStyle(Palette.muted)
            .padding(.top, 4)
    }

    private func markerBlock(_ m: Markers, _ c: SongConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(m.color).frame(width: 12, height: 12)
                Text(m.label).font(Typo.font(13, .semibold))
                Spacer()
                if let f = m.field, let p = model.current {
                    // `.id(p)` so the field's @State and focus reset with the song rather than
                    // carrying one song's half-typed text into the next.
                    MarkerTimeField(field: f, value: c[keyPath: m.key], path: p).id(p)
                } else {
                    Text(fmtSec(c[keyPath: m.key])).font(Typo.font(15, mono: true))
                }
                // The revert sits next to the VALUE, not in the nudge row below — a "put it
                // back" button beside the fine-tune buttons is a mis-press waiting to happen.
                if let f = m.field, c.onsiteEdits.contains(f) {
                    Button { model.revert(f) } label: {
                        Text("↺").font(Typo.font(15))
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(corner: 6))
                    .foregroundStyle(Palette.amber)
                    .help("คืนค่าที่คนเซ็ตส่งมา")
                }
            }
            if let f = m.field, let b = c.base, c.onsiteEdits.contains(f) {
                HStack(spacing: 6) {
                    Text("✎ แก้ที่กอง").font(Typo.font(10, .semibold))
                        .foregroundStyle(Palette.amber)
                    Text("เดิม \(f.text(b))")
                        .font(Typo.font(10, mono: true))
                        .foregroundStyle(Palette.muted)
                }
            }
            HStack(spacing: 8) {
                nudge("−") {
                    if let f = m.field { model.focus(f) }
                    model.updateConfig { $0[keyPath: m.key] = max(0, (($0[keyPath: m.key] - 0.1) * 100).rounded() / 100) }
                }
                nudge("+") {
                    if let f = m.field { model.focus(f) }
                    model.updateConfig { $0[keyPath: m.key] = (($0[keyPath: m.key] + 0.1) * 100).rounded() / 100 }
                }
                if m.key == \SongConfig.introStart {
                    Button {
                        guard let p = model.current, let a = model.analysis else { return }
                        // All three markers, not just the start. The hook is the step the
                        // pre-flight found was being skipped in practice (§8e: 8 of 9 songs
                        // still sat on the 60 s default), so the button that offers to guess
                        // has to offer to guess THAT.
                        //
                        // Which also makes it destructive on a song somebody has already
                        // reviewed — three signed-off markers, from a 38 pt button sitting 8 pt
                        // from the `−`/`+` nudges. Ask first in that case only; on an
                        // unreviewed song it is pure help and a dialog would be friction.
                        let run = {
                            if !model.applyAutoStart(p, analysis: a, manual: true) {
                                // One flash per press: a second `flash` in the same main-actor
                                // turn replaces the first before it renders a frame, so this
                                // message used to be impossible to see.
                                model.flash("หาจุดเริ่มไม่เจอ — เพลงนี้อาจดังตั้งแต่วินาทีแรก")
                            } else {
                                model.flash("กำลังหา Intro End กับ Hook… (ไม่กี่วินาที)")
                            }
                            model.guessRest(p, duration: a.duration, manual: true)
                        }
                        if !c.isConfigured
                            || confirmDestructive(
                                title: "ให้โปรแกรมเดาใหม่ทั้ง 3 จุด?",
                                body: "เพลงนี้ตั้งค่าไว้แล้ว — Intro Start / Intro End / Hook "
                                    + "จะถูกเขียนทับด้วยค่าที่โปรแกรมเดา (กด Cmd+Z ย้อนได้)",
                                ok: "เดาใหม่") {
                            run()
                        }
                    } label: { Text("🎯").frame(width: 38, height: 38).contentShape(Rectangle()) }
                    .buttonStyle(PressStyle())
                    .background(Palette.tintCyan)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.tintCyanLine)
                        .allowsHitTesting(false))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .help("เดาให้ทั้ง Intro Start / Intro End / Hook — แล้วค่อยปรับเอง")
                }
                Button {
                    if let f = m.field { model.requestMark(f) } else { model.mark(m.key) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Mark ตรงนี้").font(Typo.font(13, .semibold))
                        Text(m.hot).font(Typo.font(11, latinOnly: true)).opacity(0.78)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(Palette.ink)
                .background(m.color).clipShape(RoundedRectangle(cornerRadius: 7))
                .pulseTarget(PulseID.mark(m.label), corner: 7)
            }
            if m.key == \SongConfig.introStart && c.auto {
                Text("🎯 ตั้งให้อัตโนมัติ — ปรับเองได้ตามใจ")
                    .font(Typo.font(10)).foregroundStyle(Palette.cyan)
            }
            // Reserved height, always present. Showing it only on the focused card moved the two
            // cards below it by ~14pt under the cursor every time focus changed — the same family
            // as the transport buttons that used to slide when playback started (§12).
            Text(m.field == model.focusMarker ? "Shift+←/→ ขยับทีละ 0.01s · M สลับไปตัวอื่น" : " ")
                .font(Typo.font(10)).foregroundStyle(Palette.muted)
                .frame(height: 14, alignment: .leading)
        }
        .padding(12)
        .background(Palette.panel2)
        // The focused card is where Shift+←/→ lands. Carried by the border, which is otherwise
        // uniform across all three cards, so the difference is unmissable without a new colour.
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(m.field == model.focusMarker ? Palette.lineStrong : Palette.line,
                    lineWidth: m.field == model.focusMarker ? 2 : 1)
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let f = m.field else { return }
            model.focus(f)
            // Also drop the caret. Without this, clicking card B's background while card A's text
            // field held focus drew the focus ring on B, left A's cyan caret border lit, and sent
            // Shift+→ to A as a text selection — three disagreeing claims about where focus was.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func loudnessBlock(_ c: SongConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.levelBar)
                    .frame(width: 12, height: 12)
                Text("Loudness").font(Typo.font(13, .semibold))
                Spacer()
                Text(String(format: "%@%.1f dB", model.store.normalize ? "auto " : "", model.player.gainDb))
                    .font(Typo.font(15, mono: true))
            }
            Toggle(isOn: Binding(
                get: { model.store.normalize },
                set: { model.store.normalize = $0; model.store.settingsChanged(); model.refreshGain() })) {
                Text("เกลี่ยความดังอัตโนมัติ (ทุกเพลง)").font(Typo.font(13))
            }
            .toggleStyle(.checkbox)

            levelBar(c)
            if clampPinned(c) {
                Text("เกลี่ยชนเพดาน ±12 dB แล้ว — เพลงนี้ยังไม่ดังเท่าเป้า ต้องช่วยด้วย Trim")
                    .font(Typo.font(10)).foregroundStyle(Palette.amber)
            }
            // The gain is NOT capped at the headroom — a brief transient meeting the brick wall
            // is what a limiter is for. But past a few dB the limiter is working continuously,
            // the song does not reach the level the number above claims, and it comes out
            // squashed. Measured on the real library: two of nine intros, one of them by
            // 11.5 dB, and nothing anywhere said so.
            if model.limiterEats > 1.0 {
                Text(String(format: "⚠ หัวเพลงชนเพดาน — ลิมิตเตอร์จะกินคืน %.1f dB "
                            + "เสียงจะไม่ดังเท่าตัวเลขข้างบน และจะโดนบี้\n"
                            + "ช่วงอินโทรนี้อาจมีเสียงแหลมโดดอยู่ ลองขยับ Intro Start/End เลี่ยงมัน",
                            model.limiterEats))
                    .font(Typo.font(10)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text("วัดความดังจาก").font(Typo.font(12)).foregroundStyle(Palette.muted)
                scopeButton("ช่วง Intro", .intro)
                scopeButton("ทั้งเพลง", .song)
            }
            Text(model.scopeNote).font(Typo.font(10)).foregroundStyle(Palette.muted)

            HStack(spacing: 8) {
                Text("Trim เพลงนี้").font(Typo.font(12)).foregroundStyle(Palette.muted).fixedSize()
                // `step:` rather than rounding inside the setter — quantising in the setter while
                // the slider kept its own continuous value made the thumb fight the drag.
                Slider(value: Binding(
                    get: { c.trimDb },
                    set: { v in
                        model.updateConfigQuiet { $0.trimDb = v }
                        model.refreshGain()
                    }), in: -12...12, step: 0.5)
                Text(String(format: "%@%.1f dB", c.trimDb > 0 ? "+" : "", c.trimDb))
                    .font(Typo.font(12, mono: true)).frame(width: 58, alignment: .trailing)
                Button {
                    model.updateConfigQuiet { $0.trimDb = 0 }; model.refreshGain()
                } label: { Text("0").frame(width: 30, height: 26).contentShape(Rectangle()) }
                .buttonStyle(PressStyle())
                .background(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help("กลับเป็น 0 dB")
            }
        }
        .padding(12)
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Is the auto-levelling pinned at its clamp? `applyGain` limits the automatic part to
    /// 0.25x..4.0x, i.e. ±12.04 dB.
    private func clampPinned(_ c: SongConfig) -> Bool {
        model.store.normalize && abs(model.player.gainDb - c.trimDb) >= 11.9
    }

    /// The gain as a position between the clamps, not only a number.
    ///
    /// "+12.0 dB" does not tell you that the auto-levelling wanted MORE and was cut off there —
    /// and that is the one case where the song still goes out quiet and a manual Trim is the only
    /// remedy. The white tick is the automatic part alone, so the gap between it and the end of
    /// the fill IS the trim: how much of the level is a human decision reads off the bar.
    private func levelBar(_ c: SongConfig) -> some View {
        let total = model.player.gainDb
        let auto = total - c.trimDb
        let pinned = clampPinned(c)
        return HStack(spacing: 7) {
            Text("−12").font(Typo.font(10, latinOnly: true)).foregroundStyle(Palette.dim)
            Canvas { ctx, size in
                let w = size.width, h = size.height
                func gx(_ db: Double) -> CGFloat { CGFloat((min(12, max(-12, db)) + 12) / 24) * w }
                let mid = gx(0)
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: h / 2 - 3, width: w, height: 6),
                              cornerRadius: 3), with: .color(Palette.panel))
                let tx = gx(total)
                ctx.fill(Path(roundedRect: CGRect(x: min(mid, tx), y: h / 2 - 3,
                                                  width: max(2, abs(tx - mid)), height: 6),
                              cornerRadius: 3),
                         with: .color(pinned ? Palette.amber : Palette.accent))
                ctx.fill(Path(CGRect(x: mid - 0.5, y: 0, width: 1, height: h)),
                         with: .color(Palette.lineStrong))
                if model.store.normalize {
                    let ax = gx(auto)
                    ctx.fill(Path(CGRect(x: ax - 1, y: 1, width: 2, height: h - 2)),
                             with: .color(Palette.onWave.opacity(0.85)))
                }
            }
            .frame(height: 16)
            .help("แถบ = ความดังรวม · ขีดขาว = ส่วนที่เกลี่ยอัตโนมัติ · ส่วนต่าง = Trim ที่ตั้งเอง")
            Text("+12").font(Typo.font(10, latinOnly: true)).foregroundStyle(Palette.dim)
        }
    }

    private func scopeButton(_ t: String, _ s: LoudnessScope) -> some View {
        let on = model.store.loudnessScope == s
        return Button {
            model.store.loudnessScope = s; model.store.settingsChanged(); model.refreshGain()
        } label: {
            Text(t).font(Typo.font(11, on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.cyanOnTint : Palette.text)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(on ? Palette.cyan : Palette.muted)
        .background(on ? Palette.tintCyan : Palette.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Palette.cyan : Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func nudge(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(16)).frame(width: 38, height: 38).contentShape(Rectangle())
        }
            .buttonStyle(PressStyle()).foregroundStyle(Palette.text)
            .background(Palette.panel)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func wideButton(_ t: String, bg: Color, fg: Color, border: Color,
                            _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(13, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(fg).background(bg)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(border))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Typed `mm:ss.hh` entry for one marker — the precision a drag cannot give you at a zoom level
/// where you can still see the song, and the only way to copy a time off a reference.
///
/// The text is LOCAL state, committed on Return or on losing focus, never per keystroke. Bound
/// straight to the model it would push an undo snapshot per character and write a half-typed
/// number — and since `updateConfig` clamps Intro End to at least `introStart + minIntro`, the
/// lone "1" on the way to "1:20" would drag the other marker along with it.
struct MarkerTimeField: View {
    @EnvironmentObject var model: AppModel
    let field: MarkerField
    let value: Double
    /// The song this field was built for. Checked again at commit time — see `commit()`.
    let path: String

    @State private var text = ""
    /// The last text written here programmatically. `dirty` is the difference between the two, so
    /// "has the operator typed something" is **derived, never stored** — the same reasoning as
    /// `onsiteEdits` deriving from `base` instead of a flag (§8e): a flag can go out of sync and
    /// this one going out of sync writes a wrong marker.
    @State private var synced = ""
    @FocusState private var focused: Bool

    /// Unsaved keystrokes are in this field.
    private var dirty: Bool { text != synced }

    private func sync(_ v: Double) { let s = fmtClock(v); text = s; synced = s }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Typo.font(15, mono: true))
            .multilineTextAlignment(.trailing)
            .frame(width: 88)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(focused ? Palette.panel : Palette.panel3)
            // Amber while there are uncommitted keystrokes — the field is showing something the
            // song does not have. Only Return commits it, so this state has to be visible.
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(dirty ? Palette.amber : (focused ? Palette.cyan : Palette.line),
                        lineWidth: dirty ? 2 : 1)
                .allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focused($focused)
            .onSubmit { commit(); focused = false }
            .onAppear { sync(value) }
            // An UNTYPED field must keep tracking the waveform drag, the ± buttons, an undo and
            // an import — whether or not it happens to hold focus. This used to be gated on
            // `!focused`, which meant merely clicking into a field froze its display and the
            // blur then wrote the frozen value back, silently reverting the drag.
            .onChange(of: value) { v in if !dirty { sync(v) } }
            // **Return commits; losing focus CANCELS.** Committing on blur looked friendlier and
            // was three separate ways to destroy a signed-off marker: `Esc` belongs to the text
            // view, so it ended editing and the blur then committed the typo it was meant to
            // discard; a `1` on the way to `1:20` followed by a stray click wrote a 1-second
            // intro; and clicking a field merely to READ the exact time wrote it straight back,
            // which stamps `configured` and drops the song out of the review sweep (§11) and out
            // of the pre-flight warnings. Snapping back is visible; a silent write is not.
            .onChange(of: focused) { f in if f { model.focus(field) } else { sync(value) } }
            .help("พิมพ์ 1:23.45 หรือ 83.45 แล้ว **กด Enter** · คลิกออกหรือกด Esc = ยกเลิก")
    }

    private func commit() {
        // Nothing typed, nothing to write. Without this, clicking into a field and clicking away
        // re-wrote the marker — and `updateConfig` sets `configured`, which drops the song out of
        // the `Tab`/`Return` review sweep and out of the pre-flight warnings. A wrong value could
        // get through the handover check having never been looked at.
        guard dirty else { sync(value); return }
        // The selection can move while this field holds focus: clicking a song row is a SwiftUI
        // tap gesture and does not take first responder away. Writing then would put THIS song's
        // text onto whatever song is now current. `.id(path)` at the call site already rebuilds
        // the field per song; this is the guard that does not depend on remembering to keep it.
        guard model.current == path else { sync(value); return }
        // Reject rather than clamp: a typo leaves the marker exactly where it was, which is the
        // behaviour you want from a field sitting next to a question that is already signed off.
        guard let t = parseClock(text) else { sync(value); return }
        // An unchanged value is not an edit. `updateConfig` stamps `configured`/`auto`, so
        // committing a no-op would still silently mark the song as reviewed.
        guard !SongConfig.same(t, value) else { sync(value); return }
        model.setMarkerTime(field, t)
        if let k = field.timeKey { sync(model.config()[keyPath: k]) }
    }
}
