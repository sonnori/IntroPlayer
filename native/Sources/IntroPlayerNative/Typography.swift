import AppKit
import SwiftUI

/// Type and colour tokens.
///
/// ## Why a font cascade and not `.font(.system)`
///
/// `.font(.system)` does NOT render this app's Thai in SF. CoreText resolves Thai to
/// `.ThonburiUI-Regular` (verified with `CTRunGetAttributes`), which has three weights — so
/// `.medium`, `.semibold`, `.bold` and `.heavy` all collapse onto `ThonburiUI-Bold`. The app had
/// two usable Thai weights, not five, and no typographic hierarchy was even expressible. On top
/// of that ThonburiUI's mark zone overflows the declared ascent at 13pt, clipping tone marks.
///
/// The fix is a cascade, not a font swap: SF stays the base descriptor (Latin, metrics, tabular
/// digits) with `SukhumvitSet` as the Thai fallback. Measured on this machine:
///
/// | | ascender | descender | line box @13pt |
/// |---|---|---|---|
/// | SF base (today) | 12.57 | −2.74 | 16.0 |
/// | **SF + SukhumvitSet cascade** | **12.57** | **−2.74** | **16.0 — identical** |
/// | SukhumvitSet directly | 14.34 | −6.16 | 20.0 (+25%) |
///
/// So the cascade costs **zero layout change** while giving mark headroom, 4% narrower Thai and
/// four real Thai weights. Using the face directly would inflate every row by a quarter.
///
/// `SukhumvitSet.ttc` ships in `/System/Library/Fonts/Supplemental/` on every macOS 13+, so this
/// adds no dependency. (Sarabun does NOT — it is a downloadable asset on this machine only.)
enum Typo {
    /// Thai renders no smaller than this. Rasterised at 1x, the mark stack of `ตั้งค่าแล้ว` is a
    /// single ~25%-coverage row at 10–11pt: `่` and `ั` fuse into a grey smear. The app runs on a
    /// 2560x1080 LG WFHD — scale 1.0, ~81 PPI — so there is no Retina margin to hide it.
    ///
    /// This matters most for `✗ ไม่มีคนตอบ` vs `✓ ตอบถูก`: a burned question misread as a
    /// usable one defeats the entire point of the taping log.
    static let thaiFloor: CGFloat = 12

    private static let thaiFace: [NSFont.Weight: String] = [
        .regular: "SukhumvitSet-Text",
        .medium: "SukhumvitSet-Medium",
        .semibold: "SukhumvitSet-SemiBold",
        .bold: "SukhumvitSet-Bold",
        .heavy: "SukhumvitSet-Bold",
    ]

    private static var cache: [String: Font] = [:]

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular,
                     mono: Bool = false, latinOnly: Bool = false) -> Font {
        // Latin-only micro labels ("Space", "R", "1xx") may go below the Thai floor.
        let s = latinOnly ? size : max(size, thaiFloor)
        let key = "\(s)|\(weight.rawValue)|\(mono)"
        if let hit = cache[key] { return hit }
        let base = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: s, weight: weight)
            : NSFont.systemFont(ofSize: s, weight: weight)
        let name = thaiFace[weight] ?? "SukhumvitSet-Text"
        let desc = base.fontDescriptor.addingAttributes(
            [.cascadeList: [NSFontDescriptor(fontAttributes: [.name: name])]])
        let f = Font(NSFont(descriptor: desc, size: s) ?? base)
        cache[key] = f
        return f
    }

    // The scale. Thai needs ~1.85x the vertical ink of Latin per marked line, so the step from
    // `label` down is a floor, not a taper.
    static let display = font(26, .semibold)          // current song title
    static let title   = font(19, .semibold)          // sheet headings, stat numbers
    static let headline = font(16, .semibold)         // transport, Correct/Wrong
    static let subhead = font(14, .medium)            // marker names, section heads
    static let body    = font(13)                     // song rows, setup labels
    static let bodyEm  = font(13, .medium)            // selected row
    static let label   = font(12, .medium)            // badges, chips
    static let caption = font(12)                     // helper text
    static let micro   = font(11, .medium, latinOnly: true)   // Latin key hints only

    static let numXL = font(28, .semibold, mono: true)   // the intro countdown
    static let numL  = font(19, .medium, mono: true)
    static let numM  = font(14, .medium, mono: true)     // marker values
    static let numS  = font(12, .medium, mono: true)     // counts, clocks, zoom span
}
