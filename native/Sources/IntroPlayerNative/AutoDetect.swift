import Accelerate
import AVFoundation
import Foundation

/// A first guess at where the intro ends and where the hook is, so a round does not open with
/// nine songs all claiming `hook: 60.00` — a number that came from nowhere and, for any song
/// shorter than a minute, used to send Reveal past the end of the file.
///
/// **This is a convenience, not an authority.** Everything it writes is stamped `auto`, which
/// keeps the song in the `Return`/`Tab` review sweep and in the pre-flight warnings until a
/// human confirms it. The bar it has to clear is "better than a constant", not "right".
///
/// Why it is a separate pass and not folded into `Analysis`: this costs an FFT over the whole
/// file, and `Analysis` runs every time the selection moves. Holding ↓ through a round must not
/// start a chromagram per song.
///
/// Accelerate is an Apple system framework, like AVFoundation — §2's "no third-party runtime
/// deps" is intact.
enum AutoDetect {

    // MARK: - features

    struct Features {
        /// L2-normalised 12-bin chroma, one vector per second.
        let chroma: [[Float]]
        /// Short-term loudness per second, dBFS-ish (20·log10 of RMS). `-inf` for silence.
        let loudness: [Double]
        let duration: Double
        var seconds: Int { min(chroma.count, loudness.count) }
    }

    static let windowSize = 16384          // ~0.37 s at 44.1 kHz — long enough to resolve pitch
    static let framesPerSecond = 4

    /// One pass over the file producing a 1 Hz chromagram and a 1 Hz loudness curve.
    ///
    /// **Cancellable, and it has to be.** ~0.25 s per song in release (~5 s in a debug build —
    /// do not read the figure off a debug diagnostic), with the whole file held as `[Float]`,
    /// ~45 MB for four minutes. Without cooperative checks, cancelling the task only
    /// discarded the RESULT, so holding ↓ through a 60-song round would start sixty
    /// concurrent five-second FFT passes. §12 records exactly that shape for the old
    /// uncancelled per-song decode.
    static func extract(url: URL) -> Features? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let rate = fmt.sampleRate
        let channels = Int(fmt.channelCount)
        guard rate > 0, channels > 0, file.length > 0 else { return nil }
        let duration = Double(file.length) / rate
        // 20 minutes, NOT `Analysis`'s 4 hours. That bound was copied across without noticing
        // the cost changed: `Analysis` keeps ~12 bytes per claimed millisecond, this holds the
        // whole file as `[Float]` — 176 KB per second, so a 4-hour file would reserve ~2.5 GB.
        // Nothing in a quiz round is 20 minutes long; a full-episode rip dropped into songs/ is
        // the realistic trigger and it should simply not get a guess.
        guard duration > 5, duration < 20 * 60 else { return nil }
        // …and cap the SAMPLES too. A bound on seconds is a bound on bytes at exactly one
        // sample rate: `mono` costs `duration x rate x 4` bytes, so the comment above is right
        // for 44.1 kHz and wrong by 4x at 192 kHz — measured, 19 minutes resident is 218 MB at
        // 44.1 kHz and ~876 MB at 192 kHz. 64e6 frames is ~256 MB of Float32 and sits ABOVE
        // 20 minutes at 44.1/48 kHz (52.9e6 / 57.6e6 frames), so no ordinary file changes
        // behaviour; it only catches the high-rate case the duration cap misses.
        guard file.length <= 64_000_000 else { return nil }

