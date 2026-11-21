import AppKit
import SwiftUI

/// One strip, one message at a time, most-actionable first.
///
/// This replaces two stacked banners, for three measured reasons:
///
/// - **They co-occurred by construction, not by accident.** If the config was written by a newer
///   build then that build exists, so the feed names it — meaning "มีเวอร์ชั่นใหม่" and
///   "ไฟล์โจทย์มาจากแอปเวอร์ชั่นใหม่กว่า" showed together and said the same thing twice.
/// - **Height.** `CenterView`'s only flexible child is the waveform and it has a hard
///   `minHeight: 160` floor (§12), so content that overruns the window centres and clips BOTH
///   ends — the song title off the top and ✓ Correct / ✗ Wrong off the bottom. Two banners plus
///   `saveFailureBar` plus `ReceiveBanner` is ~226 pt of strip; the production 2560×1080 absorbs
///   it, a laptop at the declared `minHeight: 640` does not.
/// - **Hue.** The update banner is cyan because §6d reserves amber for "the intro-end stop is not
///   armed" — the one state that can put a whole song on camera — and spending amber on software
///   news dilutes exactly the warning that must never be ignored. But the schema notice was then
///   given amber on the *loose* reading of the same rule ("or something is wrong"), at the same
///   0.14 fill, 60 pt from the real thing and stacked against the red save-failure bar that it
///   sits only deutan ΔE 10.6 from — both opening with "⚠". It cannot be both ways. The schema
///   notice loses nothing (its own text says so), is not actionable during a taping, and is true
///   forever once two machines differ, so it does not earn a warning hue at all.
///
/// `ReceiveBanner` stays separate and renders ABOVE this: a round waiting to be accepted is work,
/// and software news must not push it further from the header.
struct NewsBanner: View {
    @EnvironmentObject var model: AppModel

    private enum Item { case wrongFolder, update, justUpdated, schema }

    /// Priority order. Only the first is shown; the rest are a count.
    private var items: [Item] {
        var out: [Item] = []
        if model.launchedFromRelease { out.append(.wrongFolder) }
        if model.updateInstalling || model.showUpdateNotice { out.append(.update) }
        if model.justUpdatedFrom != nil { out.append(.justUpdated) }
        if model.showSchemaNotice { out.append(.schema) }
        return out
    }

    var body: some View {
        if let top = items.first {
            strip(top, more: items.count - 1)
        }
    }

