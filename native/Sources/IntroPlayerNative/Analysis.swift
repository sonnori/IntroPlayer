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
    static let minScopeSec: Double = 0.5     // intro shorter than this can't be measured
    static let minUsableRms: Double = 0.005  // near-silent range → fall back to whole song

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
}