        // Mono mix, read in one streamed pass. A 4-minute track is ~42 MB of Float32 — the same
        // order as the decode `Analysis` already does and dropped immediately after.
        var mono = [Float]()
        mono.reserveCapacity(Int(file.length))
        let chunk = AVAudioFrameCount(1 << 18)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        var remaining = file.length
        while remaining > 0 {
            let want = AVAudioFrameCount(min(Int64(chunk), remaining))
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: want) } catch { break }
            let got = Int(buf.frameLength)
            if got == 0 { break }
            remaining -= Int64(got)
            guard let ch = buf.floatChannelData else { break }
            if Task.isCancelled { return nil }
            for i in 0..<got {
                var sum: Float = 0
                for c in 0..<channels { sum += ch[c][i] }
                mono.append(sum / Float(channels))
            }
        }
        if Task.isCancelled { return nil }
        guard mono.count > windowSize else { return nil }

        let hop = max(1, Int(rate) / framesPerSecond)
        let n = windowSize
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Pitch-class of every FFT bin, precomputed. Bins outside 80 Hz..5 kHz are dropped: below
        // that is bass fundamentals that smear across classes, above it is mostly cymbals.
        let binCount = n / 2
        var binClass = [Int](repeating: -1, count: binCount)
        for k in 1..<binCount {
            let f = Double(k) * rate / Double(n)
            guard f >= 80, f <= 5000 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            binClass[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var frameChroma = [[Float]]()
        var frameLoud = [Double]()
        var real = [Float](repeating: 0, count: binCount)
        var imag = [Float](repeating: 0, count: binCount)
        var mags = [Float](repeating: 0, count: binCount)
        var windowed = [Float](repeating: 0, count: n)

        var pos = 0
        var sinceCheck = 0
        while pos + n <= mono.count {
            // Every ~16 frames, i.e. ~4 s of audio — often enough that a cancel takes effect
            // inside a second, rare enough not to matter against an FFT.
            sinceCheck += 1
            if sinceCheck >= 16 {
                sinceCheck = 0
                if Task.isCancelled { return nil }
            }
            vDSP_vmul(Array(mono[pos..<(pos + n)]), 1, window, 1, &windowed, 1, vDSP_Length(n))

            var sumSq: Float = 0
            vDSP_measqv(Array(mono[pos..<(pos + n)]), 1, &sumSq, vDSP_Length(n))
            frameLoud.append(sumSq > 0 ? 10 * log10(Double(sumSq)) : -.infinity)

            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: binCount) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(binCount))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(binCount))
                    }
                }
            }

            var c = [Float](repeating: 0, count: 12)
            for k in 1..<binCount {
                let pc = binClass[k]
                if pc >= 0 { c[pc] += mags[k] }
            }
            frameChroma.append(c)
            pos += hop
        }
        guard !frameChroma.isEmpty else { return nil }

        // Average up to 1 Hz and L2-normalise. Normalising per SECOND rather than per frame is
        // deliberate: it makes the comparison about which notes are present, not how loud they
        // are, so a quiet reprise of the chorus still matches the loud one.
        var chroma = [[Float]]()
        var loud = [Double]()
        var i = 0
        while i < frameChroma.count {
            let j = min(i + framesPerSecond, frameChroma.count)
            var acc = [Float](repeating: 0, count: 12)
            for f in i..<j { for b in 0..<12 { acc[b] += frameChroma[f][b] } }
            // MEAN-CENTRE before normalising, so the dot product below is a correlation rather
            // than a plain cosine. Raw chroma is overwhelmingly positive and every section of a
            // pop song in one key points the same way: measured on the real library, every
            // candidate scored 1.41-1.44 and the "most repeated section" was really just the
            // loudest eight seconds. Centring is the whole difference between a repetition
            // detector and a loudness detector wearing its hat.
            var mean: Float = 0
            for b in 0..<12 { mean += acc[b] }
            mean /= 12
            for b in 0..<12 { acc[b] -= mean }
            var norm: Float = 0
            for b in 0..<12 { norm += acc[b] * acc[b] }
            norm = norm.squareRoot()
            if norm > 0 { for b in 0..<12 { acc[b] /= norm } }
            chroma.append(acc)

            // Bounded by `frameLoud`'s OWN count, not only by `frameChroma`'s. The two are
            // appended unconditionally in the same loop body today, so the counts are always
            // equal and `j` is safe — but this indexes one array with a bound derived from the
            // other, which is the exact shape that turns a future `continue` between those two
            // appends into an out-of-range crash. `Features.seconds` takes the `min` of the two
            // for the same reason, and cannot help here because this runs BEFORE it is built.
            var best = -Double.infinity
            for f in i..<min(j, frameLoud.count) where frameLoud[f] > best { best = frameLoud[f] }
            loud.append(best)
            i = j
        }
        return Features(chroma: chroma, loudness: loud, duration: duration)
    }

    // MARK: - intro end

    static let minIntroSec: Double = 8
    static let maxIntroSec: Double = 30
    /// How much louder, in dB, the music has to get to count as "the song proper has started".
    static let entryStepDb: Double = 3.0

    /// Where the question should stop. There is no musical truth here — the intro is how hard
    /// the GM wants to make it — so the target is the first clear step up in level after the
    /// start, which in practice is the beat or the vocal coming in, and the point past which
    /// the song stops being a guessing game.
    ///
    /// Clamped to 8..30 s from the start. The real library has one human-set intro of 38 s
    /// (202), so the clamp is a guess-bound, not a claim about what a GM may choose.
    static func introEnd(features f: Features, from rawStart: Double) -> Double {
        // **Do not trust the caller's start.** `Int(start.rounded())` below is a
        // `Int(_: Double)` conversion, which TRAPS — process death, SIGTRAP, exit 133 — for
        // any value >= 2^63 and for NaN. `start` arrives from `config.json` by way of
        // `store.config(for:)`, and that file is hand-editable and can be corrupted, so
        // `"introStart": 1e19` killed the app the moment that song was selected.
        //
        // `Store.decode` now clamps markers on load, which fixes it for every reader at once.
        // This is the second line of defence and not the only one, because a trap here is the
        // single most expensive failure this feature can produce and it costs one `min`.
        //
        // Note the NaN branch must come FIRST: Swift's 3-argument `min` is a left fold over
        // comparisons that are all false against NaN, so `min(nan, 1, 2)` is **nan** while
        // `min(1, nan, 2)` is 1.0 — and `fallback` below puts `start + 15` in exactly that
        // NaN-propagating first slot.
        let start = min(max(0, rawStart.isFinite ? rawStart : 0), max(0, f.duration))
        // Clamped INSIDE the song. `max(start + minIntroSec, duration - 1)` could exceed the
        // file: a 10 s song with `start = 5` returned 13 s. `play(from:)` clamps so nothing
        // plays past the end, but the value is written to config.json and the countdown reads it.
        let fallback = min(start + 15, max(start + minIntroSec, f.duration - 1), f.duration)
        let s = Int(start.rounded())
        guard f.seconds > s + Int(minIntroSec) + 2 else { return fallback }

        let lo = s + Int(minIntroSec)
        let hi = min(f.seconds - 3, s + Int(maxIntroSec))
        guard hi > lo else { return fallback }

        // Baseline = the level so far. A step is judged against what the intro has been doing,
        // not against an absolute, because these songs differ by 28 LU before normalisation.
        for t in lo..<hi {
            let before = mean(f.loudness, from: s, to: t)
            let after = mean(f.loudness, from: t, to: min(t + 4, f.seconds))
            if before.isFinite && after.isFinite && after - before >= entryStepDb {
                return Double(t)
            }
        }
        return fallback
    }

    // MARK: - hook

    static let segmentSec = 8
    /// Two sections closer together than this are the same section, not a repeat of it.
    static let minRepeatGapSec = 20
    /// Reveal has to REVEAL something. A hook sitting a couple of seconds past Intro End plays
    /// the audio the contestants just heard, so the guess is pushed at least this far past it.
    static let minAfterIntroSec = 8
    /// …and Reveal has to have song left to play into. Past this fraction the "most repeated
    /// loud section" is reliably the final chorus or the outro — measured: song 106 landed on
    /// 175 s of a 190 s track. Neither bound is a claim about music; both are about the verb.
    static let latestHookFraction = 0.75

    /// The most-repeated loud section — which for a pop song is the chorus.
    ///
    /// Scored on repetition FIRST and loudness second. Loudness alone picks the final chorus or
    /// a bridge climax; repetition alone can pick a verse pattern. Together they land on the
    /// part the audience would sing, which is what Reveal is for.
    /// How different the next few seconds are from the previous few — high where one section
    /// ends and another begins. A chorus starts at such a boundary, so this is both a way to
    /// place the guess precisely and the one objective quality signal available: a "chorus"
    /// found in the middle of a phrase is wrong whatever its repetition score.
    static func novelty(_ c: [[Float]], at t: Int, half: Int = 4) -> Double {
        guard t - half >= 0, t + half <= c.count else { return 0 }
        var dot: Float = 0
        for k in 0..<half {
            for d in 0..<12 { dot += c[t - half + k][d] * c[t + k][d] }
        }
        return 1 - Double(dot) / Double(half)
    }

    struct HookGuess {
        let time: Double
        let repetition: Double      // 0...1, correlation with its best-matching other section
        let loudness: Double        // 0...1 within the song's own range
        let onBoundary: Bool        // did it land on a section edge
    }

    static func hook(features f: Features, after: Double) -> HookGuess? {
        let n = f.seconds
        let seg = segmentSec
        guard n > seg * 3 else { return nil }
        let first = max(Int(after.rounded()) + minAfterIntroSec, 0)
        let last = min(n - seg - 2, Int(f.duration * latestHookFraction))
        guard last > first else { return nil }

        let loudVals = f.loudness.filter { $0.isFinite }
        guard let quiet = loudVals.min(), let peak = loudVals.max(), peak > quiet else { return nil }

        var rep = [Double](repeating: 0, count: last + 1)
        var bestT = first
        var bestScore = -Double.infinity
        for t in first...last {
            if Task.isCancelled { return nil }
            var r: Double = 0
            var u = 0
            while u <= last {
                if abs(u - t) >= minRepeatGapSec {
                    let s = similarity(f.chroma, t, u, seg)
                    if s > r { r = s }
                }
                u += 1
            }
            rep[t] = r
            let l = mean(f.loudness, from: t, to: t + seg)
            let loudNorm = l.isFinite ? (l - quiet) / (peak - quiet) : 0
            let score = r + 0.45 * loudNorm
            if score > bestScore { bestScore = score; bestT = t }
        }
        guard bestScore > -.infinity else { return nil }

        // The best-scoring window is often the LAST chorus — it is usually the loudest and has
        // the most earlier copies to match against. Reveal wants the first clean one: it is the
        // version the audience knows, and it leaves the rest of the song to play into. So walk
        // back to the earliest window that is the same section.
        var earliest = bestT
        var scan = first
        while scan < bestT {
            // 0.85 AND a boundary requirement — three conditions, because similarity alone
            // cannot carry this. Correlations across a whole song run 0.82-0.98, so the
            // threshold is working in a narrow band: at 0.80 the walk-back landed on the first
            // VERSE (songs 101 and 301 picked a hook three seconds after the intro ended), and
            // at 0.90 nothing earlier matched at all for song 106, which stayed on the final
            // chorus at 175 s of a 190 s track. `rep[scan]` keeps the earlier window from being
            // a one-off near-match, and `novelty` keeps it from starting mid-phrase.
            if similarity(f.chroma, scan, bestT, seg) >= 0.85 && rep[scan] >= rep[bestT] * 0.85
                && novelty(f.chroma, at: scan) > 0.20 {
                earliest = scan
                break
            }
            scan += 1
        }
        bestT = earliest

        // Snap to the section edge. The scoring window can settle a second or two inside the
        // chorus, and Reveal landing mid-phrase sounds like a mistake even when the section is
        // right. Search +-3 s for the strongest novelty peak.
        var snapped = bestT
        var bestNov = novelty(f.chroma, at: bestT)
        for d in -3...3 {
            let u = bestT + d
            guard u > first, u < last else { continue }
            let nv = novelty(f.chroma, at: u)
            if nv > bestNov { bestNov = nv; snapped = u }
        }
        let onBoundary = bestNov > 0.25
        bestT = snapped

        let l = mean(f.loudness, from: bestT, to: bestT + seg)
        return HookGuess(time: Double(bestT),
                         repetition: rep[min(bestT, rep.count - 1)],
                         loudness: l.isFinite ? (l - quiet) / (peak - quiet) : 0,
                         onBoundary: onBoundary)
    }

    // MARK: - helpers

    private static func similarity(_ c: [[Float]], _ a: Int, _ b: Int, _ len: Int) -> Double {
        // Lower bound as well as upper. `novelty` guards `t - half >= 0`; this had only the
        // upper half, so a negative `a` or `b` would index `c[a + k]` out of range. Not
        // reachable today — both call sites pass values at or above `hook`'s `first`, which is
        // itself `max(..., 0)` — but the asymmetry with its sibling is what makes that an
        // accident of one caller rather than a property of this function.
        guard a >= 0, b >= 0, len > 0, a + len <= c.count, b + len <= c.count else { return 0 }
        var dot: Float = 0
        for k in 0..<len {
            for d in 0..<12 { dot += c[a + k][d] * c[b + k][d] }
        }
        // Mean per second of a 12-dim dot product between unit-length vectors, so this is a
        // mean CORRELATION and its range is -1...1, not 0...1 — the vectors are mean-centred
        // above, which is exactly what buys the negative half and makes the measure
        // discriminating. Real music lands in 0.82-0.98, which is why the thresholds here sit
        // in such a narrow band; a reader who believes the range is 0...1 will think 0.85 is
        // a loose threshold when it is near the middle of the usable range.
        return Double(dot) / Double(len)
    }

    private static func mean(_ v: [Double], from: Int, to: Int) -> Double {
        let lo = max(0, from), hi = min(v.count, to)
        guard hi > lo else { return -.infinity }
        var sum = 0.0, n = 0
        for i in lo..<hi where v[i].isFinite { sum += v[i]; n += 1 }
        return n > 0 ? sum / Double(n) : -.infinity
    }
}
