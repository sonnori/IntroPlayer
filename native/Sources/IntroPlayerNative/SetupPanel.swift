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
                   bg: c.played ? Color(red: 0.165, green: 0.141, blue: 0.094) : Palette.panel2,
                   fg: c.played ? Palette.amber : Palette.text,
                   border: c.played ? Palette.amber : Palette.line) {
            model.updateConfigQuiet { $0.played.toggle() }
        }

        if let d = model.current.flatMap({ model.donor(for: $0) }), !c.isConfigured {
            wideButton("⤵ ดึงค่าจากรอบ \"\(Library.playlist(of: d).isEmpty ? Library.rootLabel : Library.playlist(of: d))\"",
                       bg: Color(red: 0.071, green: 0.188, blue: 0.251),
                       fg: Palette.cyan, border: Color(red: 0.165, green: 0.42, blue: 0.502)) {
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
                    .foregroundStyle(c.ignoreEnd ? Palette.amber : Palette.muted)
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
        .background(c.ignoreEnd ? Color(red: 0.165, green: 0.141, blue: 0.094) : Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.ignoreEnd ? Palette.amber : Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .pulseTarget(PulseID.ignoreEnd)

        ForEach(Array(Markers.all.enumerated()), id: \.offset) { _, m in
            markerBlock(m, c)
        }

        loudnessBlock(c)

        Text("เล่นเพลงฟัง พอถึงจุด กดปุ่ม Mark หรือคีย์ I / O / H ได้เลยขณะเล่น · บนคลื่นเสียง: คลิก = เลื่อนหัวเล่น, ลากเส้นสี = ปรับ marker, ลากที่ว่าง = เลื่อนดู · หมุนล้อ = ซูม · Space เล่นต่อจากตรงที่ค้างอยู่ ถ้าจะกลับต้น Intro กด S")
            .font(Typo.font(11)).foregroundStyle(Palette.muted)
            .padding(.top, 4)
    }

    private func markerBlock(_ m: Markers, _ c: SongConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(m.color).frame(width: 12, height: 12)
                Text(m.label).font(Typo.font(13, .semibold))
                Spacer()
                Text(fmtSec(c[keyPath: m.key])).font(Typo.font(15, mono: true))
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
                nudge("−") { model.updateConfig { $0[keyPath: m.key] = max(0, (($0[keyPath: m.key] - 0.1) * 100).rounded() / 100) } }
                nudge("+") { model.updateConfig { $0[keyPath: m.key] = (($0[keyPath: m.key] + 0.1) * 100).rounded() / 100 } }
                if m.key == \SongConfig.introStart {
                    Button {
                        guard let p = model.current, let a = model.analysis else { return }
                        if !model.applyAutoStart(p, analysis: a, manual: true) {
                            model.flash("หาจุดเริ่มไม่เจอ — เพลงนี้อาจดังตั้งแต่วินาทีแรก")
                        }
                    } label: { Text("🎯").frame(width: 38, height: 38).contentShape(Rectangle()) }
                    .buttonStyle(PressStyle())
                    .background(Color(red: 0.071, green: 0.188, blue: 0.251))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 0.165, green: 0.42, blue: 0.502)))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .help("หาจุดที่เพลงเริ่มดังให้อัตโนมัติ แล้วเลื่อนทั้งช่วง Intro ตามไป")
                }
                Button {
                    if let f = m.field { model.requestMark(f) } else { model.mark(m.key) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Mark ตรงนี้").font(Typo.font(13, .semibold))
                        Text(m.hot).font(Typo.font(11)).opacity(0.6)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(Color(red: 0.05, green: 0.05, blue: 0.05))
                .background(m.color).clipShape(RoundedRectangle(cornerRadius: 7))
                .pulseTarget(PulseID.mark(m.label), corner: 7)
            }
            if m.key == \SongConfig.introStart && c.auto {
                Text("🎯 ตั้งให้อัตโนมัติ — ปรับเองได้ตามใจ")
                    .font(Typo.font(10)).foregroundStyle(Palette.cyan)
            }
        }
        .padding(12)
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func loudnessBlock(_ c: SongConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.357, green: 0.839, blue: 1))
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

    private func scopeButton(_ t: String, _ s: LoudnessScope) -> some View {
        let on = model.store.loudnessScope == s
        return Button {
            model.store.loudnessScope = s; model.store.settingsChanged(); model.refreshGain()
        } label: {
            Text(t).font(.system(size: 11, weight: on ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(on ? Palette.cyan : Palette.muted)
        .background(on ? Color(red: 0.071, green: 0.188, blue: 0.251) : Palette.panel)
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
