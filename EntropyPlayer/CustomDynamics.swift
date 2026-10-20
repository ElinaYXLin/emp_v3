import Foundation

// Apple's AUDynamicsProcessor (kAudioUnitSubType_DynamicsProcessor) and the Web
// Audio API's DynamicsCompressorNode are two different proprietary DSP
// algorithms. Even with numerically matched threshold/ratio/attack/release,
// Apple's unit is tuned to sound smooth and "musical" (audible as gain-reduction
// pumping), while Chromium/WebKit's compressor lets fast transients slip past its
// gain smoothing and clip, which reads as actual harsh distortion. No amount of
// parameter tuning bridges that gap — the underlying curves differ.
//
// This ports the Web Audio spec's own soft-knee compression-curve algorithm
// (threshold/knee/ratio → output dB) plus a one-pole attack/release envelope on
// the gain-reduction amount, so the macOS app produces the same curve shape and
// the same "fast limiter lets transients through" character as the web edition.
final class WebAudioCompressor {

    // Written from the main thread (mode toggle), read on the audio thread.
    // Updates happen only on an explicit mode switch (never per-sample), so an
    // uncontended lock here is free in practice.
    private let lock = NSLock()
    private var sampleRate: Double = 44100
    private var thresholdDb: Double = 0
    private var kneeDb: Double = 0
    private var ratio: Double = 20
    private var attackSec: Double = 0.001
    private var releaseSec: Double = 0.1
    private var trimLinear: Double = 1.0

    private var attackCoeff: Double = 0
    private var releaseCoeff: Double = 0

    // Gain-reduction envelope state (audio-thread only).
    private var currentReductionDb: Double = 0

    init() { recomputeCoeffs() }

    func setSampleRate(_ sr: Double) {
        lock.lock()
        if sr > 0 { sampleRate = sr; recomputeCoeffs() }
        lock.unlock()
    }

    /// Mirrors the web edition's configureDynamics(): threshold/knee/ratio/
    /// attack/release match Web Audio's DynamicsCompressorNode parameters
    /// exactly; trimDb is the fixed makeup/safety trim applied after (Web Audio
    /// itself has no automatic makeup gain, so this is applied explicitly, same
    /// as the web app's separate `dynamicsTrim` gain node).
    func configure(thresholdDb: Double, kneeDb: Double, ratio: Double,
                   attackSec: Double, releaseSec: Double, trimDb: Double) {
        lock.lock()
        self.thresholdDb = thresholdDb
        self.kneeDb       = kneeDb
        self.ratio        = ratio
        self.attackSec    = attackSec
        self.releaseSec   = releaseSec
        self.trimLinear   = pow(10, trimDb / 20)
        recomputeCoeffs()
        lock.unlock()
    }

    private func recomputeCoeffs() {
        attackCoeff  = 1 - exp(-1.0 / (max(attackSec, 0.0001) * sampleRate))
        releaseCoeff = 1 - exp(-1.0 / (max(releaseSec, 0.0001) * sampleRate))
    }

    // Standard soft-knee compression curve — the same threshold/knee/ratio
    // shape the Web Audio spec's DynamicsCompressorNode parameters describe:
    // transparent below threshold, quadratic soft-knee blend through the knee
    // width, then a fixed-ratio slope beyond it.
    private func curve(_ inputDb: Double, threshold: Double, knee: Double, ratio: Double) -> Double {
        if inputDb < threshold { return inputDb }
        let kneeEnd = threshold + knee
        if knee > 0, inputDb < kneeEnd {
            let t = (inputDb - threshold) / knee
            let reduction = (1 - 1 / ratio) * knee * t * t / 2
            return inputDb - reduction
        }
        return kneeEnd + (inputDb - kneeEnd) / ratio
    }

    /// Stereo-linked in-place processing: a single gain-reduction envelope
    /// driven by the louder of the two channels is applied to both, matching
    /// Web Audio's stereo-linked compressor (keeps the stereo image stable
    /// instead of each channel ducking independently).
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock()
        let th = thresholdDb, kn = kneeDb, ra = ratio, trim = trimLinear
        let atk = attackCoeff, rel = releaseCoeff
        lock.unlock()

