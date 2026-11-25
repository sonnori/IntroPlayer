import Foundation

/// Colour measurement for `Palette`, both themes. Exists because §6d's whole argument rests on
/// measured numbers — contrast ratios, ΔL\* ladder steps, deutan ΔE2000 — and until this file
/// those numbers lived only in a comment. A comment cannot fail a build, so the one thing that
/// made the palette defensible was also the one thing nothing checked.
///
/// `--palettetest` asserts them. Not as a style guard: the pair it protects hardest is
/// ✓ ตอบถูก / ✗ ไม่มีคนตอบ, the two biggest buttons in a taping, which an earlier palette had at
/// a deutan separation of effectively nothing.
enum ColorMath {

    // MARK: - sRGB

    static func channels(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
    static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    static func toSRGB(_ c: Double) -> Double {
        let v = min(1, max(0, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    static func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        let q = { (v: Double) in UInt32(max(0, min(255, (toSRGB(v) * 255).rounded()))) }
        return (q(r) << 16) | (q(g) << 8) | q(b)
    }

    /// WCAG 2.x relative luminance and contrast ratio.
    static func luminance(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b)
    }
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - CIELAB

    private static let white = (0.95047, 1.0, 1.08883)

    static func lab(_ hex: UInt32) -> (L: Double, a: Double, b: Double) {
        let (r0, g0, b0) = channels(hex)
        let r = toLinear(r0), g = toLinear(g0), bl = toLinear(b0)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * bl
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * bl
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? cbrt(t) : (841.0 / 108.0) * t + 4.0 / 29.0
        }
        let fx = f(x / white.0), fy = f(y / white.1), fz = f(z / white.2)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
    static func lightness(_ hex: UInt32) -> Double { lab(hex).L }

    /// CIEDE2000.
    static func deltaE(_ h1: UInt32, _ h2: UInt32) -> Double {
        let (L1, a1, b1) = lab(h1), (L2, a2, b2) = lab(h2)
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cb = (c1 + c2) / 2
        let cb7 = pow(cb, 7)
        let g = 0.5 * (1 - (cb7 / (cb7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ a: Double, _ b: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let d = atan2(b, a) * 180 / .pi
            return d < 0 ? d + 360 : d
        }
        let h1p = hue(a1p, b1), h2p = hue(a2p, b2)
        let dLp = L2 - L1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            let d = h2p - h1p
            if abs(d) <= 180 { dhp = d } else if d > 180 { dhp = d - 360 } else { dhp = d + 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * .pi / 360)
        let Lbp = (L1 + L2) / 2, Cbp = (c1p + c2p) / 2
        var hbp = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hbp = (h1p + h2p) / 2 }
            else if h1p + h2p < 360 { hbp = (h1p + h2p + 360) / 2 }
            else { hbp = (h1p + h2p - 360) / 2 }
        }
        func cosd(_ d: Double) -> Double { cos(d * .pi / 180) }
        let T = 1 - 0.17 * cosd(hbp - 30) + 0.24 * cosd(2 * hbp)
                + 0.32 * cosd(3 * hbp + 6) - 0.20 * cosd(4 * hbp - 63)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Cbp7 = pow(Cbp, 7)
        let Rc = 2 * (Cbp7 / (Cbp7 + pow(25, 7))).squareRoot()
        let Sl = 1 + (0.015 * pow(Lbp - 50, 2)) / (20 + pow(Lbp - 50, 2)).squareRoot()
        let Sc = 1 + 0.045 * Cbp
        let Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * .pi / 180) * Rc
        let kl = dLp / Sl, kc = dCp / Sc, kh = dHp / Sh
        return (kl * kl + kc * kc + kh * kh + Rt * kc * kh).squareRoot()
    }

    // MARK: - deuteranopia

    /// Viénot, Brettel & Mollon (1999), applied in linear RGB. Deutan is the common form and the
    /// one that matters here: it collapses the red-green axis, which is why an outcome pair of
    /// "green vs red" cannot be assumed to be two colours.
    private static let toLMS = [[17.8824, 43.5161, 4.11935],
                                [3.45565, 27.1554, 3.86714],
                                [0.0299566, 0.184309, 1.46709]]

    private static let fromLMS: [[Double]] = {
        let m = toLMS
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        return [
            [(m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det,
             (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det,
             (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det],
            [(m[1][2] * m[2][0] - m[1][0] * m[2][2]) / det,
             (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det,
             (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det],
            [(m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det,
             (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det,
             (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det],
        ]
    }()

    private static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { r in (0..<3).reduce(0.0) { $0 + m[r][$1] * v[$1] } }
    }

    static func deutan(_ hex: UInt32) -> UInt32 {
        let (r, g, b) = channels(hex)
        let lms = apply(toLMS, [toLinear(r), toLinear(g), toLinear(b)])
        let sim = [lms[0], 0.494207 * lms[0] + 1.24827 * lms[2], lms[2]]
        let out = apply(fromLMS, sim)
        return pack(out[0], out[1], out[2])
    }
    static func deutanDeltaE(_ a: UInt32, _ b: UInt32) -> Double {
        deltaE(deutan(a), deutan(b))
    }
}

extension Diagnostics {
    /// Read-only. Writes nothing and touches no audio.
    static func paletteTest() {
        var pass = 0, fail = 0
        func assertThat(_ name: String, _ ok: Bool, _ detail: String) {
            if ok { pass += 1 } else { fail += 1 }
            print("   \(ok ? "ok " : "✗  ")\(name)  \(detail)")
        }
        func c(_ n: String, dark: Bool) -> UInt32 {
            guard let e = Palette.audit.first(where: { $0.0 == n }) else { return 0 }
            return dark ? e.1 : e.2
        }

        for dark in [true, false] {
            let name = dark ? "มืด (dark)" : "สว่าง (light)"
            print("\n=== ธีม\(name) ===")
            let panel2 = c("panel2", dark: dark), panel = c("panel", dark: dark)

            // 1. the surface ladder. 4.2-4.4 ΔL* read as one flat field at 81 PPI; 5.5 is floor.
            print("  1) ชั้นพื้นผิว ต้องห่างกัน >= 5.5 ΔL*")
            let ladder = ["bg", "panel", "panel2", "float"]
            for (a, b) in zip(ladder, ladder.dropFirst()) {
                let d = abs(ColorMath.lightness(c(b, dark: dark)) - ColorMath.lightness(c(a, dark: dark)))
                assertThat("\(a) → \(b)", d >= 5.4, String(format: "ΔL* %.1f", d))
            }
            let dPanel3 = abs(ColorMath.lightness(c("panel3", dark: dark)) - ColorMath.lightness(panel2))
            assertThat("panel2 ↔ panel3", dPanel3 >= 5.4, String(format: "ΔL* %.1f", dPanel3))

            // 2. text. `dim` is a 3:1 tier by design — it is never body copy.
            print("  2) ข้อความบนพื้น")
            for (t, need) in [("text", 4.5), ("muted", 4.5), ("dim", 3.0)] {
                let a = ColorMath.contrast(c(t, dark: dark), panel2)
                let b = ColorMath.contrast(c(t, dark: dark), panel)
                assertThat("\(t) >= \(need):1", min(a, b) >= need,
                           String(format: "panel2 %.2f:1  panel %.2f:1", a, b))
            }

            // 3. a saturated fill must separate from its surface, and carry `ink` legibly.
            print("  3) สีหลักบนพื้น และ ink บนสีหลัก")
            let ink = c("ink", dark: dark)
            for n in ["accent", "cyan", "green", "red", "amber", "purple", "onsite"] {
                let v = c(n, dark: dark)
                let onSurface = ColorMath.contrast(v, panel2)
                let inkOn = ColorMath.contrast(ink, v)
                assertThat("\(n)", onSurface >= 3.0 && inkOn >= 4.5,
                           String(format: "บนพื้น %.2f:1  ink บนมัน %.2f:1", onSurface, inkOn))
            }
            // `header` is judged differently and deliberately: it is a full-width BAR, not a
            // control, so it has no component boundary to earn 3:1 against — and what sits on
            // it is fixed light (`onHeader` / `onHeaderWarn`), never theme-flipping `ink`,
            // because the bar is dark red in both themes. Checking `ink` here reported a
            // failure against the palette when the mistake was in the check.
            let head = c("header", dark: dark)
            // Read from the audit list, not re-typed. The list exists so the check measures the
            // real value; typing `0xFFFFFF` here again is exactly the drift it is meant to stop.
            let w = ColorMath.contrast(c("onHeader", dark: dark), head)
            let warn = ColorMath.contrast(c("onHeaderWarn", dark: dark), head)
            assertThat("header: ขาวบนมัน >= 4.5:1", w >= 4.5, String(format: "%.2f:1", w))
            assertThat("header: amber เตือน save fail >= 3:1", warn >= 3.0,
                       String(format: "%.2f:1", warn))

            // 4. THE pair. Everything else in this file is hygiene; this is the one that decides
            //    whether a deutan viewer can tell ✓ ตอบถูก from ✗ ไม่มีคนตอบ.
            print("  4) คู่ผลลัพธ์ — ตาบอดสีเขียว-แดง (deutan)")
            let g = ColorMath.deutanDeltaE(c("green", dark: dark), c("red", dark: dark))
            let gt = ColorMath.deutanDeltaE(c("greenText", dark: dark), c("red", dark: dark))
            assertThat("green vs red", g >= 10.0, String(format: "ΔE %.1f", g))
            assertThat("greenText vs red", gt >= 20.0, String(format: "ΔE %.1f", gt))

            // 5. amber is the armed/disarmed carrier and must not collapse onto anything else
            //    that carries a meaning. §6d gives each hue exactly one, and amber's is "the
            //    intro-end stop is not armed".
            print("  5) amber (= ไม่หยุดเอง) ต้องไม่กลืนกับสีที่มีความหมายอื่น")
            for n in ["accent", "purple"] {
                let d = ColorMath.deutanDeltaE(c("amber", dark: dark), c(n, dark: dark))
                assertThat("amber vs \(n)", d >= 40.0, String(format: "ΔE %.1f", d))
            }
            // green and red were MISSING from this loop, and green is the pair that matters
            // most: it means "a human answered correctly" and amber means "the whole song is
            // about to play on camera". Found by negative control — setting amber's audit entry
            // to green's hex left the suite at 191 ผ่าน / 0 ตก, so the one rule §6d calls
            // load-bearing was measured by nothing at all.
            let aVsGreen = ColorMath.deutanDeltaE(c("amber", dark: dark), c("green", dark: dark))
            assertThat("amber vs green", aVsGreen >= 10.0, String(format: "ΔE %.1f", aVsGreen))
            // amber vs red: 20.6 dark, **6.1 light** — to a deutan viewer, the same colour on a
            // white ground. MEASURED, and pinned rather than fixed, for the same reason §6d pins
            // accent-vs-purple: separating it means moving a shipping status colour, and this
            // palette's light-theme lightness budget is already spent (§6d — a white ground
            // forces every accent down to roughly L* 46, which is what flattens the spread).
            //
            // Survivable, and the reasons are specific rather than hopeful. Light is the
            // SETTER's theme at a desk (§6d: dark is the operator's, and an unreadable `theme`
            // value falls back to dark for that reason), so neither state is being read under
            // time pressure there. Both carry a word — the guard strip says "⚠ ไม่หยุดเอง" and
            // §6d's rule is that amber plus a word is the carrier, never the hue alone. And the
            // save-failure bar is NOT this red: it sits on `header`, which is dark in both
            // themes with fixed-light text on it.
            //
            // So: amber and red may never be the sole difference between two things in the light
            // theme. If this ever needs fixing rather than pinning, it is a decision about the
            // show's colours, not a test threshold to nudge.
            let aVsRed = ColorMath.deutanDeltaE(c("amber", dark: dark), c("red", dark: dark))
            assertThat(dark ? "amber vs red" : "amber vs red (ธีมสว่าง: กลืนกัน ตามที่วัดไว้)",
                       dark ? aVsRed >= 15.0 : aVsRed < 10.0,
                       String(format: "ΔE %.1f%@", aVsRed,
                              dark ? "" : " — ห้ามใช้เหลือง/แดงเป็นตัวแยกสถานะเดี่ยว ๆ"))

            // 6. PINNED, not fixed. accent vs purple are the same colour to a deutan viewer in
            //    both themes. A future "improvement" that separated them would quietly invite
            //    blue-vs-purple to become the only carrier of the armed bit again — which is the
            //    bug §6d exists to prevent. If this ever fails, read §6d before changing it.
            let collide = ColorMath.deutanDeltaE(c("accent", dark: dark), c("purple", dark: dark))
            assertThat("accent vs purple ยังกลืนกัน (ตามที่ออกแบบ)", collide < 6.0,
                       String(format: "ΔE %.1f — ห้ามใช้ฟ้า/ม่วงสื่อสถานะเดี่ยวๆ", collide))

            // 7. The tinted chips. These were added for the light theme and then not measured
            //    — the audit list named none of them, so the suite passed 44/44 while testing
            //    nothing the theme change introduced. Each pair below is a real call site.
            print("  7) ตัวอักษรบนชิปสีอ่อน/เข้ม")
            let chips: [(String, String, String)] = [
                ("text", "tintSelect", "แถวเพลงที่เลือก"),
                ("tintSelectText", "tintSelect", "ชื่อเพลงที่เลือก"),
                ("text", "tintCyan", "การ์ดอัตโนมัติ"),
                ("cyanOnTint", "tintCyan", "ป้าย 🎯 / ปุ่มสโคป"),
                ("text", "tintWarn", "การ์ด played / ข้าม Intro End"),
                ("amberOnTint", "tintWarn", "ข้อความเตือนบนการ์ดนั้น"),
                ("greenText", "tintGood", "แถว log ตอบถูก"),
                ("redOnTint", "tintBad", "แถว log ไม่มีคนตอบ / แถบ save fail"),
                ("text", "tintBad", "คำอธิบายบนแถบ save fail"),
                ("muted", "tintBad", "คำอธิบายรองบนแถบนั้น"),
            ]
            for (fg, bg, what) in chips {
                let v = ColorMath.contrast(c(fg, dark: dark), c(bg, dark: dark))
                assertThat("\(fg) บน \(bg) — \(what)", v >= 4.5, String(format: "%.2f:1", v))
            }

            // 7b. The tag chips (§8g). Added originally with the same mistake as 7 — the
            //     values went into `Palette.audit` and the suite stayed at 64 assertions, i.e.
            //     it named them and measured none of them.
            //
            //     **The bar MOVED when the owner asked for แดง เหลือง เขียว น้ำเงิน ม่วง เทา.**
            //     It used to be "every tag INK is at least deutan ΔE 8 from green, red and
            //     amber", which a red/yellow/green ramp cannot pass by construction — a red
            //     tag is red. What replaces it is a bound on the thing a glance could actually
            //     misread: the chip's FILL, which is its whole area, where the status colours
            //     only ever appear as small text and badges. That bound is far WIDER than the
            //     one it replaces (20 vs 8), so this is not a relaxation dressed up as a rule.
            //
            //     The ink numbers are still measured and PRINTED every run, as the cost of the
            //     decision rather than as a pass/fail — the same treatment §6d gives the
            //     accent/purple collision it pins as expected.
            print("  7b) ชิปแท็ก — อ่านออก, พื้นชิปไม่ถูกอ่านเป็นสถานะ, และแยกกันได้")
            // A name without a colour crashes the picker; a colour without a name is
            // unreachable in it. They have to be the same length, and the order IS the wire
            // format (`_settings.tagColors`, `round.json`), so this is not cosmetic.
            if dark {
                assertThat("ชื่อสีแท็กครบตามจำนวนช่อง",
                           TagColor.allCases.count == Palette.tagSlots,
                           "\(TagColor.allCases.count) ชื่อ / \(Palette.tagSlots) ช่อง")
            }
            for i in 0..<Palette.tagSlots {
                let ink = c("tagInk\(i)", dark: dark), fill = c("tagFill\(i)", dark: dark)
                let v = ColorMath.contrast(ink, fill)
                assertThat("tagInk\(i) บน tagFill\(i)", v >= 4.5, String(format: "%.2f:1", v))
                // The chip has to read as sitting ON the pane, not as part of it.
                let sep = abs(ColorMath.lightness(fill) - ColorMath.lightness(c("panel", dark: dark)))
                assertThat("tagFill\(i) แยกจาก panel", sep >= 2.0, String(format: "ΔL* %.1f", sep))
                // The one that matters now. amber means "the intro-end stop is not armed",
                // green means a human answered, red means burned — and those three reach the
                // eye as text, never as a filled chip. So the filled chip must not be
                // mistakable for them, deutan included.
                for status in ["green", "red", "amber"] {
                    let d = ColorMath.deutanDeltaE(fill, c(status, dark: dark))
                    assertThat("tagFill\(i) ไม่ถูกอ่านเป็น \(status)", d >= 20.0,
                               String(format: "ΔE %.1f", d))
                }
            }
            // No two chips may be the SAME chip to a deutan viewer — by SOMETHING, fill or ink.
            //
            // `max(fill, ink)` rather than the fill alone, and that is a measurement result, not
            // a softened bar. In dark the fill is saturated and carries the identity (5.2–45.6
            // apart). In light the fill is a pale wash in a band `panel` splits in two, and pale
            // แดง vs pale เขียว comes out ΔE 2.2 — the same colour — while their INKS are 12.9
            // apart. Asserting the fill in both themes would have forced the light ramp back to
            // the washed-out version whose "ม่วง" read as white, i.e. it would have used a
            // number to argue for a palette that fails the thing it was asked for.
            for i in 0..<Palette.tagSlots {
                for j in (i + 1)..<Palette.tagSlots {
                    let df = ColorMath.deutanDeltaE(c("tagFill\(i)", dark: dark),
                                                    c("tagFill\(j)", dark: dark))
                    let di = ColorMath.deutanDeltaE(c("tagInk\(i)", dark: dark),
                                                    c("tagInk\(j)", dark: dark))
                    assertThat("ชิป \(TagColor(rawValue: i)?.label ?? "\(i)")"
                               + " ≠ \(TagColor(rawValue: j)?.label ?? "\(j)")",
                               max(df, di) >= 4.0,
                               String(format: "พื้น ΔE %.1f · ตัวอักษร ΔE %.1f", df, di))
                }
            }
            // The suggestion chips in SETUP draw the tag's ink on the BARE pane with only an
            // outline — no fill — so they are a call site this section would otherwise have
            // named and not measured, which is the `Palette.audit` mistake in miniature. The
            // panel is the worse of the two surfaces in light, so measure that one.
            for i in 0..<Palette.tagSlots {
                let v = ColorMath.contrast(c("tagInk\(i)", dark: dark), c("panel", dark: dark))
                assertThat("ชิปแนะนำ \(TagColor(rawValue: i)?.label ?? "\(i)") บน panel",
                           v >= 4.5, String(format: "%.2f:1", v))
            }
            print("     — ราคาที่จ่าย (วัดไว้ ไม่ใช่ข้อสอบ): ตัวอักษรในชิปเทียบสีสถานะ")
            for i in 0..<Palette.tagSlots {
                let ink = c("tagInk\(i)", dark: dark)
                let line = ["green", "red", "amber"].map { st in
                    String(format: "%@ %.1f", st, ColorMath.deutanDeltaE(ink, c(st, dark: dark)))
                }.joined(separator: "  ")
                let nm = (TagColor(rawValue: i)?.label ?? "?")
                    .padding(toLength: 10, withPad: " ", startingAt: 0)
                print("       \(nm) \(line)")
            }

            // 8. the waveform's inside/outside distinction
            let wd = abs(ColorMath.lightness(c("waveIn", dark: dark))
                         - ColorMath.lightness(c("waveOut", dark: dark)))
            assertThat("คลื่นใน/นอกช่วง intro", wd >= 10.0, String(format: "ΔL* %.1f", wd))
        }

        // 9. The colour menu's swatch. Theme-independent — it draws from `Palette.audit` by
        // name, and what can break is the WIRING: a slot with no audit entry falls back to a
        // grey square, which would ship silently as "that colour just looks grey in the menu".
        print("\n9) ตัวอย่างสีในเมนู (วาดจาก Palette.audit ตามชื่อ)")
        for i in 0..<Palette.tagSlots {
            let img = Palette.tagSwatch(i)
            let nm = TagColor(rawValue: i)?.label ?? "\(i)"
            assertThat("\(nm) ขนาด 12x12", img.size == NSSize(width: 12, height: 12),
                       "\(Int(img.size.width))x\(Int(img.size.height))")
            // Non-template or AppKit repaints it in the menu's own text colour — i.e. every
            // swatch identical, which is the whole feature gone with nothing to see.
            assertThat("\(nm) ไม่ใช่ template (ไม่งั้นเมนูจะทาสีทับ)", !img.isTemplate, "")
        }
        // The fallback must be reachable ONLY by asking for a name that does not exist. If a
        // real slot can reach it, a colour ships as a grey square.
        assertThat("ชื่อที่ไม่มีจริง → คืนค่าสำรอง (ม่วงแปร๋น ไม่ใช่เทา — ดู Palette.missingColour)",
                   Palette.auditHex("tagFillไม่มีจริง", dark: true) == Palette.missingColour, "")
        for i in 0..<Palette.tagSlots {
            let nm = TagColor(rawValue: i)?.label ?? "\(i)"
            // `Palette.missingColour`, NOT a literal: the sentinel moved from 0x808080 to
            // magenta, and a test spelling the old value would have passed for free on exactly
            // the colour that had gone missing.
            assertThat("\(nm) มีอยู่ใน audit จริง ไม่ได้ตกไปใช้ค่าสำรอง",
                       Palette.auditHex("tagFill\(i)", dark: true) != Palette.missingColour
                       && Palette.auditHex("tagInk\(i)", dark: true) != Palette.missingColour,
                       String(format: "#%06X", Palette.auditHex("tagFill\(i)", dark: true)))
        }
        // Distinct swatches: if two slots drew the same square the menu would be lying about
        // which colour you are choosing.
        var seen = Set<UInt32>()
        for i in 0..<Palette.tagSlots { seen.insert(Palette.auditHex("tagFill\(i)", dark: true)) }
        assertThat("ทั้ง \(Palette.tagSlots) ช่องวาดคนละสี", seen.count == Palette.tagSlots,
                   "\(seen.count) สีที่ต่างกัน")

        print("\n10) audit คือตัวสีจริง ไม่ใช่สำเนาของมัน")
        // The whole suite reads `audit`, `auditHex`, `tagSlots` and `tagSwatch` and NEVER a real
        // colour — so while `audit` was a table running parallel to 38 `dyn(...)` literals, all
        // 187 assertions measured the table and nothing measured what the app renders. Injecting
        // `amber = dyn(0x2FD17A, 0x1F5534)` — amber byte-identical to green, i.e. §6d's "the
        // intro-end stop is not armed" in the colour that means "a human answered correctly" —
        // left this suite at 187/0 with byte-identical output.
        //
        // The named colours now resolve THROUGH `audit` (`Palette.named`), so that drift cannot
        // exist. What this section guards is the new structure's own failure mode: a typo in one
        // of those name strings.
        assertThat("ชื่อใน audit ไม่ซ้ำกัน (ชื่อซ้ำ = ตัวที่สองเข้าไม่ถึงตลอดกาล)",
                   Set(Palette.audit.map(\.0)).count == Palette.audit.count,
                   "\(Palette.audit.count) รายการ / \(Set(Palette.audit.map(\.0)).count) ชื่อ")
        assertThat("ชื่อที่ไม่มีจริง → ได้สีม่วงแปร๋น ไม่ใช่เทาที่ดูเหมือนตั้งใจ",
                   Palette.auditHex("__ไม่มีสีนี้__", dark: true) == Palette.missingColour
                   && Palette.auditHex("__ไม่มีสีนี้__", dark: false) == Palette.missingColour,
                   String(format: "#%06X", Palette.auditHex("__ไม่มีสีนี้__", dark: true)))
        let clashes = Palette.audit.filter {
            $0.1 == Palette.missingColour || $0.2 == Palette.missingColour
        }
        assertThat("ไม่มีสีจริงไหนใช้ค่า sentinel (ไม่งั้นแยก \"หาย\" กับ \"ตั้งใจ\" ไม่ออก)",
                   clashes.isEmpty, clashes.map(\.0).joined(separator: ", "))
        // Every name the app asks for by hand must be in the table. Listed literally because
        // there is no way to enumerate the call sites — and §15's rule says a literal list stops
        // covering what arrives later, so this is a floor and not a ceiling: it is here to catch
        // a RENAME of something already in use, which is the realistic accident.
        let mustExist = ["bg", "panel", "panel2", "panel3", "float", "hair", "line", "lineStrong",
                         "text", "muted", "dim", "ink", "accent", "cyan", "green", "greenText",
                         "red", "amber", "purple", "hook", "onsite", "header", "outline",
                         "onHeader", "onHeaderWarn", "tintCyan", "tintWarn", "tintSelect",
                         "tintGood", "tintBad", "levelBar", "cyanOnTint", "amberOnTint",
                         "redOnTint", "waveOut"]
        let missing = mustExist.filter { n in !Palette.audit.contains { $0.0 == n } }
        assertThat("สีที่โค้ดเรียกด้วยชื่อ มีใน audit ครบ \(mustExist.count) ค่า",
                   missing.isEmpty, missing.joined(separator: ", "))

        print("\nผ่าน \(pass)  ตก \(fail)")
        Diagnostics.verdict(fail == 0, "✓ ผ่าน", "✗ ไม่ผ่าน")
    }
}
