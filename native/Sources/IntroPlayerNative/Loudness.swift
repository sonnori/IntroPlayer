import AVFoundation
import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness, measured over one time range of one file.
///
/// Why this exists alongside `Analysis.rms`: un-weighted RMS answers "how much energy is in this
/// audio", and the question the auto-gain is actually asking is "how loud does this sound". Those
/// differ most on exactly the material a song intro is made of — a sparse arrangement with a
/// synth bass or a kick carries energy at frequencies the ear discounts heavily, so RMS reports
/// it as loud and boosts it too little. K-weighting is the measured answer to that: a high-shelf
/// plus a high-pass that approximate the ear's response, then an energy mean over 400 ms blocks
/// with the quiet ones gated out so a lead-in cannot drag the figure down.
///
/// `Analysis` keeps its RMS prefix sums — they are O(1) per query and that is what the waveform
/// and the intro-onset detector need. This is the separate, slower, per-range measurement.
enum Loudness {

    // MARK: - result

    struct Result {
        /// Gated loudness in LUFS. `-inf` for digital silence.
        let lufs: Double
        /// 400 ms blocks that survived both gates.
        let blocks: Int
        /// True when the range was long enough to gate properly. Three 400 ms blocks need six
        /// 100 ms sub-blocks, i.e. **0.6 s** — not the 1.2 s this used to claim. Below that the
        /// relative gate is meaningless and the figure falls back to an ungated energy mean.
        /// `Analysis.minScopeSec` is 0.5, so the band that actually takes it is 0.5–0.6 s.
        let gated: Bool
        /// Max |sample| across every channel, linear. This is SAMPLE peak, not true peak — true
        /// peak needs 4x oversampling and is always >= this, so treating it as a headroom figure
        /// is optimistic by a few tenths of a dB.
        let samplePeak: Double
        /// Un-weighted RMS of channel 0 — what the app measures today.
        let rmsChannel0: Double
        /// Un-weighted RMS across every channel as a POWER mean, sqrt(mean over channels of
        /// mean(x^2)). Phase-insensitive, which is the point: a coherent (L+R)/2 downmix reads
        /// several dB low on a wide stereo mix purely from cancellation, so it would blame the
        /// channel count for an error that is really phase. BS.1770 sums channel powers for the
        /// same reason.
        let rmsPower: Double
        /// Coherent (L+R)/2 downmix RMS. Kept only to show how far phase alone moves the figure.
        let rmsDownmix: Double
        /// K-weighted but UNGATED energy mean, in LUFS. The middle rung between un-weighted RMS
        /// and full BS.1770, so the diagnostic can say how much of the improvement is the
        /// weighting and how much is the gate.
        let lufsUngated: Double

        var peakDbfs: Double { samplePeak > 0 ? 20 * log10(samplePeak) : -.infinity }
    }

    // MARK: - the K-weighting filter

    struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    }

    /// BS.1770 tabulates the coefficients at 48 kHz only. Our library is 44.1 kHz MP3, so they
    /// have to be re-derived from the analog prototype for the file's actual rate — using the
    /// 48 kHz table at 44.1 kHz shifts both corner frequencies ~9% and is a silent error.
    /// `Diagnostics.loudTest` asserts this derivation reproduces the published table at 48 kHz.
    static func kWeighting(rate: Double) -> (shelf: Biquad, highpass: Biquad) {
        // stage 1 — high-shelf, +4 dB above ~1.5 kHz (the head's acoustic response)
        let fShelf = 1681.974450955533
        let gainDb = 3.999843853973347
        let qShelf = 0.7071752369554196
        var k = tan(.pi * fShelf / rate)
        let vh = pow(10.0, gainDb / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / qShelf + k * k
        let shelf = Biquad(b0: (vh + vb * k / qShelf + k * k) / a0,
                           b1: 2.0 * (k * k - vh) / a0,
                           b2: (vh - vb * k / qShelf + k * k) / a0,
                           a1: 2.0 * (k * k - 1.0) / a0,
                           a2: (1.0 - k / qShelf + k * k) / a0)

        // stage 2 — RLB high-pass at ~38 Hz, which is what discounts the sub-bass
        let fHp = 38.13547087602444
        let qHp = 0.5003270373238773
        k = tan(.pi * fHp / rate)
        let d = 1.0 + k / qHp + k * k
        let highpass = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                              a1: 2.0 * (k * k - 1.0) / d,
                              a2: (1.0 - k / qHp + k * k) / d)
        return (shelf, highpass)
    }

    /// Per-channel filter state for the two-stage cascade.
    struct FilterState {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0   // stage 1
        var u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0   // stage 2
    }

    // MARK: - measurement

    static let blockSec = 0.400
    static let stepSec = 0.100          // 75% overlap, per BS.1770
    static let absoluteGate = -70.0     // LUFS
    static let relativeGate = -10.0     // LU below the ungated mean

    /// Channel weights from BS.1770-4 table 3: L/R/C are 1.0, the surrounds +1.5 dB (1.41),
    /// and **LFE is excluded entirely**.
    ///
    /// The previous `i >= 3 ? 1.41 : 1.0` got both wrong for the layouts it claimed to cover:
    /// in 5.1 it gave the LFE — usually the hottest channel — a +1.5 dB weight instead of
    /// zero, so loudness over-reported, the auto-gain under-boosted and the song went out
    /// quiet; in quad it weighted Ls at 1.0 and Rs at 1.41. An unknown layout now gets 1.0
    /// across the board, which is the honest answer rather than a guess at channel order.
    static func channelWeight(_ i: Int, of total: Int) -> Double {
        switch total {
        case 6:                              // L R C LFE Ls Rs — LFE is EXCLUDED, not weighted
            if i == 3 { return 0 }
            return i >= 4 ? 1.41 : 1.0
        case 5:                              // L R C Ls Rs
            return i >= 3 ? 1.41 : 1.0
        default:
            return 1.0
        }
    }

    /// Gated loudness from pre-computed 100 ms sub-blocks (BS.1770's channel-weighted mean
    /// square per sub-block). This is the fast path `Analysis` uses: the gate is the same, only
    /// the source of the sub-blocks differs. `--loudtest` cross-checks it against `measure`,
    /// which re-reads the file — a reference implementation is only worth having if something
    /// actually compares against it.
    static func gated(subBlocks: ArraySlice<Double>) -> (lufs: Double, blocks: Int, gated: Bool) {
        let perBlock = max(1, Int((blockSec / stepSec).rounded()))
        func lkfs(_ ms: Double) -> Double { ms > 0 ? -0.691 + 10 * log10(ms) : -.infinity }
        let subs = Array(subBlocks)
        guard !subs.isEmpty else { return (-.infinity, 0, false) }
        var z = [Double]()
        if subs.count >= perBlock {
            for start in 0...(subs.count - perBlock) {
                var acc = 0.0
                for k in start..<(start + perBlock) { acc += subs[k] }
                z.append(acc / Double(perBlock))
            }
        }
        // Under 0.6 s there are fewer than 3 blocks and the relative gate is meaningless.
        if z.count < 3 {
            return (lkfs(subs.reduce(0, +) / Double(subs.count)), z.count, false)
        }
        let pass1 = z.filter { lkfs($0) > absoluteGate }
        guard !pass1.isEmpty else { return (-.infinity, 0, true) }
        let threshold = lkfs(pass1.reduce(0, +) / Double(pass1.count)) + relativeGate
        let pass2 = pass1.filter { lkfs($0) > threshold }
        let kept = pass2.isEmpty ? pass1 : pass2
        return (lkfs(kept.reduce(0, +) / Double(kept.count)), kept.count, true)
    }

    /// Measure `[from, to]` of a file. Returns nil only if the file cannot be opened.
    ///
    /// Streams in chunks and keeps one 100 ms sub-block sum per channel, so cost is linear in the
    /// measured range and memory is a few hundred doubles — a whole-song measurement of a 4½
    /// minute track is ~2700 sub-blocks.
    static func measure(url: URL, from: Double, to: Double) -> Result? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let rate = fmt.sampleRate
        guard rate > 0 else { return nil }
        let channels = Int(fmt.channelCount)
        guard channels > 0 else { return nil }

        let total = file.length
        let startFrame = max(0, min(total, Int64((from * rate).rounded())))
        let endFrame = max(startFrame, min(total, Int64((to * rate).rounded())))
        guard endFrame > startFrame else { return nil }
        file.framePosition = startFrame

        let (shelf, hp) = kWeighting(rate: rate)
        var state = [FilterState](repeating: FilterState(), count: channels)

        let subFrames = max(1, Int((stepSec * rate).rounded()))
        var subSums = [[Double]]()          // per sub-block, per channel: sum of squares (filtered)
        var subCounts = [Int]()
        var cur = [Double](repeating: 0, count: channels)
        var curCount = 0

        var peak = 0.0
        var rawSumSqAll = 0.0               // un-weighted, coherent (L+R) downmix
        var rawSumSqCh0 = 0.0
        var rawSumSqPerCh = [Double](repeating: 0, count: channels)  // un-weighted, per channel
        var frames = 0

        let chunk = AVAudioFrameCount(1 << 16)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        var remaining = endFrame - startFrame

        while remaining > 0 {
            let want = AVAudioFrameCount(min(Int64(chunk), remaining))
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: want) } catch { break }
            let got = Int(buf.frameLength)
            if got == 0 { break }
            remaining -= Int64(got)
            guard let ch = buf.floatChannelData else { break }

            for i in 0..<got {
                var summed = 0.0
                for c in 0..<channels {
                    let x = Double(ch[c][i])
                    let av = x < 0 ? -x : x
                    if av > peak { peak = av }
                    summed += x
                    if c == 0 { rawSumSqCh0 += x * x }
                    rawSumSqPerCh[c] += x * x

                    // stage 1
                    var s = state[c]
                    let y = shelf.b0 * x + shelf.b1 * s.x1 + shelf.b2 * s.x2
                            - shelf.a1 * s.y1 - shelf.a2 * s.y2
                    s.x2 = s.x1; s.x1 = x; s.y2 = s.y1; s.y1 = y
                    // stage 2
                    let v = hp.b0 * y + hp.b1 * s.u1 + hp.b2 * s.u2
                            - hp.a1 * s.v1 - hp.a2 * s.v2
                    s.u2 = s.u1; s.u1 = y; s.v2 = s.v1; s.v1 = v
                    state[c] = s

                    cur[c] += v * v
                }
                rawSumSqAll += summed * summed
                curCount += 1
                frames += 1
                if curCount == subFrames {
                    subSums.append(cur); subCounts.append(curCount)
                    cur = [Double](repeating: 0, count: channels)
                    curCount = 0
                }
            }
        }
        // A trailing partial sub-block is DISCARDED, not padded. Padding it with zeros would
        // report a quiet partial block and drag the gated mean down; BS.1770's block grid simply
        // does not cover the tail.
        guard frames > 0 else { return nil }

        let rmsDown = (rawSumSqAll / Double(frames)).squareRoot() / Double(channels)
        let rmsCh0 = (rawSumSqCh0 / Double(frames)).squareRoot()
        let rmsPow = (rawSumSqPerCh.reduce(0, +) / Double(channels) / Double(frames)).squareRoot()

        func lkfs(_ meanSquare: Double) -> Double {
            meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
        }

        // K-weighted energy mean over everything measured, no gating. Reported so the diagnostic
        // can separate "the weighting changed the answer" from "the gate changed the answer".
        var ungatedAcc = 0.0
        var ungatedFrames = 0
        for k in 0..<subSums.count { ungatedFrames += subCounts[k] }
        if ungatedFrames > 0 {
            for c in 0..<channels {
                var sum = 0.0
                for k in 0..<subSums.count { sum += subSums[k][c] }
                ungatedAcc += channelWeight(c, of: channels) * (sum / Double(ungatedFrames))
            }
        }
        let ungatedLufs = lkfs(ungatedAcc)

        // 400 ms blocks = 4 consecutive 100 ms sub-blocks, stepping one sub-block at a time.
        let perBlock = max(1, Int((blockSec / stepSec).rounded()))
        var z = [Double]()                  // weighted mean square per block
        if subSums.count >= perBlock {
            for start in 0...(subSums.count - perBlock) {
                var acc = 0.0
                var n = 0
                for k in start..<(start + perBlock) { n += subCounts[k] }
                guard n > 0 else { continue }
                for c in 0..<channels {
                    var s = 0.0
                    for k in start..<(start + perBlock) { s += subSums[k][c] }
                    acc += channelWeight(c, of: channels) * (s / Double(n))
                }
                z.append(acc)
            }
        }


        // Too short to gate: fall back to one ungated energy mean over everything measured. This
        // is the `minScopeSec` end of the range, where a gated figure would be built from one or
        // two blocks and would swing wildly.
        if z.count < 3 {
            return Result(lufs: ungatedLufs, blocks: z.count, gated: false,
                          samplePeak: peak, rmsChannel0: rmsCh0, rmsPower: rmsPow,
                          rmsDownmix: rmsDown, lufsUngated: ungatedLufs)
        }

        // gate 1 — absolute
        let pass1 = z.filter { lkfs($0) > absoluteGate }
        guard !pass1.isEmpty else {
            return Result(lufs: -.infinity, blocks: 0, gated: true,
                          samplePeak: peak, rmsChannel0: rmsCh0, rmsPower: rmsPow,
                          rmsDownmix: rmsDown, lufsUngated: ungatedLufs)
        }
        // gate 2 — relative to the ungated mean of what gate 1 kept
        let threshold = lkfs(pass1.reduce(0, +) / Double(pass1.count)) + relativeGate
        let pass2 = pass1.filter { lkfs($0) > threshold }
        let kept = pass2.isEmpty ? pass1 : pass2
        let mean = kept.reduce(0, +) / Double(kept.count)
        return Result(lufs: lkfs(mean), blocks: kept.count, gated: true,
                      samplePeak: peak, rmsChannel0: rmsCh0, rmsPower: rmsPow,
                      rmsDownmix: rmsDown, lufsUngated: ungatedLufs)
    }
}