        var reductionDb = currentReductionDb
        for i in 0..<count {
            let l = Double(left[i])
            let r = right != nil ? Double(right![i]) : l
            let peak = Swift.max(abs(l), abs(r), 1e-8)
            let inputDb  = 20 * log10(peak)
            let outputDb = curve(inputDb, threshold: th, knee: kn, ratio: ra)
            let targetReduction = Swift.max(0, inputDb - outputDb)

            if targetReduction > reductionDb {
                reductionDb += (targetReduction - reductionDb) * atk
            } else {
                reductionDb += (targetReduction - reductionDb) * rel
            }

            let gain = pow(10, -reductionDb / 20) * trim
            left[i] = Float(l * gain)
            if let right { right[i] = Float(r * gain) }
        }
        currentReductionDb = reductionDb
    }
}

// MARK: - Look-ahead safety limiter

// The final output safety stage (after Post-Gain). A transparent look-ahead
// peak limiter: the signal is delayed 3 ms while the limiter looks at the
// peak level coming up, so it can lower the gain smoothly *before* a peak
// arrives (no overshoot past the ceiling), then recovers over ~250 ms.
// Replaces a fast compressor (0.5 ms attack / 50 ms release) whose gain
// bobbed ~20×/s under heavy Post-Gain — an audible pumping "stutter" — and
// let peaks past full scale into hard clipping. A soft clip just under 0 dBFS
// catches anything left. Stereo-linked. Realtime-safe.
final class LookaheadLimiter {
    static let latency = 132                                      // 3 ms
    private static let size = 256
    private let ceiling: Float = 0.944                             // −0.5 dBFS
    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: LookaheadLimiter.size)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: LookaheadLimiter.size)
    private let peaks = UnsafeMutablePointer<Float>.allocate(capacity: LookaheadLimiter.size)
    private var w = 0
    private var gain: Float = 1
    private let release = Float(1 - exp(-1 / (0.250 * 44100)))
    private let attack = Float(1 - exp(-1 / (0.0012 * 44100)))     // reaches target well within the 3 ms look-ahead

    init() {
        bufL.initialize(repeating: 0, count: Self.size); bufR.initialize(repeating: 0, count: Self.size)
        peaks.initialize(repeating: 0, count: Self.size)
    }
    deinit { bufL.deallocate(); bufR.deallocate(); peaks.deallocate() }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        let mask = Self.size - 1, L = Self.latency
        for i in 0..<count {
            let l = left[i], r = right?[i] ?? l
            bufL[w] = l; bufR[w] = r
            peaks[w] = max(abs(l), abs(r))
            // Peak over the look-ahead window (L samples; small, so a scan is fine
            // every 8 samples, holding the max in between).
            if i % 8 == 0 || peaks[w] > heldPeak {
                var m: Float = 0
                var j = w
                for _ in 0...L { m = max(m, peaks[j]); j = (j - 1) & mask }
                heldPeak = m
            }
            let target = heldPeak > ceiling ? ceiling / heldPeak : 1
            gain += (target < gain ? attack : release) * (target - gain)
            let rd = (w - L) & mask
            var ol = bufL[rd] * gain, or = bufR[rd] * gain
            // Backstop soft clip just under full scale.
            if abs(ol) > 0.97 { ol = (ol > 0 ? 1 : -1) * (0.97 + 0.03 * tanhf((abs(ol) - 0.97) / 0.03)) }
            if abs(or) > 0.97 { or = (or > 0 ? 1 : -1) * (0.97 + 0.03 * tanhf((abs(or) - 0.97) / 0.03)) }
            left[i] = ol; right?[i] = or
            w = (w + 1) & mask
        }
    }
    private var heldPeak: Float = 0
}

// MARK: - Tube (vari-mu) compressor

