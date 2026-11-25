import AVFoundation
import Foundation

/// Playback intent. Decides whether the intro-end auto-stop applies — the app's core requirement
/// is that playback must never run past Intro End except on a deliberate Reveal.
enum PlayMode {
    case idle, intro, reveal, free

    var chipText: String {
        switch self {
        case .reveal:  return "● เล่นเฉลย / Hook"
        case .free:    return "● เล่นต่อ (ไม่หยุดเอง)"
        default:       return "● เล่น Intro"
        }
    }
}

final class Player: ObservableObject {
    static let fadeSec: Double = 0.4

    @Published private(set) var isPlaying = false
    @Published private(set) var mode: PlayMode = .idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var gainDb: Double = 0
    /// What Reveal will play at. Separate from `gainDb` because they are measured over
    /// different stretches of the song — see `Analysis.revealLufs`. The level card shows both.
    @Published private(set) var revealGainDb: Double = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 0)     // globalGain is our level control (dB)
    private let limiter: AVAudioUnitEffect
    private var file: AVAudioFile?
    private var seekOffset: Double = 0
    private var pausedAt: Double = 0
    /// Last frame handed to scheduleSegment. play() bounds the segment at Intro End, so moving the
    /// marker outward has to re-schedule — the node has nothing beyond this to render.
    private var scheduledEndFrame: AVAudioFramePosition = 0
    private var engineReady = false

    /// Fade state. The fade is offset so silence lands exactly on Intro End — it starts at
    /// `introEnd - fadeSec`, never after, so audio never plays past the intro range.
    private var fading = false
    private var fadeFrom: Double = 0
    private var fadeStartHost: CFTimeInterval = 0
    private var fadeDur: Double = 0
    private var fadeEndAt: Double = 0
    private var baseGainDb: Double = 0
    /// The level for `.reveal`, held here so `reveal()` and `play(from:)` can apply it without
    /// needing the Analysis — `applyGain` already runs at every moment either figure can change.
    private var revealBaseGainDb: Double = 0

    private var guardTimer: Timer?
    private var activity: NSObjectProtocol?

    /// Called when the intro-end guard stops playback, so the UI can settle.
    var onAutoStop: (() -> Void)?
    /// Called when the audio engine cannot start or dies — must reach the operator, not a log.
    var onEngineFailure: ((String) -> Void)?
    /// Fires on every guard tick while playing. This is the app's only reliable heartbeat: a
    /// Timer.publish owned by a SwiftUI view is recreated on each publish and starves.
    var onTick: (() -> Void)?
    /// Supplies the live config for the current song (introEnd / ignoreEnd).
    var configProvider: (() -> SongConfig)?

    init() {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = kAudioUnitSubType_PeakLimiter
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        limiter = AVAudioUnitEffect(audioComponentDescription: desc)
        // Attack, release, pre-gain — CLAMPED TO THE UNIT'S OWN REPORTED RANGE. The release
        // was 0.120 s against a reported maximum of 0.040, and the AUParameter bridge does not
        // clamp: the value read back as 0.1200 and the resulting behaviour is undefined and
        // OS-version dependent. The ranges are queried rather than hardcoded because they are
        // not the ones in the SDK header's comment on this machine.
        func setParam(_ addr: AUParameterAddress, _ want: AUValue) {
            guard let p = limiter.auAudioUnit.parameterTree?.parameter(withAddress: addr) else { return }
            p.value = min(max(want, p.minValue), p.maxValue)
        }
        setParam(0, 0.003)   // attack
        setParam(1, 0.040)   // release — the unit's maximum; 0.120 was out of spec
        setParam(2, -1.0)    // pre-gain

        engine.attach(node); engine.attach(eq); engine.attach(limiter)
        // Keep the Mac awake for as long as the app runs — this is what `caffeinate` did for the
        // shell launcher, but scoped to the process so nothing can be left behind.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Running a taping")
    }

    /// Silences the output without touching the gain path — for headless tests only.
    func muteForTest() { engine.mainMixerNode.outputVolume = 0 }

    // MARK: - loading

    func load(url: URL) {
        stopEverything()
        guard let f = try? AVAudioFile(forReading: url) else { file = nil; duration = 0; return }
        file = f
        duration = Double(f.length) / f.processingFormat.sampleRate
        let fmt = f.processingFormat
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(limiter)
        engine.connect(node, to: eq, format: fmt)
        engine.connect(eq, to: limiter, format: fmt)
        engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
        engineReady = true
        seekOffset = 0; pausedAt = 0; position = 0
        mode = .idle
        node.volume = 1
        // Never carry the previous song's gain into this one — a +12 dB track followed by a loud
        // master went out 12 dB hot if Start was pressed before analysis finished.
        baseGainDb = 0
        revealBaseGainDb = 0
        eq.globalGain = 0
    }

    private func startEngineIfNeeded() {
        guard engineReady, !engine.isRunning else { return }
        try? engine.start()
    }

    // MARK: - level

    /// What `applyGain` worked out. `limiterEats` is the part of the figure the output limiter
    /// will take back, and it exists because the gain used to be computed with no reference to
    /// the audio's peak at all — so the two quietest intros in the real library, the ones this
    /// feature exists for, asked for more than fitted under the brick wall and got squashed
    /// instead of raised. Measured: song 107 asked +12.0 dB with +0.5 dB of headroom.
    struct Level {
        var db: Double                 // what is actually applied (auto + trim)
        var usedScope: LoudnessScope?
        var limiterEats: Double        // dB of `db` the limiter will claw back; 0 when it fits
        var headroomDb: Double         // dB available before the -1 dBFS wall
        var revealDb: Double           // what Reveal will play at, measured over the hook
        var revealLimiterEats: Double  // the same claw-back figure for the hook
    }

    /// The level for the stretch a given mode actually plays.
    ///
    /// Only Reveal gets its own figure, and that asymmetry is deliberate: a seek can land
    /// anywhere, so re-deriving the level from wherever the playhead stopped would change the
    /// loudness under the operator's hand on every waveform click — constant during marker work,
    /// and with no cut to hide it. Reveal is one jump to one fixed place, so the level change is
    /// masked by the jump it already makes. `.free` therefore keeps the intro's level: it is a
    /// setup state, not an on-camera verb.
    private func levelDb(for m: PlayMode) -> Double {
        m == .reveal ? revealBaseGainDb : baseGainDb
    }

    private func applyLevel() {
        if !fading { eq.globalGain = Float(max(-96, min(24, levelDb(for: mode)))) }
    }

    /// Combined auto-normalise + per-song trim, applied as one dB figure.
    ///
    /// Measures **gated LUFS** (BS.1770-4) over the intro, not un-weighted RMS. Measured across
    /// the real nine-song library, the RMS version left 2.6 LU of spread in what the audience
    /// hears; targeting LUFS closes it. RMS over-weights bass energy, which is exactly what a
    /// sparse intro is made of.
    func applyGain(analysis: Analysis?, config c: SongConfig, normalize: Bool, scope: LoudnessScope)
        -> Level {
        var autoDb: Double = 0
        var revealAutoDb: Double = 0
        var used: LoudnessScope?
        var headroom = Double.infinity
        var revealHeadroom = Double.infinity
        if let a = analysis, a.isReady {
            if normalize {
                let m = a.measuredLufs(config: c, scope: scope)
                used = m.usedScope
                if m.lufs.isFinite {
                    autoDb = min(max(Analysis.targetLufs - m.lufs, -12), 12)   // same ±12 clamp
                }
                // Reveal plays the hook, not the intro. Same clamp, its own window and its own
                // target — see `Analysis.revealLufs` for what applying the intro's figure here
                // measured on the real library.
                let r = a.revealLufs(config: c, scope: scope)
                if r.lufs.isFinite {
                    revealAutoDb = min(max(Analysis.revealTargetLufs - r.lufs, -12), 12)
                }
            }
            // ALWAYS the intro range, never the measurement scope. The limiter acts on what is
            // PLAYED, and that is the intro whatever the gain was measured over — following
            // `used` meant a `.song` scope took the peak from a mastered track's ~0 dBFS
            // maximum and reported every song as squashed.
            let lo = min(c.introStart, c.introEnd)
            let hi = max(c.introStart, c.introEnd)
            let pk = Double(hi > lo ? a.peakAllChannels(lo, hi) : 0)
            if pk > 0 { headroom = Player.limiterCeilingDb - 20 * log10(pk) }
            // The hook's own headroom, on the hook's own window — the same rule as above, for
            // the same reason: the limiter acts on what is PLAYED.
            let (r0, r1) = a.revealRange(config: c)
            let rpk = Double(r1 > r0 ? a.peakAllChannels(r0, r1) : 0)
            if rpk > 0 { revealHeadroom = Player.limiterCeilingDb - 20 * log10(rpk) }
        }
        // `min(24, nan)` returns 24 — Swift's min yields its first argument when the second is
        // NaN — so a non-finite total would apply the MAXIMUM +24 dB to live playback. Every
        // other guard in this file fails closed; this one failed wide open.
        let raw = autoDb + c.trimDb
        let total = raw.isFinite ? raw : 0
        baseGainDb = total
        // Trim is a human decision about the SONG, so it applies to both stretches. With
        // normalize off both figures collapse to the trim and Reveal behaves exactly as before.
        let rawReveal = revealAutoDb + c.trimDb
        revealBaseGainDb = rawReveal.isFinite ? rawReveal : 0
        applyLevel()
        gainDb = total
        revealGainDb = revealBaseGainDb
        // NOT capped. A brief transient meeting a brick wall is what a limiter is for, and
        // silently lowering what goes on air is not ours to decide — §15's "fail visible, not
        // shut". The figure is surfaced instead, in the level card and in the pre-flight.
        let eats = headroom.isFinite ? max(0, total - headroom) : 0
        let revealEats = revealHeadroom.isFinite ? max(0, revealBaseGainDb - revealHeadroom) : 0
        return Level(db: total, usedScope: used, limiterEats: eats,
                     headroomDb: headroom.isFinite ? headroom : 0,
                     revealDb: revealBaseGainDb, revealLimiterEats: revealEats)
    }

    /// Where limiting actually begins, in nominal dBFS (input + applied gain).
    ///
    /// **`kLimiterParam_PreGain` is not a threshold**, which is the trap this constant used to
    /// fall into. Measured by rendering the real graph offline and sweeping it: output is
    /// exactly `input + gain − 1.0 dB` right up to a nominal **+1.0 dBFS**, where limiting
    /// starts. So the pre-gain is a flat 1 dB attenuation, and the knee is at +1, not −1.
    ///
    /// Getting this wrong overstated every `limiterEats` figure by exactly 2 dB — enough to
    /// raise the `squashedIntro` pre-flight warning on song 102, whose true figure is 1.42 dB
    /// against a 2.0 dB threshold, i.e. a warning fired at a song the limiter never touches.
    /// §12 already records that lesson once, under `previewArmed`.
    static let limiterCeilingDb: Double = 1.0

    // MARK: - transport

    /// The single rule for "what does playing from here mean?" — used by both Start and
    /// click-to-seek so the two can't drift apart.
    static func modeForPosition(_ t: Double, _ c: SongConfig) -> PlayMode {
        (t < c.introEnd - 0.02 || c.ignoreEnd) ? .intro : .free
    }

    /// Start never rewinds: it plays from wherever the playhead is. Reset is the one thing that
    /// returns to Intro Start.
    func toggleStart(config c: SongConfig) {
        if isPlaying || fading {
            cancelFade()
            pause()
            return
        }
        cancelFade()
        mode = Player.modeForPosition(position, c)
        play(from: position)
    }

    func testIntro(config c: SongConfig) {
        cancelFade()
        mode = .intro
        play(from: c.introStart)
    }

    func reveal(config c: SongConfig) {
        cancelFade()
        mode = .reveal
        // A hook past the end schedules zero frames and Reveal goes silent on camera; the default
        // is 60 s, so every song shorter than that is exposed until the GM sets one.
        let h = min(max(0, c.hook), max(0, duration - 0.5))
        play(from: h)
    }

    func reset(config c: SongConfig) {
        cancelFade()
        pause()
        seek(to: c.introStart, config: c)
        mode = .idle
    }

    /// Seeking is deliberate, so while playing it re-derives the mode for where we landed — that
    /// is what lets the GM jump past Intro End mid-playback without ticking Ignore Intro End.
    func seek(to t: Double, config c: SongConfig) {
        cancelFade()          // a click during the intro-end fade means "keep going", not "stop"
        let clamped = max(0, min(duration, t))
        if isPlaying {
            // Mode FIRST. `play(from:)` reads `mode` to decide where to bound the segment, so
            // assigning after it meant a seek during a hook audition was still scheduled against
            // `previewEnd`: seeking past it gives `frames == 0`, and the `pause()` on that path
            // runs after `node.stop()` — verbatim the §12 defect where the playhead jumped back
            // to the previous pause. Every other caller already sets mode first.
            mode = Player.modeForPosition(clamped, c)
            play(from: clamped)
        } else {
            pausedAt = clamped
            seekOffset = clamped
            position = clamped
        }
    }

    private func play(from t: Double) {
        guard let f = file else { return }
        startEngineIfNeeded()
        guard engine.isRunning else {     // a dead engine makes node.play() a silent no-op
            isPlaying = false
            onEngineFailure?("เปิดเครื่องเสียงไม่สำเร็จ — ลองเลือกเพลงใหม่อีกครั้ง")
            return
        }
        node.stop()                       // resets the node clock; seekOffset carries the origin
        let sr = f.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(duration, t)) * sr)
        // Schedule only as far as the intro is allowed to run. The timer guard still drives the
        // fade, but it is no longer the ONLY thing between the GM and the whole song playing out:
        // the node simply has nothing left to render past Intro End.
        var endFrame = f.length
        if mode == .intro, let c = configProvider?(), !c.ignoreEnd, c.introEnd > c.introStart {
            endFrame = min(endFrame, AVAudioFramePosition(min(duration, c.introEnd) * sr))
        }
        let frames = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frames > 0 else { pause(); return }
        seekOffset = Double(startFrame) / sr
        scheduledEndFrame = endFrame
        node.scheduleSegment(f, startingFrame: startFrame, frameCount: frames, at: nil,
                             completionHandler: nil)
        // Restore the level after any fade — for the mode being played, not unconditionally the
        // intro's. Every transport verb assigns `mode` before calling this (§12: a seek that
        // assigned it afterwards was a real defect), so `reveal()` needs nothing of its own.
        eq.globalGain = Float(max(-96, min(24, levelDb(for: mode))))
        node.play()
        isPlaying = true
        position = seekOffset
        startGuard()
    }

    /// Re-apply a changed config to live playback. Only matters because play() bounds the scheduled
    /// segment at Intro End: dragging the marker out, or ticking Ignore Intro End, while the intro
    /// is playing would otherwise still stop dead at the old boundary.
    func remode(config c: SongConfig) {
        guard isPlaying, !fading, let f = file else { return }
        // Reveal must stay Reveal — a hook nudge mustn't silently re-arm the intro guard.
        guard mode == .intro || mode == .free else { return }
        let p = livePosition()
        // A marker edit may only ARM the intro-end guard, never disarm it.
        //
        // Assigning `modeForPosition` unconditionally here was a core-requirement violation.
        // Pulling Intro End back BEHIND the playhead — one typed value, or one drag — made the
        // new mode `.free`, which skipped the `mode == .intro` bound below, left `want` at
        // `f.length`, and then passed the "moved outward" test against the OLD boundary. The node
        // was rescheduled to the end of the file and **the whole song played out on camera**:
        // shortening the intro made playback longer.
        //
        // A seek is a transport command and keeps re-deriving freely (§10). A marker edit is not
        // one — the operator typed in a setup field, they did not ask to hear past the intro.
        // Holding `.intro` lets `tick()` do the right thing instead: it sees the playhead already
        // past the new Intro End, and `beginFade`'s "already late" branch cuts immediately.
        let next = Player.modeForPosition(p, c)
        if next == .intro { mode = next }
        let sr = f.processingFormat.sampleRate
        var want = f.length
        if mode == .intro, !c.ignoreEnd, c.introEnd > c.introStart {
            want = min(want, AVAudioFramePosition(min(duration, c.introEnd) * sr))
        }
        // Only when the boundary moved OUT. Pulling it in needs nothing: the guard fades at the
        // new, earlier Intro End, and re-scheduling would click for no reason.
        if want > scheduledEndFrame + AVAudioFramePosition(0.05 * sr) { play(from: p) }
    }

    /// Will the scheduled segment run out BEFORE the Intro End the config now holds, with the
    /// playhead close enough for that to be heard?
    ///
    /// The window this exists to close. `AppModel.nudgeFocused` writes with
    /// `updateConfig(commit: false)` and a 350 ms debounce, deliberately: committing per
    /// keypress calls `remode`, which re-schedules the node and clicks. But `←`/`→` are the one
    /// pair exempt from the app-wide autorepeat suppression — §11, because 0.01 s per press
    /// means a held key has to work or the feature does not exist — and autorepeat arrives
    /// roughly every 30 ms, so a HELD key re-arms that debounce before it can ever fire.
    /// `remode` therefore never ran: the node stayed bounded at the OLD Intro End, the audio
    /// stopped there, and the guard strip went on counting down to the new value while the
    /// button still read Pause. On camera that is indistinguishable from a hang.
    ///
    /// **Not a §10 violation** — nothing plays past Intro End, so the core requirement held
    /// throughout. It is a dropout, and it happened during the exact task the key exists for:
    /// listening for the cut while moving it.
    ///
    /// Read-only by construction. It schedules nothing and changes no state; the caller decides
    /// whether to commit, and `remode` re-derives everything for itself when it does.
    func boundRunsOutEarly(config c: SongConfig) -> Bool {
        // `.free` and `.reveal` are not bounded by Intro End, so nothing can run out early;
        // `.fading` means the cut has already begun and `remode` would decline anyway.
        guard isPlaying, !fading, let f = file, mode == .intro else { return false }
        guard !c.ignoreEnd, c.introEnd > c.introStart else { return false }
        let sr = f.processingFormat.sampleRate
        let want = min(f.length, AVAudioFramePosition(min(duration, c.introEnd) * sr))
        // The same 0.05 s hysteresis `remode` applies, so this can never answer "commit" to a
        // `remode` that then declines to re-schedule.
        guard want > scheduledEndFrame + AVAudioFramePosition(0.05 * sr) else { return false }
        // Only once the playhead is actually approaching the stale bound. Holding the key with
        // twenty seconds still to run must keep coalescing into ONE commit on release, or this
        // trades silence for a re-schedule every 350 ms. The lead is the fade length because
        // the cut begins at `introEnd - fadeSec` — deciding later than that is deciding too
        // late to be silent about it.
        return livePosition() + Player.fadeSec >= Double(scheduledEndFrame) / sr
    }

    func pause() {
        // Read the playhead BEFORE stopping: playerTime(forNodeTime:) returns nil the moment the
        // node stops, so livePosition() would fall through to the stale `pausedAt` and assign it
        // to itself — the playhead jumped back to the previous pause/seek on every buzz.
        let now = livePosition()
        node.pause()
        pausedAt = now
        position = now
        isPlaying = false
        stopGuard()
    }

    private func stopEverything() {
        cancelFade(); stopGuard()
        node.stop()
        isPlaying = false
    }

    private func livePosition() -> Double {
        guard node.isPlaying else { return pausedAt }
        if let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), pt.sampleRate > 0 {
            return seekOffset + Double(pt.sampleTime) / pt.sampleRate
        }
        return pausedAt
    }

    // MARK: - intro-end guard

    /// A timer, not a display link. The web version learned this the hard way: anything tied to
    /// frame callbacks stops when the window is backgrounded, and the intro would run into the
    /// song. This must keep firing regardless of what is on screen.
    private func startGuard() {
        stopGuard()
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        guardTimer = t
    }
    private func stopGuard() { guardTimer?.invalidate(); guardTimer = nil }

    private func tick() {
        guard isPlaying || fading else { return }
        position = livePosition()
        onTick?()

        if fading {
            let el = CACurrentMediaTime() - fadeStartHost
            let k = fadeDur > 0 ? min(1, el / fadeDur) : 1
            // Linear in AMPLITUDE, like the web original. Ramping dB sounds like an instant 42%
            // drop on the first step and is perceptually silent a quarter of the way in.
            node.volume = Float(max(0, 1 - k))
            if k >= 1 { finishFade() }
            return
        }

        if position >= duration - 0.01 && duration > 0 {
            pause(); mode = .idle; onAutoStop?()
            return
        }

        guard mode == .intro else { return }
        guard let c = configProvider?() else {      // fail CLOSED: no config means stop, not play on
            pause(); mode = .idle; onAutoStop?(); return
        }
        guard !c.ignoreEnd else { return }
        guard c.introEnd > c.introStart else {      // degenerate range — stop rather than run free
            pause(); mode = .idle; onAutoStop?(); return
        }
        // no introStart floor: it would push fadeStart past introEnd on a short intro
        let fadeStart = max(0, c.introEnd - Player.fadeSec)
        if position >= fadeStart { beginFade(endAt: c.introEnd) }
    }

    private func beginFade(endAt: Double) {
        guard !fading else { return }
        let remain = endAt - position
        guard remain > 0.005 else { finishFadeNow(at: endAt); return }   // already late: cut, don't drift
        fading = true
        fadeEndAt = endAt
        fadeDur = remain                           // land silence exactly on Intro End
        fadeStartHost = CACurrentMediaTime()
    }

    private func finishFade() { finishFadeNow(at: fadeEndAt) }

    private func finishFadeNow(at endAt: Double) {
        fading = false
        node.pause()
        isPlaying = false
        pausedAt = endAt
        position = endAt
        seekOffset = endAt
        node.stop()                                 // so the next play schedules cleanly
        node.volume = 1
        mode = .idle
        stopGuard()
        onAutoStop?()
    }

    /// Abort a fade. Order matters: the caller pauses first, otherwise the render thread can emit
    /// one full-level block between restoring the volume and the node actually stopping.
    func cancelFade() {
        guard fading else { return }
        fading = false
        node.volume = 1
    }
}
