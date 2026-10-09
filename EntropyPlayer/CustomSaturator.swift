import Foundation

// AVAudioUnitDistortion is Apple's own distortion algorithm (its presets are
// built from ring-modulation, decimation, and delay-based effects, not a plain
// tanh soft-clip) — a fundamentally different DSP than the web edition's
// saturator. That mismatch is what caused a boomy artifact once the EQ's bass
// boost drove it: AVAudioUnitDistortion's internal processing doesn't behave
// like a simple waveshaper on boosted low-frequency content.
//
// This ports the web app's exact saturator: a fixed pre-gain, a tanh
// waveshaper curve normalized so tanh(drive) maps to unity, then a post-gain
// that compensates for level except below unity drive. Same algorithm,
// evaluated directly per-sample instead of via a 512-point lookup table
// (equivalent audible result, no interpolation error).
//
// Analog voicing: a plain tanh is odd-symmetric, so it only ever adds odd
// harmonics (3rd, 5th… — the harsher, "transistor" sound). Like a tube
// stage's grid-bias shift, the curve's operating point here is offset by a
// bias proportional to the signal's own envelope. Because the bias scales
// with level, the clipping stays asymmetric even when driven hard (a fixed
// bias gets swamped and the output turns square/odd again), so 2nd/4th
// harmonics dominate at every drive setting — measured ~7–20 dB more even
// than odd content, and ~15 dB less 3rd harmonic than the plain tanh at full
// drive. The asymmetry produces a level-dependent DC offset, removed by a
// 10 Hz high-pass (4th-order Butterworth, 24 dB/oct). It's steep because
// even-order distortion also makes intermodulation difference tones (two
// bass notes at 55 + 62 Hz → a 7 Hz throb) that a gentle DC blocker let
// through as an engine-like whirr. The envelope follower is also slow
// (50 ms attack / 400 ms release) so the bias doesn't track — and
// re-modulate — individual bass cycles and beats.
//
// Two voicings share this class: `.even` (the biased curve above) and `.odd`
// (the web edition's original plain tanh, kept as its own "Odd Saturator"
// control for a brighter, grittier edge).
final class WebAudioSaturator {

    enum Voicing { case even, odd }
    private let voicing: Voicing

    init(voicing: Voicing) {
        self.voicing = voicing
    }

    // Written from the main thread (macro/slider updates), read on the audio
    // thread. Updates are UI-rate, so an uncontended lock here is effectively free.
    private let lock = NSLock()
    private var driveLin: Double = 1.0
    private var tanhDrive: Double = 1.0
    private var postGain: Double = 1.0

    /// Bias as a fraction of the envelope — sets the even/odd balance.
    private var biasAmount = 0.5
    private static let sampleRate = 44100.0
    private static let attackCoef  = 1 - exp(-1 / (0.050 * sampleRate))
    private static let releaseCoef = 1 - exp(-1 / (0.400 * sampleRate))
    // Two cascaded RBJ high-pass biquads, Q = 0.5412 and 1.3066 → 4th-order Butterworth at 10 Hz.
    private static let hpCoefs: [(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)] =
        [0.5411961, 1.3065630].map { q in
            let w0 = 2 * Double.pi * 10 / sampleRate, alpha = sin(w0) / (2 * q), c = cos(w0), a0 = 1 + alpha
            return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
        }
    // [channel][stage] biquad state: x1, x2, y1, y2
    private var hpState = [[[Double]]](repeating: [[0, 0, 0, 0], [0, 0, 0, 0]], count: 2)

    // Per-channel filter state, owned by the audio thread.
    private var env:  [Double] = [0, 0]
    // Loudness makeup state per channel: smoothed input / output power.
    private var pIn:  [Double] = [0, 0]
    private var pOut: [Double] = [0, 0]
    private static let powerCoef = 1 - exp(-1 / (0.300 * sampleRate))

