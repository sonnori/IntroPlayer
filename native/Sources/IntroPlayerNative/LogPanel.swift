import AppKit
import SwiftUI

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    private var shown: [LogEvent] {
        model.logStore.events.filter { model.logAllRounds || $0.playlist == model.currentPlaylist }
    }
    private var currentSession: [LogEvent] { shown.filter(model.isCurrentSession) }
    private var olderCount: Int { shown.count - currentSession.count }

    /// One row per song, decided by its outcome — what the edit team actually needs.
    private struct Summary { var path: String; var correct: Bool; var wrongs: Int; var last: String }
    private func summarise(_ evs: [LogEvent]) -> [Summary] {
        var order: [String] = []
        var map: [String: Summary] = [:]
        for e in evs {
            if map[e.path] == nil { order.append(e.path); map[e.path] = Summary(path: e.path, correct: false, wrongs: 0, last: e.t) }
            if e.isCorrect { map[e.path]!.correct = true } else { map[e.path]!.wrongs += 1 }
            map[e.path]!.last = e.t
        }
        return order.compactMap { map[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("📋 บันทึกการถ่ายทำ").font(Typo.font(14, .bold))
                Text(scopeLabel).font(Typo.font(12)).foregroundStyle(Palette.muted)
                Spacer()
                Toggle(isOn: $model.logAllRounds) { Text("ดูทุกรอบ").font(Typo.font(12)) }
                    .toggleStyle(.checkbox).foregroundStyle(Palette.muted)
                Button { model.showLog = false } label: {
                    Text("✕").font(Typo.font(16)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(PressStyle()).foregroundStyle(Palette.muted)
            }
            .padding(14)
            Divider().overlay(Palette.line)

            let s = summarise(currentSession)
            HStack(spacing: 10) {
                stat("\(s.filter(\.correct).count)", "มีคนตอบถูก — ใช้ตัดต่อได้", Palette.green)
                stat("\(s.filter { !$0.correct }.count)", "ใช้ในกองแล้ว แต่ไม่มีคนตอบ", Palette.amber)
                stat("\(s.count)", "โจทย์ที่ใช้ไปทั้งหมด", Palette.text)
            }
            .padding(14)
            Divider().overlay(Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        VStack(spacing: 6) {
                            Text("ยังไม่มีบันทึก").font(Typo.font(14))
                            Text("กด Correct หรือ Wrong ระหว่างถ่าย แล้วจะขึ้นตรงนี้")
                                .font(Typo.font(11)).foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    rows
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }

            Divider().overlay(Palette.line)
            HStack(spacing: 8) {
                foot("📄 คัดลอกเป็นข้อความ") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exportText(), forType: .string)
                    model.flash("คัดลอกแล้ว")
                }
                foot("⤓ บันทึก CSV") { saveCSV() }
                Spacer()
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
            .padding(14)
        }
        .frame(width: 760, height: 640)
        .background(Palette.float)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var rows: some View {
        let evs = shown
        // Older takes stay visible under a divider so a reset reads as history, not as a failure
        // to clear. Dimmed, but never deleted — the log is the tape's record.
        let firstCurrentIdx = evs.firstIndex(where: model.isCurrentSession)
        ForEach(Array(evs.enumerated()), id: \.element.id) { i, e in
            if olderCount > 0, let f = firstCurrentIdx, i == f {
                Text("↺ เริ่มถ่ายรอบใหม่ — ด้านบนคือรอบก่อนหน้า")
                    .font(Typo.font(11)).foregroundStyle(Color(red: 0.81, green: 0.88, blue: 1))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color(red: 0.141, green: 0.188, blue: 0.286))
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
                    .background(e.isCorrect ? Color(red: 0.07, green: 0.19, blue: 0.13)
                                            : Color(red: 0.18, green: 0.14, blue: 0.07))
                    .clipShape(Capsule())
            }
            .opacity(model.isCurrentSession(e) ? 1 : 0.42)
            .padding(.vertical, 7)
            Divider().overlay(Color(red: 0.125, green: 0.141, blue: 0.176))
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

    private func exportText() -> String {
        let evs = currentSession
        let s = summarise(evs)
        let ok = s.filter(\.correct), no = s.filter { !$0.correct }
        let head = "บันทึกการถ่ายทำ — " + (model.logAllRounds ? "ทุกรอบ"
            : (model.currentPlaylist.isEmpty ? "รอบที่ยังไม่ได้จัด" : model.currentPlaylist))
        var t = head + "\n" + String(repeating: "=", count: head.count) + "\n\n"
        if olderCount > 0 {
            t += "(เฉพาะรอบถ่ายปัจจุบัน — มีบันทึกของรอบก่อนหน้าอีก \(olderCount) รายการในไฟล์ log)\n\n"
        }
        t += "ใช้ตัดต่อได้ (มีคนตอบถูก) — \(ok.count) เพลง\n"
        for (i, x) in ok.enumerated() {
            t += "  \(i + 1). [\(hhmmss(x.last))] \(Library.title(x.path))"
            if x.wrongs > 0 { t += "  (ตอบผิดก่อน \(x.wrongs) ครั้ง)" }
            t += "\n"
        }
        t += "\nใช้ในกองแล้วแต่ไม่มีคนตอบ — \(no.count) เพลง\n"
        for (i, x) in no.enumerated() {
            t += "  \(i + 1). [\(hhmmss(x.last))] \(Library.title(x.path))  (ตอบผิด \(x.wrongs) ครั้ง)\n"
        }
        t += "\n--- ลำดับจริงตามเวลา ---\n"
        for e in evs { t += "\(hhmmss(e.t))  \(e.isCorrect ? "ถูก" : "ผิด")  \(Library.title(e.path))\n" }
        return t
    }

    private func saveCSV() {
        // every event, with which taping each belongs to; BOM so Excel reads Thai correctly
        var rows = [["เวลา", "รอบ", "เพลง", "ผล", "รอบถ่าย"]]
        for e in shown {
            rows.append([e.t, e.playlist, Library.title(e.path),
                         e.isCorrect ? "ตอบถูก" : "ตอบผิด",
                         model.isCurrentSession(e) ? "ปัจจุบัน" : "ก่อนหน้า"])
        }
        let csv = "\u{FEFF}" + rows.map { r in
            r.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n")

        let p = NSSavePanel()
        p.nameFieldStringValue = "introplayer-log-\(model.currentPlaylist.isEmpty ? "all" : model.currentPlaylist).csv"
        p.allowedContentTypes = [.commaSeparatedText]
        if p.runModal() == .OK, let url = p.url {
            try? csv.data(using: .utf8)?.write(to: url)
            model.flash("บันทึก CSV แล้ว")
        }
    }
}
