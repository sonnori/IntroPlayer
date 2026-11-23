import AVFoundation
import Foundation

/// Waveform + loudness analysis for one song. Direct port of the web version's maths, including
/// the constants — the numbers it produces were validated against the real library and should not
/// drift without re-measuring.
final class Analysis {
    enum Failure: Error { case implausibleDuration }

    static let envHz: Double = 1000          // envelope buckets per second (~1 MB for 4.5 min)
    static let minSpan: Double = 0.2         // deepest zoom
    static let targetRms: Double = 0.13
    /// Where the auto-gain aims, in LUFS. Chosen as the level the OLD un-weighted-RMS path was
    /// already delivering on the real library (it landed around −15.2 LUFS on average), so
    /// switching the metric re-levels the set relative to each other without moving the whole
    /// show's output level under the operator.
    static let targetLufs: Double = -15.0
    static let minScopeSec: Double = 0.5     // intro shorter than this can't be measured
    static let minUsableRms: Double = 0.005  // near-silent range → fall back to whole song
    /// The LUFS equivalent of `minUsableRms` (0.005 ≈ −46 dBFS). Below this there is nothing
    /// for the audience to hear, so measuring the whole song is the better answer.
    static let minUsableLufs: Double = -46

    /// How much of the song Reveal counts as putting on air, for levelling. Reveal plays until
    /// the operator stops it, so there is no exact answer; 15 s is about one chorus, which is
    /// what Reveal exists to show.
    static let revealScopeSec: Double = 15
    /// Where Reveal aims. Deliberately the SAME as `targetLufs` today, so the reveal and the
    /// intro come out at one level — and kept as its own constant because "should the payoff be
    /// a few dB hotter than the question?" is a production decision, and this is the one number
    /// that answers it.
    static let revealTargetLufs: Double = -15.0

    // intro-start detection
    static let preRoll: Double = 0.25
    static let onsetWin: Double = 0.03
    static let onsetHold: Double = 0.06

    private(set) var env: [Float] = []       // peak per bucket, for drawing
    private(set) var sqPrefix: [Double] = [] // cumulative sum of squares → O(1) RMS
    private(set) var step: Int = 1           // frames per bucket
    /// The ACTUAL bucket rate, sampleRate/step — not the nominal `envHz`. 44100/round(44100/1000)
    /// = 1002.27 Hz, so indexing at a flat 1000 drifts 0.227%: half a second by minute four, which
    /// put the drawn waveform out of step with the playhead it is used to align markers against.
    private(set) var bucketHz: Double = Analysis.envHz
    private(set) var frameCount: Int = 0
    private(set) var globalPeak: Float = 1
    private(set) var duration: Double = 0
    private(set) var sampleRate: Double = 44100

    /// K-weighted mean square per 100 ms sub-block, summed over channels with BS.1770's weights.
    /// Gated LUFS for ANY range is computable from these without re-reading the file, which is
    /// what makes a per-marker-edit re-level affordable — the window moves every time a marker
    /// does. ~10 doubles a second: 21 KB for a four-minute song.
    private(set) var kBlocks: [Double] = []
    /// Peak magnitude ACROSS ALL CHANNELS per sub-block, aligned with `kBlocks`. `env` is
    /// channel 0 only (fine for drawing), but the gain is applied to every channel, so a
    /// hard-panned transient on the right was invisible to the headroom model — measured
    /// 1.41 dB low on song 106. 10 values a second: a few KB.
    private(set) var peakBlocks: [Float] = []
    /// The ACTUAL sub-block period, `kSubFrames / sampleRate`, not the nominal 0.1 s. Exactly
    /// 0.1 at 44.1/48/96 kHz, but `round(0.1 * 11025) = 1103` drifts 0.045% — the same class
    /// of bug §12 records for `bucketHz` indexing the envelope at a flat `envHz`.
    private(set) var kBlockSec: Double = Loudness.stepSec
    private(set) var channels: Int = 1

    private(set) var framesRead: Int = 0
    /// A failed first read still leaves sqPrefix allocated, which used to report "ready" and show
    /// a flat waveform with no error.
    var isReady: Bool { !sqPrefix.isEmpty && framesRead > 0 }