    /// driveDb: 0–16 dB (the web edition used 0–8; doubled for more warmth).
    /// Even voicing: bias as a fraction of the envelope (sets even/odd balance).
    func setBias(_ b: Double) {
        lock.lock()
        biasAmount = max(0, min(1, b))
        lock.unlock()
    }

    /// Low quality: a rational tanh approximation (Padé 3/2, clamped) in
    /// place of the exact double-precision tanh — the saturators were the
    /// most expensive stage. Max error ≈ 2 % near the knee; inaudible as
    /// a level change, slightly different harmonic balance at high drive.
    // Wobble (even voicing): the bias drifts to a random destination in
    // ±wobble over a random 20–100 s, then picks the next. A rising bias also
    // closes a 2-pole low-pass on the saturator's output (20 kHz → ~2.5 kHz
    // at +1 bias shift); falling bias leaves it open. Wobble 0 is exact.
    private var wobble = 0.0
    private var wobFrom = 0.0, wobTo = 0.0, wobPos = 0.0, wobLen = 1.0, wobShift = 0.0
    private var wobRng: UInt64 = 0xB1A5_0FF5_E7D1_F7ED
    private var wlp = [[0.0, 0.0], [0.0, 0.0]]
    private var wobLPCoef = 1.0
    func setWobble(_ w: Double) { lock.lock(); wobble = max(0, min(1, w)); lock.unlock() }
    /// Current wobble bias shift (for display/report).
    var wobbleShift: Double { wobShift }

    private func wobRand() -> Double {
        wobRng ^= wobRng << 13; wobRng ^= wobRng >> 7; wobRng ^= wobRng << 17
        return Double(wobRng >> 11) / Double(1 << 53)
    }

    /// Advances the wobble LFO by one block (called on channel 0).
    private func advanceWobble(_ count: Int, _ amount: Double) {
        wobPos += Double(count)
        if wobPos >= wobLen {
            wobPos = 0; wobFrom = wobTo
            wobTo = wobRand() * 2 - 1
            wobLen = (20 + 80 * wobRand()) * Self.sampleRate
        }
        let e = 0.5 - 0.5 * cos(Double.pi * wobPos / wobLen)
        wobShift = amount * (wobFrom + (wobTo - wobFrom) * e)
        let fc = 20000 * pow(0.125, max(0, wobShift))
        wobLPCoef = 1 - exp(-2 * Double.pi * fc / Self.sampleRate)
    }

    private var lowQuality = false
    func setLowQuality(_ on: Bool) { lock.lock(); lowQuality = on; lock.unlock() }

    @inline(__always) private static func fastTanh(_ x: Double) -> Double {
        if x > 3 { return 1 }
        if x < -3 { return -1 }
        let x2 = x * x
        return x * (27 + x2) / (27 + 9 * x2)
    }