    @ViewBuilder private func strip(_ item: Item, more: Int) -> some View {
        let amber = item == .wrongFolder
        HStack(spacing: 12) {
            Text(glyph(item)).font(Typo.font(14))
            content(item)
            if more > 0 {
                Text("+\(more)").font(Typo.numS)
                    .foregroundStyle(Palette.text.opacity(0.6))
                    .help("มีเรื่องแจ้งอีก \(more) อย่าง — ดูที่หน้าเกี่ยวกับแอป")
            }
            Spacer(minLength: 8)
            buttons(item)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background((amber ? Palette.amber : Palette.cyan).opacity(amber ? 0.16 : 0.18))
        .overlay(alignment: .leading) {
            Rectangle().fill(amber ? Palette.amber : Palette.cyan)
                .frame(width: 3).allowsHitTesting(false)
        }
        .foregroundStyle(Palette.text)
    }

    private func glyph(_ i: Item) -> String {
        switch i {
        case .wrongFolder: return "⚠"
        case .update: return model.updateInstalling ? "⟳" : "⬆"
        case .justUpdated: return "✓"
        case .schema: return "ℹ"
        }
    }

    @ViewBuilder private func buttons(_ i: Item) -> some View {
        switch i {
        case .wrongFolder:
            // No dismiss: nothing in the app works from that folder, so hiding the only thing
            // that explains why would be the worst possible kindness.
            pill("ดูวิธีแก้", prominent: false) { model.showAbout = true }
        case .update:
            if model.updateInstalling {
                // Nothing to press. A cancel button here would have to abort a swap that may
                // already be under way in another process.
                EmptyView()
            } else {
                // This is the button the whole feature is for: one press, one confirm, done.
                pill("อัปเดตเลย", prominent: true) { model.installUpdate() }
                pill("รายละเอียด", prominent: false) { model.showAbout = true }
                dismissPill { model.dismissUpdateNotice() }
            }
        case .justUpdated:
            pill("มีอะไรใหม่", prominent: false) { model.showAbout = true }
            dismissPill { model.justUpdatedFrom = nil }
        case .schema:
            pill("ดูรายละเอียด", prominent: false) { model.showAbout = true }
            dismissPill { model.dismissSchemaNotice() }
        }
    }

    private func pill(_ t: String, prominent: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.font(12, .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 7))
        .background(prominent ? Palette.cyan.opacity(0.42) : Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func dismissPill(_ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text("ไว้ก่อน").font(Typo.font(11))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(corner: 7))
        .foregroundStyle(Palette.text.opacity(0.7))
        .help("ปิดแถบนี้ — เลขเวอร์ชั่นในรายชื่อเพลงจะยังเป็นสีฟ้าไว้เตือน")
    }

    @ViewBuilder private func content(_ i: Item) -> some View {
        switch i {
        case .wrongFolder:
            Text("นี่คือโฟลเดอร์ที่แตก zip ออกมา ไม่ใช่ที่ติดตั้ง")
                .font(Typo.font(13, .bold)).foregroundStyle(Palette.amber)
            Text("ปิดแอปนี้ แล้วดับเบิลคลิก ติดตั้ง-อัปเดต.command — โจทย์และเพลงของคุณอยู่ในโฟลเดอร์เดิม")
                .font(Typo.font(12)).foregroundStyle(Palette.text)
                .layoutPriority(-1).lineLimit(1)
        case .update:
            if model.updateInstalling {
                Text(model.updateStep.isEmpty ? "กำลังอัปเดต…" : model.updateStep)
                    .font(Typo.font(13, .bold))
                progressBar
            } else if let u = model.updateInfo {
                Text("มีเวอร์ชั่นใหม่ \(u.version)").font(Typo.font(13, .bold))
                Text("· ตอนนี้ใช้ \(AppVersion.display)")
                    .font(Typo.font(12)).foregroundStyle(Palette.text.opacity(0.85))
                if u.needsNewerOS {
                    Text("· ⚠ เครื่องนี้ใช้ไม่ได้ (ต้อง macOS \(u.minMacOS))")
                        .font(Typo.font(12, .semibold)).foregroundStyle(Palette.amber)
                } else if !u.notes.isEmpty {
                    // `layoutPriority(-1)` is load-bearing. SwiftUI shares a width shortfall out
                    // in proportion to ideal widths, so a 1200-char note (the cap) has a ~7000 pt
                    // ideal and dominated the row: the VERSION NUMBER truncated to "มีเวอร์ชั่นใ…"
                    // and the buttons collapsed to ellipses. Capping the string bounded the
                    // string, not the layout.
                    Text("· \(u.notes)")
                        .font(Typo.font(12)).foregroundStyle(Palette.text.opacity(0.75))
                        .layoutPriority(-1).lineLimit(1)
                }
            }
        case .justUpdated:
            // Cyan, not green. §6d gives green exactly one meaning — "a human answered
            // correctly" — and this strip sits in the same visual field as ✓ Correct, 60 pt
            // above the transport. The glyph and the word carry "it worked" without spending
            // the hue that the outcome pair depends on.
            Text("อัปเดตเป็น \(AppVersion.display) แล้ว").font(Typo.font(13, .bold))
            Text("· จากเวอร์ชั่น \(model.justUpdatedFrom ?? "—") · โจทย์และ log อยู่ครบ")
                .font(Typo.font(12)).foregroundStyle(Palette.text.opacity(0.85))
                .layoutPriority(-1).lineLimit(1)
        case .schema:
            Text("ไฟล์โจทย์เคยถูกเปิดด้วยแอปเวอร์ชั่นใหม่กว่า").font(Typo.font(13, .bold))
            Text("· เล่นและแก้ได้ปกติ ค่าที่แอปนี้ไม่รู้จักไม่ถูกลบ — แต่ควรอัปเดตให้ตรงกัน")
                .font(Typo.font(12)).foregroundStyle(Palette.text.opacity(0.8))
                .layoutPriority(-1).lineLimit(1)
        }
    }

    /// Fixed width so the strip's height and the buttons' position do not move as it fills —
    /// same reasoning as the transport buttons that used to slide (§12).
    @ViewBuilder private var progressBar: some View {
        if model.updateProgress >= 0 {
            ProgressView(value: min(1, max(0, model.updateProgress)))
                .progressViewStyle(.linear)
                .frame(width: 180)
            Text("\(Int(min(1, max(0, model.updateProgress)) * 100))%")
                .font(Typo.numS).foregroundStyle(Palette.text.opacity(0.8))
        } else {
            ProgressView().progressViewStyle(.linear).frame(width: 180)
        }
    }
}

/// Version, where the data lives, and how to update.
///
/// Everything a support call needs in one place. "Which version are you on" and "which folder is
/// it reading" are the first two questions for any report from the field, and before this there
/// was no way for the person holding the machine to answer either.
struct AboutPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var feed = ""
    @State private var feedLoaded = false
    /// Reported INSIDE the sheet. `model.flash` renders a toast in the parent window's content,
    /// which a macOS sheet covers — so every confirmation from here was invisible.
    @State private var note = ""