    /// One pass over the decoded file produces both the drawing envelope and the prefix sums.
    /// Reads in chunks so a long file never sits fully in memory.
    static func analyse(url: URL) throws -> Analysis {
        let a = Analysis()
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        a.sampleRate = fmt.sampleRate
        a.frameCount = Int(file.length)
        a.duration = Double(file.length) / fmt.sampleRate
        a.step = max(1, Int((fmt.sampleRate / envHz).rounded()))
        a.bucketHz = fmt.sampleRate / Double(a.step)

        // A corrupt header claiming a huge duration would otherwise pre-allocate ~12 bytes per
        // claimed millisecond and get the process killed.
        guard a.duration < 4 * 3600 else { throw Analysis.Failure.implausibleDuration }
        let n = max(1, Int((Double(a.frameCount) / Double(a.step)).rounded(.up)))
        a.env = [Float](repeating: 0, count: n)
        a.sqPrefix = [Double](repeating: 0, count: n + 1)

        a.channels = max(1, Int(fmt.channelCount))
        let kw = Loudness.kWeighting(rate: fmt.sampleRate)
        var kState = [Loudness.FilterState](repeating: .init(), count: a.channels)
        let kSubFrames = max(1, Int((Loudness.stepSec * fmt.sampleRate).rounded()))
        var kSum = [Double](repeating: 0, count: a.channels)
        var kCount = 0
        a.kBlockSec = Double(kSubFrames) / fmt.sampleRate
        a.kBlocks.reserveCapacity(Int(a.duration / a.kBlockSec) + 2)
        a.peakBlocks.reserveCapacity(Int(a.duration / a.kBlockSec) + 2)
        var kPeak: Float = 0

        let chunk = AVAudioFrameCount(1 << 18)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return a }

        var bucket = 0            // index of the bucket being filled
        var inBucket = 0          // frames accumulated into it
        var peak: Float = 0
        var sumSq: Double = 0
        var running: Double = 0
        var maxPeak: Float = 0

