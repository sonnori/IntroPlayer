import AppKit
import SwiftUI

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    private var shown: [LogEvent] {
        model.logStore.events.filter { model.logAllRounds || $0.playlist == model.currentPlaylist }
    }
    private var currentSession: [LogEvent] { shown.filter(model.isCurrentSession) }
    private var olderCount: Int { shown.count - currentSession.count }

    /// The current taping's running order, numbered from 1. Past takes get their own numbering
    /// so the current round always starts at 1 — that is the number people say out loud.
    /// From the model's cache, not rebuilt here: this pane re-renders at the player's tick rate
    /// while audio is running, and `body` reaches for the running order several times per pass.
    /// `AppModel.invalidateStatus()` drops it on every log write, reset and round switch.
    private var takes: [Take] { model.takes() }
    /// Not cached — only a count and the CSV need it, and both are user-initiated.
    private var pastTakes: [Take] { Takes.build(shown.filter { !model.isCurrentSession($0) }) }

    private var sittings: [[Take]] { Takes.sittings(takes) }

    /// Seconds from the first take of ITS OWN sitting, for lining up against a camera timecode
    /// that was reset when the camera was. Measured from the whole session's first take, this
    /// read `+2230:24:30` on the real log, where "one session" spans months.
    private func elapsed(_ t: Take, in sitting: [Take]) -> Double? {
        guard let s = t.start, let first = sitting.first?.start else { return nil }
        return s.timeIntervalSince(first)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane header, not a sheet title bar: it must read as "the song list has been
            // swapped out", because the pane it replaces is where the eye expects the list.
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text("📋 บันทึกการถ่ายทำ").font(Typo.font(14, .bold))
                    Spacer()
                    Button { model.showLog = false } label: {
                        HStack(spacing: 5) {
                            Text("✕").font(Typo.font(13))
                            Text("ปิด").font(Typo.font(12))
                        }
                        .padding(.horizontal, 9).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(corner: 6)).foregroundStyle(Palette.muted)
                    .background(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line)
                        .allowsHitTesting(false))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help("ปิดแล้วกลับไปดูรายการเพลง (L หรือ Esc)")
                }
                HStack(spacing: 10) {
                    Text(scopeLabel).font(Typo.font(12)).foregroundStyle(Palette.muted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Toggle(isOn: Binding(get: { model.logAllRounds },
                                         set: { model.setLogAllRounds($0) })) {
                        Text("ดูทุกรอบ").font(Typo.font(12))
                    }
                    .toggleStyle(.checkbox).foregroundStyle(Palette.muted).fixedSize()
                }
            }
            .padding(12)
            .background(Palette.panel2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.line).frame(height: 1).allowsHitTesting(false)
            }

            let tk = takes
            VStack(alignment: .leading, spacing: 8) {
                // Three tiles side by side need the wide pane; at 300pt they stack rather than
                // squeeze, because the number has to stay legible across the room.
                Group {
                    if model.isWide {
                        HStack(spacing: 10) { statTiles(tk) }
                    } else {
                        VStack(spacing: 8) { statTiles(tk) }
                    }
                }
                if let sp = Takes.span(tk) {
                    let n = sittings.count
                    Text(n > 1
                         ? "\(n) ช่วงถ่าย · \(LogStore.dayText(sp.first)) – \(LogStore.dayText(sp.last))"
                         : "\(LogStore.dayText(sp.first)) · \(hm(sp.first)) – \(hm(sp.last)) · รวม "
                           + fmtSpanThai(sp.last.timeIntervalSince(sp.first)))
                        .font(Typo.font(11)).foregroundStyle(Palette.muted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    viewButton("ลำดับการถ่าย", .running)
                    viewButton("ทุกเหตุการณ์", .events)
                }
            }
            .padding(12)
            Divider().overlay(Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        VStack(spacing: 6) {
                            Text("ยังไม่มีบันทึก").font(Typo.font(14))
                            Text("กด ✓ Correct หรือ ✗ Wrong ระหว่างถ่าย แล้วจะขึ้นตรงนี้ตามลำดับที่เปิด")
                                .font(Typo.font(11)).foregroundStyle(Palette.muted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    if model.logView == .running { runningRows(tk) } else { rows }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }

            Divider().overlay(Palette.line)
            FlowRow(spacing: 8, lineSpacing: 8) {
                foot("📄 คัดลอกเป็นข้อความ") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exportText(), forType: .string)
                    model.flash("คัดลอกแล้ว")
                }
                foot("⤓ บันทึก CSV") { saveCSV() }
                foot("↩ ยกเลิกรายการล่าสุด", Palette.amber) {
                    if let e = model.logStore.undoLast(playlist: model.logAllRounds ? nil : model.currentPlaylist) {
                        model.flash("ยกเลิก \(Library.title(e.path)) แล้ว")
                    } else { model.flash("ยังไม่มีรายการให้ยกเลิก") }
                    model.invalidateStatus()
                    model.objectWillChange.send()
                }
                foot("🗑 ล้าง log รอบนี้", Palette.red) {
                    let scope = model.logAllRounds ? nil : model.currentPlaylist
                    let count = model.logStore.events.filter { scope == nil || $0.playlist == scope }.count
                    guard count > 0 else { model.flash("ยังไม่มี log ให้ลบ"); return }
                    guard confirmDestructive(
                        title: "ลบ log ทิ้งถาวร?",
                        body: "จะลบ \(count) รายการ"
                            + (scope == nil ? " ของทุกรอบ" : " ของรอบ \(Library.label(model.currentPlaylist))")
                            + " — นี่คือลำดับการถ่ายที่ห้องตัดต่อใช้ และกู้คืนไม่ได้\n\n"
                            + "ถ้าแค่จะเริ่มถ่ายรอบใหม่ ให้กด ↺ รีเซ็ตเล่นแล้ว แทน",
                        ok: "ลบถาวร") else { return }
                    model.logStore.clear(playlist: scope)
                    model.flash("ล้าง log แล้ว")
                    model.invalidateStatus()
                    model.objectWillChange.send()
                }
            }
            .padding(12)
        }
        // Matches the song list it replaces, so the three panes keep their widths and the centre
        // pane does not resize when the log opens mid-taping.
        .frame(width: model.isWide ? 780 : 300)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.line).frame(width: 1).allowsHitTesting(false)
        }
    }

    @ViewBuilder private func statTiles(_ tk: [Take]) -> some View {
        stat("\(tk.count)", "ข้อที่ใช้ไป (ตามลำดับถ่าย)", Palette.text)
        stat("\(tk.filter(\.correct).count)", "มีคนตอบถูก — ใช้ตัดต่อได้", Palette.green)
        stat("\(tk.filter { !$0.correct }.count)", "ใช้ในกองแล้ว แต่ไม่มีคนตอบ", Palette.red)
    }

    private func viewButton(_ t: String, _ v: AppModel.LogView) -> some View {
        let on = model.logView == v
        return Button { model.logView = v } label: {
            Text(t).font(Typo.font(12, on ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 6))
        .foregroundStyle(on ? Palette.text : Palette.muted)
        .background(on ? Palette.panel3 : Palette.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Palette.lineStrong : Palette.line)
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The running order — one row per question, in the order it was opened. This is the view the
    /// log exists for: nothing is ever played in list order, so the number on the left is the only
    /// handle the edit room has on the tape.
    @ViewBuilder private func runningRows(_ tk: [Take]) -> some View {
        if !pastTakes.isEmpty {
            Text("รอบก่อนหน้า \(pastTakes.count) ข้อ — ดูรายละเอียดที่ \"ทุกเหตุการณ์\"")
                .font(Typo.font(10)).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            Divider().overlay(Palette.line)
        }
        if tk.isEmpty && !shown.isEmpty {
            Text("รอบถ่ายนี้ยังไม่มีข้อที่ใช้ — กด ↺ รีเซ็ตเล่นแล้ว ไปแล้วหรือเปล่า")
                .font(Typo.font(11)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
        let groups = sittings
        ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
            // Only label the sitting when there is more than one — a single day's taping should
            // not carry a heading explaining that it is one day.
            if groups.count > 1, let d = g.first?.start {
                HStack(spacing: 8) {
                    Text("\(LogStore.dayText(d))  \(hm(d))")
                        .font(Typo.font(11, .semibold))
                    if let sp = Takes.span(g) {
                        Text("· \(g.count) ข้อ · \(fmtSpanThai(sp.last.timeIntervalSince(sp.first)))")
                            .font(Typo.font(10)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(hex: 0xCFE0FF))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0x24304A))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.top, gi == 0 ? 6 : 12).padding(.bottom, 2)
            }
            ForEach(g) { t in takeRow(t, in: g) }
        }
    }

    private func takeRow(_ t: Take, in sitting: [Take]) -> some View {
        let isCurrent = model.current == t.path
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // The order number, large and tabular: the primary key of this whole view.
                Text("\(t.order)")
                    .font(Typo.font(17, .bold, mono: true, latinOnly: true))
                    .foregroundStyle(t.correct ? Palette.greenText : Palette.red)
                    .frame(width: 26, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Library.displayTitle(t.path))
                        .font(isCurrent ? Typo.bodyEm : Typo.body)
                        .lineLimit(2)
                        .foregroundStyle(isCurrent ? .white : Palette.text)
                    HStack(spacing: 8) {
                        Text(hhmmss(t.startISO))
                            .font(Typo.font(11, mono: true)).foregroundStyle(Palette.muted)
                        if let el = elapsed(t, in: sitting) {
                            Text(fmtElapsed(el))
                                .font(Typo.font(11, mono: true)).foregroundStyle(Palette.dim)
                        }
                        Text(Library.trackNumber(t.path))
                            .font(Typo.font(11, mono: true)).foregroundStyle(Palette.dim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(t.correct ? "✓ ตอบถูก" : "✗ ไม่มีคนตอบ")
                        .font(Typo.font(11, .semibold))
                        .foregroundStyle(t.correct ? Palette.greenText : Palette.red)
                    if t.wrongs > 0 {
                        Text(t.correct ? "ผิดก่อน \(t.wrongs)" : "ผิด \(t.wrongs) ครั้ง")
                            .font(Typo.font(10)).foregroundStyle(Palette.muted)
                    }
                }
                .fixedSize()
            }
            .padding(.vertical, 9).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Color(hex: 0x24304A) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { model.selectFromLog(t.path) }
            .help("คลิกเพื่อเปิดเพลงนี้ (ต้องหยุดเล่นก่อน)")
            Divider().overlay(Palette.hair)
        }
    }

    private func hm(_ d: Date) -> String { LogStore.hmText(d) }

    @ViewBuilder private var rows: some View {
        let evs = shown
        // Older takes stay visible under a divider so a reset reads as history, not as a failure
        // to clear. Dimmed, but never deleted — the log is the tape's record.
        let firstCurrentIdx = evs.firstIndex(where: model.isCurrentSession)
        ForEach(Array(evs.enumerated()), id: \.element.id) { i, e in
            if olderCount > 0, let f = firstCurrentIdx, i == f {
                Text("↺ เริ่มถ่ายรอบใหม่ — ด้านบนคือรอบก่อนหน้า")
                    .font(Typo.font(11)).foregroundStyle(Palette.tintSelectText)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Palette.tintSelect)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.vertical, 8)
            }
            HStack(spacing: 10) {
                Text(hhmmss(e.t)).font(Typo.font(12, mono: true))
                    .foregroundStyle(Palette.muted).frame(width: 64, alignment: .leading)
                Text(Library.title(e.path)).font(Typo.font(13)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.logAllRounds && !e.playlist.isEmpty {
                    Text(e.playlist).font(Typo.font(11)).foregroundStyle(Palette.muted)
                }
                Text(e.isCorrect ? "ตอบถูก" : "ตอบผิด")
                    .font(Typo.font(11, .semibold))
                    .foregroundStyle(e.isCorrect ? Palette.green : Palette.amber)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(e.isCorrect ? Palette.tintGood
                                            : Palette.tintBad)
                    .clipShape(Capsule())
            }
            .opacity(model.isCurrentSession(e) ? 1 : 0.42)
            .padding(.vertical, 7)
            Divider().overlay(Palette.hair)
        }
    }

    private var scopeLabel: String {
        var s = model.logAllRounds ? "ทุกรอบ"
            : (model.currentPlaylist.isEmpty ? "รอบที่ยังไม่ได้จัด" : "รอบ " + model.currentPlaylist)
        if olderCount > 0 { s += " · รอบถ่ายปัจจุบัน" }
        return s
    }

    private func stat(_ n: String, _ label: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(Typo.font(22, .bold, mono: true)).foregroundStyle(c)
            Text(label).font(Typo.font(11)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func foot(_ t: String, _ fg: Color = Palette.text, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(12)).padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(fg)
        .background(Palette.panel2)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func hhmmss(_ iso: String) -> String { LogStore.clockText(iso) }

    /// Running order FIRST. The grouped-by-outcome summary used to lead, which answered a
    /// question nobody asks of this file: the edit room is holding a tape and needs to know what
    /// was shot when. The summary is still here, second, and now cites take numbers so the two
    /// halves point at each other.
    private func exportText() -> String {
        let tk = takes
        let head = "บันทึกการถ่ายทำ — " + (model.logAllRounds ? "ทุกรอบ"
            : (model.currentPlaylist.isEmpty ? "รอบที่ยังไม่ได้จัด" : model.currentPlaylist))
        var t = head + "\n" + String(repeating: "=", count: max(24, head.count)) + "\n"
        if let sp = Takes.span(tk) {
            t += "วันที่ \(LogStore.dayText(sp.first))  ·  เริ่ม \(hm(sp.first))"
            t += "  ·  ล่าสุด \(hm(sp.last))"
            t += "  ·  รวม \(fmtSpanThai(sp.last.timeIntervalSince(sp.first)))\n"
        }
        t += "ใช้ไป \(tk.count) ข้อ  ·  มีคนตอบถูก \(tk.filter(\.correct).count)"
        t += "  ·  ไม่มีคนตอบ \(tk.filter { !$0.correct }.count)\n"
        if !pastTakes.isEmpty {
            t += "(เฉพาะรอบถ่ายปัจจุบัน — ในไฟล์ log ยังมีของรอบก่อนหน้าอีก \(pastTakes.count) ข้อ)\n"
        }

        t += "\n\nลำดับการถ่าย — เรียงตามที่เปิดจริง ไม่ใช่ตามเลขเพลง\n"
        t += String(repeating: "-", count: 46) + "\n"
        let groups = sittings
        for g in groups {
            if groups.count > 1, let d = g.first?.start {
                t += "\n[ \(LogStore.dayText(d))  \(hm(d))  —  \(g.count) ข้อ ]\n"
            }
            t += "  #   เวลา      จากเริ่ม   เพลง\n"
            for x in g {
                let el = elapsed(x, in: g).map(fmtElapsed) ?? "—"
                t += String(format: "%3d.  %@  %-8@  ", x.order, hhmmss(x.startISO) as NSString,
                            el as NSString)
                t += Library.title(x.path)
                t += x.correct ? "   ✓ ตอบถูก" : "   ✗ ไม่มีคนตอบ"
                if x.wrongs > 0 { t += x.correct ? " (ผิดก่อน \(x.wrongs))" : " (ผิด \(x.wrongs) ครั้ง)" }
                t += "\n"
            }
        }

        let ok = tk.filter(\.correct), no = tk.filter { !$0.correct }
        t += "\n\nสรุปตามผล\n" + String(repeating: "-", count: 46) + "\n"
        t += "\nใช้ตัดต่อได้ (มีคนตอบถูก) — \(ok.count) ข้อ\n"
        for x in ok { t += "   ข้อ \(x.order)  [\(hhmmss(x.startISO))]  \(Library.title(x.path))\n" }
        t += "\nใช้ในกองแล้วแต่ไม่มีคนตอบ — \(no.count) ข้อ  ← เผาไปแล้ว ใช้ซ้ำไม่ได้\n"
        for x in no {
            t += "   ข้อ \(x.order)  [\(hhmmss(x.startISO))]  \(Library.title(x.path))"
            t += "  (ผิด \(x.wrongs) ครั้ง)\n"
        }
        return t
    }

    /// One row per TAKE, not per event — the running order is what gets opened in Excel. The raw
    /// per-event stream stays in `log.json` for working out what happened when a row looks odd.
    private func saveCSV() {
        var rows = [["ลำดับที่", "วันที่", "เวลา", "จากเริ่มช่วงนี้", "ช่วงถ่าย",
                     "รอบ", "เลขเพลง", "เพลง", "ผล", "ตอบผิดกี่ครั้ง", "รอบถ่าย"]]
        func add(_ groups: [[Take]], current: Bool) {
            for (gi, g) in groups.enumerated() {
                for x in g {
                    rows.append(["\(x.order)",
                                 x.start.map(LogStore.dayText) ?? "",
                                 hhmmss(x.startISO),
                                 elapsed(x, in: g).map(fmtElapsed) ?? "",
                                 "\(gi + 1)",
                                 x.playlist, Library.trackNumber(x.path), Library.title(x.path),
                                 x.correct ? "ตอบถูก" : "ไม่มีคนตอบ", "\(x.wrongs)",
                                 current ? "ปัจจุบัน" : "ก่อนหน้า"])
                }
            }
        }
        add(Takes.sittings(pastTakes), current: false)
        add(sittings, current: true)

        // BOM so Excel reads Thai; CRLF for the same reason.
        let csv = "\u{FEFF}" + rows.map { r in
            r.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n")

        let p = NSSavePanel()
        p.nameFieldStringValue = "introplayer-ลำดับถ่าย-\(model.currentPlaylist.isEmpty ? "all" : model.currentPlaylist).csv"
        p.allowedContentTypes = [.commaSeparatedText]
        if p.runModal() == .OK, let url = p.url {
            try? csv.data(using: .utf8)?.write(to: url)
            model.flash("บันทึก CSV แล้ว")
        }
    }
}