    private var feedDirty: Bool {
        feed.trimmingCharacters(in: .whitespacesAndNewlines) != model.store.updateFeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("เกี่ยวกับแอป").font(Typo.title).foregroundStyle(Palette.text)
                Spacer()
                Button { model.showAbout = false } label: {
                    Text("✕").font(Typo.font(16)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 6))
                .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider().overlay(Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.launchedFromRelease { wrongFolderNotice }
                    identity
                    if let u = model.updateInfo { updateFound(u) } else { upToDate }
                    feedSetting
                    howToUpdate
                }
                .padding(20)
            }
            // Reserved height, not conditional: §12 records that a line appearing and
            // disappearing moves everything below it under the cursor.
            Text(note)
                .font(Typo.caption)
                .foregroundStyle(note.hasPrefix("✓") ? Palette.greenText : Palette.amber)
                .frame(height: 18, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .frame(width: 720, height: 620)
        .background(Palette.float)
        .onAppear {
            // Once only. Re-seeding on every model publish would snap the field back under the
            // cursor mid-typing — the same class of bug as the typed marker fields (§11).
            guard !feedLoaded else { return }
            feed = model.store.updateFeed
            feedLoaded = true
        }
    }

    // MARK: - wrong folder

    private var wrongFolderNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⚠ แอปนี้กำลังอ่านข้อมูลจากโฟลเดอร์ที่แตก zip ออกมา")
                .font(Typo.font(14, .bold)).foregroundStyle(Palette.amber)
            Text("โฟลเดอร์นี้มีแค่ตัวโปรแกรม ไม่มีเพลงและไม่มีโจทย์ของคุณ — ที่เห็นว่างเปล่าเป็นเรื่องปกติ\n"
                 + "ปิดแอปนี้ แล้วดับเบิลคลิก ติดตั้ง-อัปเดต.command ในโฟลเดอร์เดียวกัน "
                 + "มันจะเอาตัวโปรแกรมใหม่ไปวางในโฟลเดอร์จริงของคุณให้")
                .font(Typo.caption).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amber.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.amber.opacity(0.5))
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("RGF Intro Player").font(Typo.font(17, .bold)).foregroundStyle(Palette.text)
                Text(AppVersion.display).font(Typo.numL).foregroundStyle(Palette.cyan)
            }
            row("บิลด์", AppVersion.commit.isEmpty && AppVersion.date.isEmpty
                ? "— (บิลด์จากเครื่อง ไม่ได้ stamp)"
                : [AppVersion.commit, AppVersion.date].filter { !$0.isEmpty }.joined(separator: " · "))
            row("macOS", UpdateInfo.runningOS)
            // The single most useful line on a support call: an app reading the wrong folder looks
            // exactly like an app that lost its settings.
            row("โฟลเดอร์ข้อมูล", AppPaths.root.path, mono: true)
            // "เขียนล่าสุดโดย" was false within a second of launch: `openedBy` is captured at
            // load, but selecting the first song saves, which rewrites `writtenBy` as this
            // build. What the field actually answers is "was this folder touched by another
            // build before now", which is the useful question — so it says that.
            row("รูปแบบไฟล์โจทย์",
                "schema \(model.store.schemaOnDisk)" +
                (model.store.schemaAhead ? " — ใหม่กว่าที่แอปนี้รู้จัก (\(Store.schema))" : "") +
                (model.store.openedBy.isEmpty ? "" : " · ก่อนเปิดครั้งนี้ เขียนโดย v\(model.store.openedBy)"))
            HStack(spacing: 8) {
                Button {
                    // `config.json` does not exist until the first save — and a brand-new or
                    // TCC-blocked folder is exactly the case this button exists to diagnose.
                    let fm = FileManager.default
                    if fm.fileExists(atPath: AppPaths.config.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config])
                    } else {
                        NSWorkspace.shared.open(AppPaths.root)
                    }
                } label: {
                    Text("เปิดโฟลเดอร์ข้อมูล").font(Typo.font(12))
                        .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 6))
                .background(Palette.panel3).clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Palette.text)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(supportSummary, forType: .string)
                    note = "✓ คัดลอกแล้ว — paste ส่งให้คนดูแลได้เลย"
                } label: {
                    Text("คัดลอกข้อมูลสำหรับแจ้งปัญหา").font(Typo.font(12))
                        .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 6))
                .background(Palette.panel3).clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Palette.text)
            }
            .padding(.top, 2)
        }
    }

    /// One paste that answers every question a report from the field raises.
    private var supportSummary: String {
        """
        RGF Intro Player \(AppVersion.full)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        โฟลเดอร์: \(AppPaths.root.path)\
        \(model.launchedFromRelease ? "  ⚠ (โฟลเดอร์ที่แตก zip ไม่ใช่ที่ติดตั้ง)" : "")
        schema: \(model.store.schemaOnDisk) (แอปรู้จัก \(Store.schema))\
        \(model.store.openedBy.isEmpty ? "" : ", ก่อนเปิดครั้งนี้เขียนโดย v\(model.store.openedBy)")
        เพลง: \(model.songs.count) · รอบ: \(model.playlists.count)
        บันทึก: \(model.store.saveFailed ? "ล้มเหลว — \(model.store.saveState)" : "ปกติ")
        feed: \(model.store.updateFeed.isEmpty ? "— (ปิด)" : model.store.updateFeed)
        """
    }

    // MARK: - update

    private var upToDate: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("เวอร์ชั่นใหม่").font(Typo.subhead).foregroundStyle(Palette.text)
            HStack(spacing: 10) {
                Button { model.checkForUpdate(manual: true) } label: {
                    Text(model.updateChecking ? "กำลังเช็ก…" : "ตรวจเวอร์ชั่นใหม่")
                        .font(Typo.font(12, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 7))
                .background(Palette.panel3).clipShape(RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(Palette.text)
                .disabled(model.updateChecking || model.store.updateFeed.isEmpty)
                Text(model.updateState.isEmpty
                     ? (model.store.updateFeed.isEmpty
                        ? "ยังไม่ได้ตั้งที่อยู่ — ตั้งด้านล่าง หรือรอคนดูแลส่งไฟล์มาให้"
                        : "ยังไม่ได้ตรวจ")
                     : model.updateState)
                    .font(Typo.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func updateFound(_ u: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("⬆ มีเวอร์ชั่นใหม่ \(u.version)")
                    .font(Typo.font(14, .bold)).foregroundStyle(Palette.cyan)
                Text("(ตอนนี้ \(AppVersion.display))").font(Typo.caption).foregroundStyle(Palette.muted)
            }
            if !u.notes.isEmpty {
                Text(u.notes).font(Typo.caption).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if u.needsNewerOS {
                // Displaying `minMacOS` and leaving it at that was a trap: the operator runs the
                // installer, a WORKING bundle is replaced by one that cannot launch, and the way
                // back is a backups/ folder they will not find unaided.
                Text("⚠ เวอร์ชั่นนี้ต้องใช้ macOS \(u.minMacOS) ขึ้นไป — เครื่องนี้เป็น \(UpdateInfo.runningOS) "
                     + "อย่าติดตั้ง แจ้งคนดูแลก่อน")
                    .font(Typo.font(12, .semibold)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.updateInstalling {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.updateStep).font(Typo.font(13, .semibold))
                        .foregroundStyle(Palette.text)
                    if model.updateProgress >= 0 {
                        HStack(spacing: 8) {
                            ProgressView(value: min(1, max(0, model.updateProgress)))
                                .progressViewStyle(.linear)
                            Text("\(Int(min(1, max(0, model.updateProgress)) * 100))%")
                                .font(Typo.numS).foregroundStyle(Palette.muted)
                        }
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("อย่าปิดเครื่อง — แอปจะปิดตัวเองแล้วเปิดขึ้นมาใหม่")
                        .font(Typo.font(11)).foregroundStyle(Palette.muted)
                }
            } else {
            HStack(spacing: 8) {
                // The one-press path, and the reason the manual steps below are a *fallback*
                // now rather than the procedure.
                if u.openable != nil && !u.needsNewerOS {
                    Button { model.installUpdate() } label: {
                        Text("⬆ อัปเดตเลย").font(Typo.font(13, .bold))
                            .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(corner: 7))
                    .background(Palette.cyan.opacity(0.42))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.cyan.opacity(0.9))
                        .allowsHitTesting(false))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Palette.text)
                    .disabled(model.player.isPlaying)
                    Button {
                        note = model.openUpdateDownload() ?? ""
                    } label: {
                        Text(u.isLocalFile ? "เปิดโฟลเดอร์ที่มีไฟล์" : "โหลดเอง")
                            .font(Typo.font(12))
                            .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(corner: 7))
                    .background(Palette.panel3)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Palette.text)
                } else if !u.download.isEmpty {
                    Text("ที่อยู่ไฟล์: \(u.download)")
                        .font(Typo.font(11, mono: true)).foregroundStyle(Palette.muted)
                        .textSelection(.enabled).lineLimit(2)
                } else {
                    Text("ชุดอัปเดตนี้ไม่ได้บอกที่อยู่ไฟล์ — ขอไฟล์จากคนดูแลโดยตรง")
                        .font(Typo.caption).foregroundStyle(Palette.amber)
                }
                Button { model.checkForUpdate(manual: true) } label: {
                    Text("ตรวจอีกครั้ง").font(Typo.font(12))
                        .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 7))
                .background(Palette.panel3).clipShape(RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(Palette.text)
                .disabled(model.updateChecking)
            }
            if model.player.isPlaying {
                Text("⚠ กำลังเล่นเพลงอยู่ — กดอัปเดตไม่ได้ (การอัปเดตต้องปิดแอป) หยุดเพลงก่อน")
                    .font(Typo.font(12, .semibold)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cyan.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.cyan.opacity(0.45))
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var feedSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ที่อยู่สำหรับเช็กเวอร์ชั่น").font(Typo.subhead).foregroundStyle(Palette.text)
            Text("ใส่ได้ 3 แบบ — **GitHub**: `owner/repo` · **โฟลเดอร์ที่ sync ไว้**: path ที่เริ่มด้วย / "
                 + "(ไม่ต้องใช้เน็ตตอนเช็ก) · **เว็บ**: ลิงก์ https:// ที่มี manifest.json\n"
                 + "เว้นว่าง = ปิดการเช็ก")
                .font(Typo.font(11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("", text: $feed)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.font(12, mono: true))
                    .onSubmit { save() }
                    // Mirrors `MarkerTimeField` (§11): the amber edge is the only thing saying
                    // the typed text is not in effect yet. Unlike a marker field there is no
                    // visible snap-back, so without it a closed sheet silently discarded it.
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Palette.amber, lineWidth: feedDirty ? 2 : 0)
                        .allowsHitTesting(false))
                Button { save() } label: {
                    Text("บันทึก").font(Typo.font(12, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 6))
                .background(feedDirty ? Palette.cyan.opacity(0.28) : Palette.panel3)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Palette.text)
                .disabled(!feedDirty)
            }
            if feedDirty {
                Text("ยังไม่ได้บันทึก — กด Enter หรือปุ่มบันทึก (ปิดหน้านี้ไปเลยจะไม่ถูกบันทึก)")
                    .font(Typo.font(11)).foregroundStyle(Palette.amber)
            }
            // `feedKind`, not `manifestLocation`: a GitHub feed does not resolve to a
            // manifest URL, and showing one would describe something the app will not read.
            // Still purely syntactic, so it is safe to call from `body` (§15).
            if let kind = Updater.feedKind(feed), !feed.isEmpty {
                Text("จะอ่านจาก: \(kind.describe)")
                    .font(Typo.font(11, mono: true)).foregroundStyle(Palette.dim)
                    .lineLimit(2)
            } else if !feed.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("⚠ ที่อยู่นี้ใช้ไม่ได้ — ต้องเป็น owner/repo (GitHub), "
                     + "path ที่เริ่มด้วย / หรือ ~, หรือลิงก์ https://")
                    .font(Typo.font(11)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard feedDirty else { return }
        model.setUpdateFeed(feed)
        feed = model.store.updateFeed
        note = model.store.updateFeed.isEmpty
            ? "✓ ปิดการเช็กเวอร์ชั่นแล้ว"
            : "✓ บันทึกที่อยู่แล้ว — กด \"ตรวจเวอร์ชั่นใหม่\" เพื่อลอง"
    }

    // MARK: - instructions

    private var howToUpdate: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("ถ้าอัปเดตในแอปไม่ได้ — ทำมือ").font(Typo.subhead).foregroundStyle(Palette.text)
                Spacer()
                Button { model.openUpdateLog() } label: {
                    Text("เปิด log การอัปเดต").font(Typo.font(11))
                        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(corner: 5))
                .foregroundStyle(Palette.muted)
                .help("ตัวติดตั้งเขียนไว้ที่ ~/Library/Logs/IntroPlayer-update.log")
            }
            // Said plainly and first, because it is the thing the operator is actually worried
            // about. The questions are siblings of the bundle, never inside it (§5).
            // Cyan, not green: §6d gives green one meaning only ("a human answered correctly")
            // and this app's two biggest buttons depend on that pair not being diluted.
            Text("โจทย์ที่ตั้งไว้ · log การถ่าย · ไฟล์เพลง — ไม่ถูกแตะเลย ตัวอัปเดตเปลี่ยนแค่ตัวแอป")
                .font(Typo.font(12, .medium)).foregroundStyle(Palette.cyan)
            step(1, "ปิดแอปก่อน (Cmd+Q) — ห้ามอัปเดตตอนกำลังถ่าย")
            step(2, "แตกไฟล์ zip ที่ได้มา (ดับเบิลคลิก)")
            step(3, "ดับเบิลคลิก ติดตั้ง-อัปเดต.command ในโฟลเดอร์ที่แตกออกมา")
            step(4, "ถ้า macOS เตือนว่าเปิดไม่ได้ → คลิกขวาที่ไฟล์ → Open → Open\n"
                 + "ถ้ายังไม่ได้ → System Settings → Privacy & Security → กด \"Open Anyway\"\n"
                 + "(ต้องทำใหม่ทุกครั้งที่ดาวน์โหลดไฟล์ชุดใหม่ — ไม่ใช่ครั้งเดียวจบ)")
            // The one step where a dialog asks the operator something, and it was the step the
            // copy physically in front of them left out.
            step(5, "มันจะถามว่าจะลงที่โฟลเดอร์ไหน — ถ้าเคยใช้แล้วมันหาให้เอง กด \"อัปเดต\"")
            step(6, "เปิดแอปใหม่ แล้วเช็กที่หน้านี้ว่าเลขเวอร์ชั่นเปลี่ยนแล้ว")
            Text("ตัวติดตั้งจะคัดลอก config.json กับ log.json เก็บไว้ใน backups/ ให้ก่อนเปลี่ยนเสมอ "
                 + "พร้อมไฟล์ชุดเดิมทั้งหมด เผื่อต้องย้อนกลับ\n"
                 + "— แต่นั่นคือการสำรองเฉพาะตอนอัปเดต ไม่ใช่การสำรองประจำวัน "
                 + "ถ้าอยากได้สำเนาโจทย์ไว้ที่อื่น ให้ก๊อปโฟลเดอร์รอบนั้นเก็บไว้เอง (ดูหัวข้อส่งต่อ)")
                .font(Typo.font(11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Typo.numS).foregroundStyle(Palette.cyan)
                .frame(width: 14, alignment: .trailing)
            Text(t).font(Typo.caption).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(Typo.caption).foregroundStyle(Palette.muted)
                .frame(width: 118, alignment: .leading)
            Text(v)
                .font(mono ? Typo.font(12, mono: true) : Typo.caption)
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