/// A variable-mu tube compressor, the design of the Fairchild 660/670 and
/// Manley Vari-Mu: the gain-reduction tube's gain falls as its grid bias
/// rises, so the ratio is not fixed — it grows with level (≈1.5:1 just over
/// threshold → ≈4:1 when driven 15 dB over), over a very soft knee. That
/// progressive curve is why vari-mu compression sounds like glue rather than
/// clamping.
///
/// • Detector: stereo-linked RMS (5 ms) fed back from the output (feedback
///   topology, like the originals — smoother, more forgiving).
/// • Threshold: the lower of (music's 3 s RMS + 6 dB) and an absolute
///   ceiling, so it works at EMP's quiet internal level and on the hot
///   signal after +30 dB of Post-Gain alike.
/// • Timing: 12 ms attack; program-dependent two-stage release (a fast
///   0.3 s part for transients and a slow 2.5 s part that builds up on
///   sustained loud passages), after the Fairchild's multi-constant release.
/// • Tube colour: the signal passes a gently biased tanh (mostly 2nd
///   harmonic) whose drive rises with gain reduction, as a vari-mu tube
///   distorts more when biased hard. DC-blocked. About 1 % THD, mostly 2nd.
/// • Make-up: slow, half the average reduction, so it glues without
///   pumping the loudness up and down.
final class TubeCompressor {
    private static let sr = 44100.0
    private let lock = NSLock()
    private var enabled = false, absCeilingDb = -6.0
    private var env = 1e-6, longMs = 1e-6, fast = 0.0, slow = 0.0, avgGR = 0.0
    private var fbL: Float = 0, fbR: Float = 0
    private var dcX: [Float] = [0, 0], dcY: [Float] = [0, 0]
    private let envC = 1 - exp(-1 / (0.005 * 44100)), longC = 1 - exp(-1 / (3.0 * 44100))
    private let atkC = 1 - exp(-1 / (0.012 * 44100))
    private let relFast = 1 - exp(-1 / (0.3 * 44100)), relSlow = 1 - exp(-1 / (2.5 * 44100))
    private let mkC = 1 - exp(-1 / (4.0 * 44100))
    private let dcR = Float(exp(-2 * Double.pi * 10 / 44100))

    /// `ceilingDb`: absolute level above which it always compresses.
    func configure(enabled on: Bool, ceilingDb: Double) {
        lock.lock(); enabled = on; absCeilingDb = ceilingDb; lock.unlock()
    }

    @inline(__always) private static func gainReductionDb(_ over: Double) -> Double {
        // Soft knee (softplus, ~10 dB wide) and a ratio that grows with level.
        let o = 5 * log(1 + exp(over / 5))
        let ratio = 1.5 + 2.5 * min(1, o / 15)
        return o * (1 - 1 / ratio)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); let on = enabled, ceil = absCeilingDb; lock.unlock()
        if !on { fast = 0; slow = 0; avgGR = 0; return }
        for i in 0..<count {
            let xl = left[i], xr = right[i]
            // Feedback detector: what the tube is already putting out.
            let d = 0.5 * Double(fbL * fbL + fbR * fbR)
            env += envC * (d - env)
            let inP = 0.5 * Double(xl * xl + xr * xr)
            longMs += longC * (inP - longMs)
            let levelDb = 10 * log10(max(env, 1e-12))
            let thrDb = min(10 * log10(max(longMs, 1e-12)) + 6, ceil)
            let want = on ? Self.gainReductionDb(levelDb - thrDb) : 0
            // Two-stage release: fast follows transients, slow builds on sustained level.
            fast += (want > fast ? atkC : relFast) * (want - fast)
            slow += (want > slow ? atkC * 0.25 : relSlow) * (want - slow)
            let gr = max(fast, slow)
            avgGR += mkC * (gr - avgGR)
            let g = Float(pow(10, (-gr + 0.5 * avgGR) / 20))
            // Tube colour: biased tanh, drive rising with gain reduction.
            let drive = Float(0.6 + 0.08 * min(gr, 12))
            let bias: Float = 0.15, off = tanhf(bias)
            func tube(_ x: Float, _ ch: Int) -> Float {
                let ref = Float(max(longMs, 1e-8).squareRoot()) * 6      // headroom over the music's RMS
                let u = x / ref
                let y = (tanhf(drive * u + bias) - off) / (drive * (1 - off * off)) * ref
                let o = y - dcX[ch] + dcR * dcY[ch]; dcX[ch] = y; dcY[ch] = o
                return o
            }
            let yl = tube(xl * g, 0), yr = tube(xr * g, 1)
            left[i] = yl; right[i] = yr
            fbL = yl; fbR = yr
        }
    }
}