        // Read only what's left. `file.length` is an estimate for MP3, and asking for frames past
        // the end makes AVAudioFile throw nilError rather than returning a short buffer.
        var remaining = file.length
        while remaining > 0 {
            let want = AVAudioFrameCount(min(Int64(chunk), remaining))
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: want) } catch { break }
            let got = Int(buf.frameLength)
            if got == 0 { break }
            remaining -= Int64(got)
            a.framesRead += got
            guard let ch = buf.floatChannelData else { break }
            let left = ch[0]      // mono-equivalent: channel 0, same as the web version
            for i in 0..<got {
                // K-weighting runs over EVERY channel — BS.1770 sums channel powers, and the
                // envelope's channel-0 shortcut is fine for drawing but not for loudness.
                for c in 0..<a.channels {
                    let xf = ch[c][i]
                    let axf = xf < 0 ? -xf : xf
                    if axf > kPeak { kPeak = axf }
                    let x = Double(xf)
                    var st = kState[c]
                    let y = kw.shelf.b0 * x + kw.shelf.b1 * st.x1 + kw.shelf.b2 * st.x2
                            - kw.shelf.a1 * st.y1 - kw.shelf.a2 * st.y2
                    st.x2 = st.x1; st.x1 = x; st.y2 = st.y1; st.y1 = y
                    let z = kw.highpass.b0 * y + kw.highpass.b1 * st.u1 + kw.highpass.b2 * st.u2
                            - kw.highpass.a1 * st.v1 - kw.highpass.a2 * st.v2
                    st.u2 = st.u1; st.u1 = y; st.v2 = st.v1; st.v1 = z
                    kState[c] = st
                    kSum[c] += z * z
                }
                kCount += 1
                if kCount == kSubFrames {
                    var acc = 0.0
                    for c in 0..<a.channels {
                        acc += Loudness.channelWeight(c, of: a.channels) * (kSum[c] / Double(kCount))
                    }
                    a.kBlocks.append(acc)
                    a.peakBlocks.append(kPeak)
                    kPeak = 0
                    for c in 0..<a.channels { kSum[c] = 0 }
                    kCount = 0
                }

                let v = left[i]
                let av = v < 0 ? -v : v
                if av > peak { peak = av }
                sumSq += Double(v) * Double(v)
                inBucket += 1
                if inBucket == a.step {
                    if bucket < n {
                        a.env[bucket] = peak
                        running += sumSq
                        a.sqPrefix[bucket + 1] = running
                    }
                    if peak > maxPeak { maxPeak = peak }
                    bucket += 1; inBucket = 0; peak = 0; sumSq = 0
                }
            }
        }
        // trailing partial bucket
        if inBucket > 0 && bucket < n {
            a.env[bucket] = peak
            running += sumSq
            a.sqPrefix[bucket + 1] = running
            if peak > maxPeak { maxPeak = peak }
            bucket += 1
        }
        // any buckets we never reached keep the last running total so ranges stay monotonic
        if bucket < n {
            for i in (bucket + 1)...n { a.sqPrefix[i] = running }
        }
        a.globalPeak = maxPeak > 0 ? maxPeak : 1
        return a
    }

    /// RMS between two times, straight off the prefix sums.
    func rms(_ t0: Double, _ t1: Double) -> Double {
        guard !sqPrefix.isEmpty else { return 0 }
        let n = env.count
        guard t0.isFinite, t1.isFinite else { return 0 }
        let i0 = max(0, min(n, Int((t0 * bucketHz).rounded(.down))))
        let i1 = max(0, min(n, Int((t1 * bucketHz).rounded(.up))))
        if i1 <= i0 { return 0 }
        let count = min(frameCount, i1 * step) - i0 * step
        if count <= 0 { return 0 }
        return ((sqPrefix[i1] - sqPrefix[i0]) / Double(count)).squareRoot()
    }

    /// Where the music actually starts, or nil.
    ///
    /// Two stages, because one threshold cannot do this job — measured on the real library, song
    /// 103 carries 0.0118 of tape hiss in its first second while song 107's opening notes are only
    /// 0.0066. So: find a confident loud onset, then walk backwards while anything audible
    /// continues. The silence in front of the music is what stops the walk, which is how a quiet
    /// lead-in survives without hiss fooling it.
    func detectIntroStart() -> Double? {
        guard isReady, duration > 0 else { return nil }
        let ref = rms(0, duration)
        guard ref > 0 else { return nil }
        let stepT = 0.01
        let loudThr = max(ref * 0.08, 0.004)

        var onset = -1.0
        var holdFrom = -1.0
        var t = 0.0
        while t + Analysis.onsetWin <= duration {
            if rms(t, t + Analysis.onsetWin) > loudThr {
                if holdFrom < 0 { holdFrom = t }
                if t - holdFrom >= Analysis.onsetHold { onset = holdFrom; break }
            } else {
                holdFrom = -1
            }
            t += stepT
        }
        guard onset >= 0 else { return nil }

        let quietThr = max(loudThr * 0.12, 0.0025)
        var s = onset
        while s - stepT >= 0 && rms(max(0, s - Analysis.onsetWin), s) > quietThr { s -= stepT }
        return max(0, s - Analysis.preRoll)
    }

    /// Gated LUFS over a time range, from the sub-blocks built during analysis.
    func lufs(_ t0: Double, _ t1: Double) -> Double {
        guard !kBlocks.isEmpty, t1 > t0 else { return -.infinity }
        let i0 = max(0, min(kBlocks.count, Int((t0 / kBlockSec).rounded(.down))))
        let i1 = max(i0, min(kBlocks.count, Int((t1 / kBlockSec).rounded(.up))))
        guard i1 > i0 else { return -.infinity }
        return Loudness.gated(subBlocks: kBlocks[i0..<i1]).lufs
    }

    /// Highest sample magnitude in a range **across every channel** — what the limiter sees,
    /// because the gain is applied to all of them. Sample peak, not true peak: true peak needs
    /// oversampling and is always a little higher, so this is optimistic by a few tenths.
    func peakAllChannels(_ t0: Double, _ t1: Double) -> Float {
        guard !peakBlocks.isEmpty, t1 > t0 else { return 0 }
        let i0 = max(0, min(peakBlocks.count, Int((t0 / kBlockSec).rounded(.down))))
        let i1 = max(i0, min(peakBlocks.count, Int((t1 / kBlockSec).rounded(.up))))
        guard i1 > i0 else { return 0 }
        var m: Float = 0
        for i in i0..<i1 where peakBlocks[i] > m { m = peakBlocks[i] }
        return m
    }

    /// Channel 0 only, from the drawing envelope. Kept for anything that is about the drawn
    /// waveform; `peakAllChannels` is the one to use for headroom.
    func peak(_ t0: Double, _ t1: Double) -> Float {
        guard !env.isEmpty else { return 0 }
        let i0 = max(0, min(env.count, Int((t0 * bucketHz).rounded(.down))))
        let i1 = max(i0, min(env.count, Int((t1 * bucketHz).rounded(.up))))
        guard i1 > i0 else { return 0 }
        var m: Float = 0
        for i in i0..<i1 where env[i] > m { m = env[i] }
        return m
    }

    /// The loudness the auto-gain works from, with the same scope fallback as `measuredRms`.
    func measuredLufs(config c: SongConfig, scope: LoudnessScope) -> (lufs: Double, usedScope: LoudnessScope) {
        guard isReady, !kBlocks.isEmpty else { return (-.infinity, .song) }
        let whole = { (self.lufs(0, self.duration), LoudnessScope.song) }
        guard scope == .intro else { return whole() }
        let a = min(c.introStart, c.introEnd), b = max(c.introStart, c.introEnd)
        if b - a < Analysis.minScopeSec { return whole() }
        let v = lufs(a, b)
        // A silent lead-in would otherwise divide into the maximum boost. The old RMS path fell
        // back at 0.005 ≈ −46 dBFS; −70 LUFS (BS.1770's absolute BLOCK gate, for excluding
        // silence from an average) is not the same thing and loosened this safety net by ~24 dB.
        // An intro at −55 LUFS is inaudible, would ask for +40 dB, and would be clamped to +12
        // and crushed instead of falling back to the whole song.
        if !v.isFinite || v < Analysis.minUsableLufs { return whole() }
        return (v, .intro)
    }

    /// The stretch Reveal puts on air. Shared by the level measurement and the headroom check so
    /// the two cannot drift onto different windows — §7a3 records what it cost when the peak
    /// followed the measurement scope instead of what is played.
    func revealRange(config c: SongConfig) -> (Double, Double) {
        let h0 = min(max(0, c.hook), max(0, duration - 0.5))
        return (h0, min(duration, h0 + Analysis.revealScopeSec))
    }

    /// Reveal's own level, because Reveal plays the HOOK and the auto-gain is measured over the
    /// sparse intro. A pop master puts its loudest 15 seconds in the chorus, so a song whose
    /// quiet intro earned a boost was sending that boost out on camera.
    ///
    /// Measured on the real nine-song library before this existed: the songs' choruses sit
    /// within 9.93 LU of each other untouched (3.53 LU for eight of the nine — masters are
    /// already levelled), and applying the intro's gain to them widened that to **15.21 LU**,
    /// sd 2.82 → 5.02. Song 107's reveal landed at +0.86 LUFS — 15.9 LU over target — with the
    /// limiter clawing back 10.78 dB, so the reveal was simultaneously the loudest thing in the
    /// show and the most crushed. Normalising the intro de-normalised the one thing on camera.
    ///
    /// `scope == .song` is honoured and returns the whole-file figure: that setting means "one
    /// number for this file", so there is nothing to re-level.
    func revealLufs(config c: SongConfig, scope: LoudnessScope) -> (lufs: Double, windowed: Bool) {
        guard isReady, !kBlocks.isEmpty else { return (-.infinity, false) }
        let whole = { (self.lufs(0, self.duration), false) }
        guard scope == .intro else { return whole() }
        let (h0, h1) = revealRange(config: c)
        guard h1 - h0 >= Analysis.minScopeSec else { return whole() }
        let v = lufs(h0, h1)
        guard v.isFinite, v >= Analysis.minUsableLufs else { return whole() }
        return (v, true)
    }

    /// Which stretch the auto-gain is measured over. Intro-scoped by default: the GM only plays the
    /// intro, and whole-song averaging systematically under-boosts songs with a soft intro.
    func measuredRms(config c: SongConfig, scope: LoudnessScope) -> (rms: Double, usedScope: LoudnessScope) {
        guard isReady else { return (0, .song) }
        let whole = { (self.rms(0, self.duration), LoudnessScope.song) }
        guard scope == .intro else { return whole() }
        let a = min(c.introStart, c.introEnd), b = max(c.introStart, c.introEnd)
        if b - a < Analysis.minScopeSec { return whole() }
        let r = rms(a, b)
        if !(r > Analysis.minUsableRms) { return whole() }
        return (r, .intro)
    }

    /// Cache key: the view window plus the canvas width, exactly like the web version's
    /// `rebuildCols` early-return. Without it every Canvas render walked the whole envelope again —
    /// CLAUDE.md §8b calls this cache "what keeps the draw loop cheap", and it had not been ported.
    private var colCache: [Float] = []
    private var colKey: String = ""

    /// Peak per pixel column for a view window, normalised against the whole-song peak so a quiet
    /// passage doesn't balloon to full height when you zoom into it.
    func columnPeaks(viewStart: Double, viewEnd: Double, width: Int) -> [Float] {
        guard width > 0, !env.isEmpty else { return [] }
        let key = "\(width)|\(viewStart)|\(viewEnd)"
        if key == colKey { return colCache }
        var out = [Float](repeating: 0, count: width)
        let span = max(1e-4, viewEnd - viewStart)
        for x in 0..<width {
            var i0 = Int(((viewStart + Double(x) / Double(width) * span) * bucketHz).rounded(.down))
            var i1 = Int(((viewStart + Double(x + 1) / Double(width) * span) * bucketHz).rounded(.up))
            if i1 <= i0 { i1 = i0 + 1 }
            i0 = max(0, i0); i1 = min(env.count, i1)
            var m: Float = 0
            var i = i0
            while i < i1 { if env[i] > m { m = env[i] }; i += 1 }
            out[x] = m / globalPeak
        }
        colKey = key
        colCache = out
        return out
    }

    private var ovCache: [Float] = []
    private var ovWidth = 0

    /// Peaks for the whole song, for the overview strip.
    ///
    /// This needs its OWN cache. `columnPeaks` keeps a single entry keyed on the view window, so
    /// having the strip ask it for `0..duration` while the main waveform asks for a zoomed window
    /// would make the two evict each other and re-walk the entire envelope **twice per frame** —
    /// the exact cost the column cache exists to avoid. The strip's window never changes, so
    /// width alone is a sufficient key.
    func overviewPeaks(width: Int) -> [Float] {
        guard width > 0, !env.isEmpty else { return [] }
        if width == ovWidth, !ovCache.isEmpty { return ovCache }
        // Same indexing as `columnPeaks` over 0..duration — floor/ceil on bucketHz, not a
        // proportional split of env.count. Proportional division drops the bucket each column
        // shares with the next, which cost up to 0.17 of normalised peak at a transient: the strip
        // and a zoomed-out waveform drew visibly different shapes for the same audio.
        var out = [Float](repeating: 0, count: width)
        let span = max(1e-4, duration)
        for x in 0..<width {
            var i0 = Int((Double(x) / Double(width) * span * bucketHz).rounded(.down))
            var i1 = Int((Double(x + 1) / Double(width) * span * bucketHz).rounded(.up))
            if i1 <= i0 { i1 = i0 + 1 }
            i0 = max(0, i0); i1 = min(env.count, i1)
            var m: Float = 0
            var i = i0
            while i < i1 { if env[i] > m { m = env[i] }; i += 1 }
            out[x] = m / globalPeak
        }
        ovWidth = width
        ovCache = out
        return out
    }
}