    func setDrive(driveDb: Double) {
        lock.lock()
        let d = pow(10, driveDb / 20)
        driveLin  = d
        tanhDrive = tanh(max(d, 0.001))
        // Level normalization, two parts:
        // 1. Unity small-signal gain: the curve's input is scaled by d², so
        //    divide by d² after it (|tanh u| ≤ |u| → never louder).
        // 2. Loudness makeup (in process): input and output power are tracked
        //    with the same 300 ms smoothing and the output is scaled so its
        //    RMS matches the input's. Clipping lowers the crest factor, so at
        //    matched RMS the peaks still come out at or below the input's —
        //    loudness-neutral, never hotter into the limiter.
        // (The web edition's 1/tanh(d)·1/max(d,1) scaling left quiet material
        // up to d/tanh(d) louder: +2.4 dB at 0 dB drive, ~+16 dB at 16 dB.)
        postGain  = 1 / (d * d)
        lock.unlock()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        lock.lock()
        let drive = driveLin, post = postGain, lq = lowQuality, wob = wobble
        var biasAmt = biasAmount
        lock.unlock()
        if voicing == .even {
            if channel == 0 { advanceWobble(count, wob) }
            biasAmt = max(0, biasAmt + wobShift)
        }

        // Hot loop: plain local scalars only (no captured closures or nested
        // arrays — those cost far more than the tanh itself).
        let ch = min(max(channel, 0), 1)
        var pi = pIn[ch], po = pOut[ch]
        let maxMakeup = 1 / post
        let pc = Self.powerCoef
        // Makeup gain: every sample in high quality, every 32 in low.
        let makeupEvery = lq ? 32 : 1
        var g = max(1, min(maxMakeup, ((pi + 1e-12) / (po + 1e-12)).squareRoot()))

        if voicing == .odd {
            let d2 = drive * drive
            for i in 0..<count {
                let x = Double(buffer[i])
                let u = x * d2
                let y = (lq ? Self.fastTanh(u) : tanh(u)) * post      // unity small-signal gain
                pi += pc * (x * x - pi)
                po += pc * (y * y - po)
                if i % makeupEvery == 0 {
                    g = max(1, min(maxMakeup, ((pi + 1e-12) / (po + 1e-12)).squareRoot()))
                }
                buffer[i] = Float(y * g)
            }
            pIn[ch] = pi; pOut[ch] = po
            return
        }

        var e = env[ch]
        let c0 = Self.hpCoefs[0], c1 = Self.hpCoefs[1]
        var s0 = hpState[ch][0], s1 = hpState[ch][1]
        var a0 = s0[0], a1 = s0[1], a2 = s0[2], a3 = s0[3]     // stage 1: x1 x2 y1 y2
        var b0 = s1[0], b1 = s1[1], b2 = s1[2], b3 = s1[3]     // stage 2
        let d2 = drive * drive
        for i in 0..<count {
            let x = Double(buffer[i])
            let xs = x * d2                                       // preGain + curve drive

            // Envelope follower (50 ms attack / 400 ms release) → tube-style bias.
            let mag = abs(xs)
            e += (mag > e ? Self.attackCoef : Self.releaseCoef) * (mag - e)
            let bias = biasAmt * e

            // Biased waveshaper, re-centered so silence stays at zero.
            let shaped = lq ? Self.fastTanh(xs + bias) - Self.fastTanh(bias)
                            : tanh(xs + bias) - tanh(bias)

            // 4th-order high-pass (removes DC and sub-10 Hz difference tones).
            let o1 = c0.b0 * shaped + c0.b1 * a0 + c0.b2 * a1 - c0.a1 * a2 - c0.a2 * a3
            a1 = a0; a0 = shaped; a3 = a2; a2 = o1
            let o2 = c1.b0 * o1 + c1.b1 * b0 + c1.b2 * b1 - c1.a1 * b2 - c1.a2 * b3
            b1 = b0; b0 = o1; b3 = b2; b2 = o2

            let y = o2 * post                                     // unity small-signal gain
            pi += pc * (x * x - pi)
            po += pc * (y * y - po)
            if i % makeupEvery == 0 {
                g = max(1, min(maxMakeup, ((pi + 1e-12) / (po + 1e-12)).squareRoot()))
            }
            buffer[i] = Float(y * g)
        }
        if wobShift > 0.002 || wlp[ch][1] != 0 {
            // Wobble low-pass (also runs while it settles back open).
            var p0 = wlp[ch][0], p1 = wlp[ch][1]
            let c = wobLPCoef
            for i in 0..<count {
                let x = Double(buffer[i])
                p0 += c * (x - p0); p1 += c * (p0 - p1)
                buffer[i] = Float(p1)
            }
            if wobShift <= 0.002 && abs(p1 - Double(buffer[count - 1])) < 1e-9 { p0 = 0; p1 = 0 }
            wlp[ch] = [p0, p1]
        }
        s0 = [a0, a1, a2, a3]; s1 = [b0, b1, b2, b3]
        env[ch] = e; hpState[ch] = [s0, s1]
        pIn[ch] = pi; pOut[ch] = po
    }

}
