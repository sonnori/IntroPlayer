import AppKit
import SwiftUI

// MARK: - Export / pre-flight

/// What the setter sees before handing a round over. Its job is to say what is still unfinished
/// BEFORE the folder is copied — the real library had 6 of 9 songs on an auto-guessed intro start
/// and 8 of 9 with the hook untouched, none of which was visible anywhere.
struct HandoverPanel: View {
    @EnvironmentObject var model: AppModel

    private var paths: [String] { model.songsIn(model.currentPlaylist) }
    private var blocking: [PreflightItem] { model.preflight.filter { $0.kind.blocking } }
    private var warnings: [PreflightItem] { model.preflight.filter { !$0.kind.blocking } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("📤 ส่งต่อรอบ \(Library.label(model.currentPlaylist))")
                    .font(Typo.font(14, .bold))
                if model.preflightScanning {
                    Text("กำลังตรวจเสียง…").font(Typo.font(11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { model.showHandover = false } label: {
                    Text("✕").font(Typo.font(16)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle()).foregroundStyle(Palette.muted)
            }
            .padding(14)
            Divider().overlay(Palette.line)

            HStack(spacing: 10) {
                tile("\(paths.filter { !model.needsReview($0) }.count)", "ยืนยันแล้ว", Palette.green)
                tile("\(paths.filter { model.needsReview($0) }.count)", "ยังต้องตรวจ", Palette.cyan)
                tile("\(blocking.count)", "ต้องแก้ก่อนส่ง", Palette.red)
                tile("\(warnings.count)", "ควรดู", Palette.amber)
            }
            .padding(14)
            Divider().overlay(Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.preflight.isEmpty && !model.preflightScanning {
                        VStack(spacing: 6) {
                            Text("ตรวจแล้วไม่พบปัญหา ✓").font(Typo.font(14))
                                .foregroundStyle(Palette.green)
                            Text("รอบนี้พร้อมส่งต่อ").font(Typo.font(11))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    if !blocking.isEmpty {
                        section("⚠ ต้องแก้ก่อนส่ง", Palette.red)
                        ForEach(blocking) { row($0, Palette.red) }
                    }
                    if !warnings.isEmpty {
                        section("△ ควรดู", Palette.amber)
                        ForEach(warnings) { row($0, Palette.amber) }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }

            Divider().overlay(Palette.line)
            HStack(spacing: 10) {
                Text("ชื่อคนเซ็ต").font(Typo.font(11)).foregroundStyle(Palette.muted)
                TextField("", text: $model.setterName)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .font(Typo.font(12))
                Spacer()
                Text("จะเขียน \(RoundPackage.fileName) ลงในโฟลเดอร์ของรอบนี้")
                    .font(Typo.font(11)).foregroundStyle(Palette.muted)
                Button {
                    // Never block the handover — a round with outstanding warnings is sometimes
                    // exactly what has to go out. Just make the operator say so out loud.
                    if !blocking.isEmpty {
                        guard confirmDestructive(
                            title: "ยังมี \(blocking.count) ข้อที่ต้องแก้",
                            body: "ส่งต่อตอนนี้คนรันจะได้โจทย์ที่ยังไม่พร้อม \(blocking.count) ข้อ",
                            ok: "ส่งต่อทั้งที่ยังไม่ครบ") else { return }
                    }
                    let msg = model.doExport()
                    model.showHandover = false
                    model.flash(msg)
                } label: {
                    Text(blocking.isEmpty ? "📤 ส่งต่อรอบนี้" : "ส่งต่อทั้งที่ยังไม่ครบ")
                        .font(Typo.font(12, .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .background(blocking.isEmpty ? Palette.green.opacity(0.22) : Palette.amber.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Palette.text)
            }
            .padding(14)
        }
        .frame(width: 820, height: 620)
        .background(Palette.float)
        .foregroundStyle(Palette.text)
    }

    private func section(_ t: String, _ c: Color) -> some View {
        Text(t).font(Typo.font(12, .bold)).foregroundStyle(c)
            .padding(.top, 14).padding(.bottom, 6)
    }

    /// The row IS the fix: clicking it selects that song and closes the sheet, so the setter
    /// never has to close, hunt and reopen once per warning.
    private func row(_ it: PreflightItem, _ c: Color) -> some View {
        Button {
            model.select(it.path)
            model.showHandover = false
        } label: {
            HStack(spacing: 10) {
                Text(it.kind.label).font(Typo.font(11, .semibold))
                    .foregroundStyle(c).frame(width: 150, alignment: .leading)
                Text(it.detail).font(Typo.font(12)).foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer()
                Text("ไปแก้ ↩").font(Typo.font(11)).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 6))
    }

    private func tile(_ n: String, _ label: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(n).font(Typo.font(22, .bold)).foregroundStyle(c)
            Text(label).font(Typo.font(11)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Palette.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Import / accept

/// One row per changed FIELD, not per song — accepting a whole song would hide which value moved.
/// Comparison is incoming-vs-local, so it stays correct when both sides edited since the handover.
struct DiffPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let plan = model.importPlan
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("📥 รับการแก้ไข").font(Typo.font(14, .bold))
                if let p = plan {
                    Text("จาก \(p.package.by.isEmpty ? "ไม่ระบุชื่อ" : p.package.by)")
                        .font(Typo.font(11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { model.importPlan = nil } label: {
                    Text("✕").font(Typo.font(16)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle()).foregroundStyle(Palette.muted)
            }
            .padding(14)
            Divider().overlay(Palette.line)

            if let p = plan {
                HStack(spacing: 14) {
                    Text("เพลงใหม่ \(p.fresh.count)").font(Typo.font(11))
                        .foregroundStyle(Palette.green)
                    Text("ค่าต่างกัน \(p.rows.count) จุด").font(Typo.font(11))
                        .foregroundStyle(Palette.amber)
                    Text("เหมือนกัน \(p.unchanged.count)").font(Typo.font(11))
                        .foregroundStyle(Palette.muted)
                    if !p.orphans.isEmpty {
                        Text("ไม่มีไฟล์ \(p.orphans.count)").font(Typo.font(11))
                            .foregroundStyle(Palette.red)
                    }
                    Spacer()
                    Button { model.acceptedRows = Set(p.rows.map(\.id)) } label: {
                        Text("รับทั้งหมด").font(Typo.font(11)).contentShape(Rectangle())
                    }.buttonStyle(PressStyle(corner: 6)).foregroundStyle(Palette.muted)
                    Button { model.acceptedRows = [] } label: {
                        Text("ไม่รับเลย").font(Typo.font(11)).contentShape(Rectangle())
                    }.buttonStyle(PressStyle(corner: 6)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider().overlay(Palette.line)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(p.rows) { r in diffRow(r) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }

            Divider().overlay(Palette.line)
            HStack {
                Text("ที่ไม่ติ๊กจะคงค่าเดิมของเครื่องนี้ไว้ · ไม่แตะสถานะ \"เล่นแล้ว\" และ log")
                    .font(Typo.font(11)).foregroundStyle(Palette.muted)
                Spacer()
                Button { model.applyImport() } label: {
                    Text("รับ \(model.acceptedRows.count) รายการ")
                        .font(Typo.font(12, .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .background(Palette.green.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Palette.text)
            }
            .padding(14)
        }
        .frame(width: 900, height: 620)
        .background(Palette.float)
        .foregroundStyle(Palette.text)
    }

    private func diffRow(_ r: DiffRow) -> some View {
        let on = model.acceptedRows.contains(r.id)
        return Button {
            if on { model.acceptedRows.remove(r.id) } else { model.acceptedRows.insert(r.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(on ? "☑" : "☐").font(Typo.font(14))
                        .foregroundStyle(on ? Palette.green : Palette.muted)
                    Text(Library.title(r.path)).font(Typo.font(12))
                        .frame(width: 260, alignment: .leading).lineLimit(1)
                    Text(r.field.label).font(Typo.font(11, .semibold))
                        .foregroundStyle(Palette.cyan).frame(width: 110, alignment: .leading)
                    if !r.field.isProse {
                        Text(r.mine).font(Typo.font(12, mono: true))
                            .foregroundStyle(Palette.muted)
                        Text("→").font(Typo.font(11)).foregroundStyle(Palette.muted)
                        Text(r.theirs).font(Typo.font(12, .semibold, mono: true))
                            .foregroundStyle(on ? Palette.text : Palette.muted)
                    }
                    Spacer()
                }
                // A note is a sentence and a tag list is a list, not a number. Side by side in
                // a ~160 pt column the setter can read neither value, and reading BOTH is the
                // entire decision this row exists for — so they wrap onto their own lines.
                if r.field.isProse {
                    noteValue("ของเครื่องนี้", r.mine.isEmpty ? "— ไม่มี —" : r.mine,
                              r.mine.isEmpty ? Palette.dim : Palette.muted)
                    // For tags `theirs` is the RESULT of accepting — the union — not the
                    // sender's list, so the label must not claim it is what they sent.
                    noteValue(r.field == .tags ? "รับแล้วจะเป็น" : "ที่รับมา",
                              r.theirs, on ? Palette.text : Palette.muted)
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Palette.panel2 : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 6))
    }

    private func noteValue(_ label: String, _ text: String, _ fg: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(Typo.font(11)).foregroundStyle(Palette.dim)
                .frame(width: 92, alignment: .trailing)
            Text(text).font(Typo.font(12)).foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, 32)
    }
}

// MARK: - Receive banner

/// A persistent strip, not a toast: the operator may not be looking when a 2.4 s message fires,
/// and this is the one thing they must check before rolling camera.
struct ReceiveBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let pkg = model.incoming, !model.incomingDismissed {
            HStack(spacing: 12) {
                Text("📥").font(Typo.font(14))
                Text("รอบ \(Library.label(pkg.round))")
                    .font(Typo.font(13, .bold))
                Text("ตั้งโดย \(pkg.by.isEmpty ? "ไม่ระบุชื่อ" : pkg.by)")
                    .font(Typo.font(12)).foregroundStyle(Palette.text.opacity(0.85))
                Text("· \(pkg.songs.count) เพลง").font(Typo.font(12))
                    .foregroundStyle(Palette.text.opacity(0.85))
                if !pkg.at.isEmpty {
                    Text("· \(LogStore.clockText(pkg.at))").font(Typo.font(11))
                        .foregroundStyle(Palette.text.opacity(0.6))
                }
                Spacer()
                Button { model.openImport() } label: {
                    Text("ดูและรับโจทย์").font(Typo.font(12, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 7))
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                Button { model.incomingDismissed = true } label: {
                    Text("ไว้ก่อน").font(Typo.font(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 7))
                .foregroundStyle(Palette.text.opacity(0.7))
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Palette.cyan.opacity(0.18))
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.cyan).frame(width: 3).allowsHitTesting(false)
            }
            .foregroundStyle(Palette.text)
        }
    }
}
