import Foundation
import Accelerate

// Blur section engines that run in their own STFT (Smoke, Underwater). Each
// always runs (constant 2048-sample latency) and passes the input through
// exactly at strength 0. Wash and Diffuse live in MelodyBlur.swift; Swell is
// time-domain (no STFT, no latency).
class BlurSTFT {
    static let n = 2048, hop = 256, bins = 1024
    static let frameRate = 44100.0 / Double(hop)
    let fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    let window: UnsafeMutablePointer<Float>
    let inBuf, accum, ready: [UnsafeMutablePointer<Float>]
    let frame, re, im: UnsafeMutablePointer<Float>
    var fill = 0
    var rng: UInt64 = 0x1234_5678_9ABC_DEF1
    // 0…1, set from the UI thread; glided per frame on the audio thread.
    let lock = NSLock()
    var targetStrength: Float = 0, strength: Float = 0
    func setStrength(_ s: Double) { lock.lock(); targetStrength = Float(max(0, min(1, s))); lock.unlock() }
    static func buf(_ c: Int, _ v: Float = 0) -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: v, count: c); return p }
    init() {
        let n = Self.n
        window = BlurSTFT.buf(n); vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf = [BlurSTFT.buf(n), BlurSTFT.buf(n)]; accum = [BlurSTFT.buf(n), BlurSTFT.buf(n)]; ready = [BlurSTFT.buf(Self.hop), BlurSTFT.buf(Self.hop)]
        frame = BlurSTFT.buf(n); re = BlurSTFT.buf(Self.bins); im = BlurSTFT.buf(Self.bins)
    }
    @inline(__always) func uni() -> Float { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Float(rng >> 40) / Float(1 << 24) }
    @inline(__always) func gauss() -> Float { (uni() + uni() + uni() + uni() - 2) * 1.73 }
    func spectrum(_ ch: Int) {}          // override: modify re/im (bins 1..<B)
    func idle(_ ch: Int) {}              // override: keep state warm while off (spectrum untouched)
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let H = Self.hop, N = Self.n
        for i in 0..<count {
            let l = left[i], r = right[i]
            left[i] = ready[0][fill]; right[i] = ready[1][fill]
            inBuf[0][N - H + fill] = l; inBuf[1][N - H + fill] = r
            fill += 1
            if fill == H {
                fill = 0
                lock.lock(); let t = targetStrength; lock.unlock()
                strength += (t - strength) * 0.08
                step(0); step(1)
            }
        }
    }
    private func step(_ ch: Int) {
        let N = Self.n, H = Self.hop, B = Self.bins
        vDSP_vmul(inBuf[ch], 1, window, 1, frame, 1, vDSP_Length(N))
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(kFFTDirection_Forward))
        if strength > 1e-4 { spectrum(ch) } else { idle(ch) }
        vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(kFFTDirection_Inverse))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(B)) }
        var scale = 1 / (2 * Float(N) * 3.0)
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(N))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(N))
        vDSP_vadd(accum[ch], 1, frame, 1, accum[ch], 1, vDSP_Length(N))
        ready[ch].assign(from: accum[ch], count: H)
        accum[ch].assign(from: accum[ch] + H, count: N - H)
        vDSP_vclr(accum[ch] + (N - H), 1, vDSP_Length(H))
        inBuf[ch].assign(from: inBuf[ch] + H, count: N - H)
    }
    func coef(_ sec: Double) -> Float { Float(1 - exp(-1 / (sec * Self.frameRate))) }
}


// Smoke — blurs across pitch (up to ±⅓ octave) and time (up to 0.3 s in,
// 2.5 s out), resynthesized with fast-churning noise-like phases: notes lose
// their pitch and become textured fog. Strength scales the width, the time
// constants and how much fog replaces the live sound.
final class SmokeBlur: BlurSTFT {
    let st = [BlurSTFT.buf(1024), BlurSTFT.buf(1024)], cp = [BlurSTFT.buf(1024), BlurSTFT.buf(1024)], pre = BlurSTFT.buf(1025), mg = BlurSTFT.buf(1024)
    override func spectrum(_ ch: Int) {
        let sm = strength
        let S = st[ch], P = cp[ch], a = coef(Double(0.03 + 0.27 * sm)), rl = coef(Double(0.1 + 2.4 * sm))
        let expect = 2 * Float.pi * 256 / 2048
        for k in 1..<1024 { mg[k] = (re[k]*re[k] + im[k]*im[k]).squareRoot() }
        pre[0] = 0; pre[1] = 0; for k in 1..<1024 { pre[k + 1] = pre[k] + mg[k] }
        for k in 1..<1024 {
            let w = max(1, Int(Float(k) * 0.26 * sm)); let lo = max(1, k - w), hi = min(1023, k + w)
            let avg = (pre[hi + 1] - pre[lo]) / Float(hi - lo + 1)
            S[k] += (avg > S[k] ? a : rl) * (avg - S[k])
            P[k] += expect * Float(k) + 1.4 * gauss()
            P[k] -= 2 * Float.pi * (P[k] / (2 * Float.pi)).rounded()
            // Fog replaces the live sound in proportion to strength.
            re[k] = re[k] * (1 - sm) + sm * S[k] * cosf(P[k]); im[k] = im[k] * (1 - sm) + sm * S[k] * sinf(P[k])
        }
    }
    override func idle(_ ch: Int) { for k in 1..<1024 { st[ch][k] = (re[k]*re[k] + im[k]*im[k]).squareRoot() } }
}

// Underwater — frequency-dependent: lows linger up to ~4 s, highs fade within
// 0.15 s and bloom in slowly (0.6 s), with up to −8 dB of high-frequency dip;
// the lingering part is a soft drifting cloud. Strength scales the time
// constants and the dip from transparent to full.
final class UnderwaterBlur: BlurSTFT {
    let st = [BlurSTFT.buf(1024), BlurSTFT.buf(1024)], cp = [BlurSTFT.buf(1024), BlurSTFT.buf(1024)]
    let tpos = BlurSTFT.buf(1024)        // 0 @100 Hz → 1 @5 kHz
    override init() {
        super.init()
        for k in 1..<1024 { let hz = Float(k) * 44100 / 2048; tpos[k] = max(0, min(1, (log2f(hz / 100)) / log2f(50))) }
    }
    override func spectrum(_ ch: Int) {
        let S = st[ch], P = cp[ch], expect = 2 * Float.pi * 256 / 2048, s = strength
        for k in 1..<1024 {
            let t = tpos[k]
            let atkC = coef(Double(0.01 + (0.04 + 0.55 * t) * s))
            let relC = coef(Double(0.03 + (4.0 * powf(0.0375, t) - 0.03) * s))
            let tilt = powf(10, -8 * t * s / 20)
            let m = (re[k]*re[k] + im[k]*im[k]).squareRoot()
            S[k] += (m > S[k] ? atkC : relC) * (m - S[k])
            P[k] += expect * Float(k) + 0.3 * gauss()
            P[k] -= 2 * Float.pi * (P[k] / (2 * Float.pi)).rounded()
            let out = S[k] * tilt
            let live = min(m, S[k]) * tilt / max(m, 1e-12)
            let e = max(0, out - m * tilt)
            re[k] = re[k] * live + e * cosf(P[k]); im[k] = im[k] * live + e * sinf(P[k])
        }
    }
    override func idle(_ ch: Int) { for k in 1..<1024 { st[ch][k] = (re[k]*re[k] + im[k]*im[k]).squareRoot() } }
}

// Smear: a dense, short, slowly moving diffusion network — no spectral
// processing (the STFT versions resynthesized lingering energy as steady
// tones, which sounded like a spectral resonator). Input diffusion (two
// allpasses) feeds an 8-line feedback delay network (9–45 ms lines, Hadamard
// mixing, each line's delay swaying a few samples at its own slow rate, a
// 6 kHz damping filter in the loop). Its tail is 0.15 → 1.0 s with strength,
// so notes melt into each other as a soft smear; modulation keeps any
// resonance from settling. Added on top of the dry sound; strength 0 is
// exactly dry. Stereo out from different line taps.
final class SmearBlur {
    private static let sr = 44100.0
    private static let lens = [397, 523, 677, 811, 953, 1103, 1289, 1499]
    private static let size = 2048
    private let lock = NSLock()
    private var target = 0.0, strength = 0.0
    private let lines = UnsafeMutablePointer<Float>.allocate(capacity: 8 * SmearBlur.size)
    private var w = 0
    private var lp = [Float](repeating: 0, count: 8)
    private var modPh: [Double] = (0..<8).map { Double($0) * 0.77 }
    private let modRate: [Double] = (0..<8).map { 0.11 + 0.07 * Double($0) }
    private let ap = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 512)
    private var apW = 0
    private let x = UnsafeMutablePointer<Float>.allocate(capacity: 8)    // line outputs
    private let h = UnsafeMutablePointer<Float>.allocate(capacity: 8)    // Hadamard scratch

    init() {
        lines.initialize(repeating: 0, count: 8 * Self.size)
        ap.initialize(repeating: 0, count: 2 * 512)
        x.initialize(repeating: 0, count: 8); h.initialize(repeating: 0, count: 8)
    }
    deinit { lines.deallocate(); ap.deallocate(); x.deallocate(); h.deallocate() }

    func setStrength(_ s: Double) { lock.lock(); target = max(0, min(1, s)); lock.unlock() }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); let t = target; lock.unlock()
        if t == 0 && strength < 1e-4 { strength = 0; return }
        strength += (t - strength) * (1 - exp(-Double(count) / (0.05 * Self.sr)))
        let s = strength
        let rt60 = 0.15 + 0.85 * s
        let meanLen = 900.0
        let g = Float(pow(10, -3 * meanLen / (rt60 * Self.sr)))      // per-trip feedback for the RT60
        let damp = Float(1 - exp(-2 * Double.pi * 6000 / Self.sr))
        let wet = Float(0.9 * s), dry = Float(1 - 0.3 * s)
        let mask = Self.size - 1
        for i in 0..<count {
            // Input: mono, through two short diffusion allpasses.
            var v = (left[i] + right[i]) * 0.5
            for (k, len) in [(0, 113), (1, 337)] {
                let base = k * 512, d = ap[base + ((apW - len) & 511)]
                let ww = v + 0.6 * d; ap[base + (apW & 511)] = ww; v = d - 0.6 * ww
            }
            apW = (apW + 1) & 511
            // Read the 8 lines (modulated), damp.
            for k in 0..<8 {
                modPh[k] += modRate[k] / Self.sr; if modPh[k] > 1 { modPh[k] -= 1 }
                let d = Double(Self.lens[k]) + 6 * sin(2 * Double.pi * modPh[k])
                let pos = Double(w) - d, fl = pos.rounded(.down), fr = Float(pos - fl)
                let i0 = Int(fl) & mask, i1 = (i0 + 1) & mask
                let a = lines[k * Self.size + i0], b = lines[k * Self.size + i1]
                lp[k] += damp * ((a + (b - a) * fr) - lp[k])
                x[k] = lp[k]
            }
            // Hadamard 8×8 (fast), scaled to stay energy-preserving.
            for k in 0..<8 { h[k] = x[k] }
            var span = 1
            while span < 8 {
                var j = 0
                while j < 8 { for q in j..<(j + span) { let u = h[q], z = h[q + span]; h[q] = u + z; h[q + span] = u - z }; j += span * 2 }
                span *= 2
            }
            for k in 0..<8 { lines[k * Self.size + w] = v * 0.35 + h[k] * 0.35355 * g }
            w = (w + 1) & mask
            let outL = (x[0] - x[2] + x[4] - x[6]) * 0.5, outR = (x[1] - x[3] + x[5] - x[7]) * 0.5
            left[i] = left[i] * dry + outL * wet
            right[i] = right[i] * dry + outR * wet
        }
    }
}

// Swell: no spectral processing at all. Eight bands split by
// subtraction (they sum back exactly); in each, attacks are slowed by the
// ratio of a slow-attack to a fast envelope (up to 0.8 s) and decays held up (to 2.5×), like a multiband transient
// shaper turned all the way to "soft" — even dense music becomes pads.
final class SwellBlur {
    static let cuts: [Double] = [100, 200, 400, 800, 1600, 3200, 6400]
    private let lock = NSLock()
    private var target = 0.0, strength = 0.0
    func setStrength(_ s: Double) { lock.lock(); target = max(0, min(1, s)); lock.unlock() }
    private var lp = [[Double]](repeating: [Double](repeating: 0, count: 14), count: 2)
    private var envF = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 2)
    private var envS = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 2)
    private var gain = [[Double]](repeating: [Double](repeating: 1, count: 8), count: 2)
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); let t = target; lock.unlock()
        if t == 0 && strength < 1e-4 { strength = 0; return }
        strength += (t - strength) * (1 - exp(-Double(count) / (0.05 * 44100)))
        let sr = 44100.0, c = Self.cuts.map { 1 - exp(-2 * Double.pi * $0 / sr) }
        let fA = 1 - exp(-1 / (0.001 * sr)), fR = 1 - exp(-1 / (0.060 * sr))
        // Slow follower: slow rise (up to 0.8 s) AND slow fall (up to 0.6 s),
        // so attacks are pulled down and decays are held up — a pad.
        let sA = 1 - exp(-1 / ((0.01 + 0.79 * strength) * sr)), sR = 1 - exp(-1 / ((0.06 + 0.54 * strength) * sr))
        let gS = 1 - exp(-1 / (0.005 * sr))
        for ch in 0..<2 {
            let p = ch == 0 ? left : right
            var L = lp[ch], EF = envF[ch], ES = envS[ch], G = gain[ch]
            for i in 0..<count {
                var rest = Double(p[i]), out = 0.0
                for b in 0..<8 {
                    var band: Double
                    if b < 7 { L[2*b] += c[b] * (rest - L[2*b]); L[2*b+1] += c[b] * (L[2*b] - L[2*b+1]); band = L[2*b+1]; rest -= band } else { band = rest }
                    let a = abs(band)
                    EF[b] += (a > EF[b] ? fA : fR) * (a - EF[b]); ES[b] += (a > ES[b] ? sA : sR) * (a - ES[b])
                    // Exaggerated (ratio^2.5) so even dense, sustained music is
                    // pulled into pads: attacks pushed down hard, decays held up
                    // (to 2.5×).
                    let want = min(2.5, pow(ES[b] / max(EF[b], 1e-9), 2.5))
                    G[b] += gS * (want - G[b])
                    out += band * (1 + strength * (G[b] - 1))
                }
                p[i] = Float(out)
            }
            lp[ch] = L; envF[ch] = EF; envS[ch] = ES; gain[ch] = G
        }
    }
}

// Murk — the bass buries the mids, using the ear's own upward masking.
// Three parts, all scaled by strength and all level-independent (ratios):
//  1. Bass-triggered mid duck: the bass's share of the frame's energy
//     (fast attack, ~200 ms release) pulls a broad 300 Hz–3 kHz band down,
//     up to −21 dB, so every kick / bass note sinks the mids beneath it.
//  2. Spectral masking: each bass bin (≤ 260 Hz) casts an upward masking
//     curve (slope 24 → 12 dB/oct, offset 14 → 6 dB as strength rises);
//     mid/high bins that fall under it are attenuated Wiener-style, so quiet
//     detail the bass would "nearly" hide is hidden.
//  3. Low-mid bloom: up to +6 dB around 150–400 Hz, backed off when that
//     band is already heavy (slow, ~400 ms) — woolly, behind-a-wall warmth.
//  Plus bass harmonic bleed (see process) and a high darkening (−4 dB/oct above 2 kHz at full) and a haze fog:
//     removed mid detail returns smeared in pitch and time.
// Gains glided per bin; the fog adds drifting phases. Exact pass-through at 0.
final class MurkFilter: BlurSTFT {
    private let G = [BlurSTFT.buf(1024, 1), BlurSTFT.buf(1024, 1)], p = BlurSTFT.buf(1024)
    // Haze: a slow, pitch-smeared magnitude fog with drifting phases, per channel.
    private let fog = [BlurSTFT.buf(1024), BlurSTFT.buf(1024)], fogPh = [BlurSTFT.buf(1024), BlurSTFT.buf(1024)], mag = BlurSTFT.buf(1024)
    private let weightDark = BlurSTFT.buf(1024)
    // Loudness hold: smoothed in/out loudness (≈ K-weighted: bins below
    // ~100 Hz ignored, 2–8 kHz counted extra) and the makeup gain.
    private var inLoud: [Float] = [1e-12, 1e-12], outLoud: [Float] = [1e-12, 1e-12], makeup: [Float] = [1, 1]
    private let weightK = BlurSTFT.buf(1024)
    private var bassEnv: [Float] = [0, 0], bloomEnv: [Float] = [0, 0], bloomLong: [Float] = [1e-9, 1e-9]
    private static let srcBins = 12                                   // ≤ ~260 Hz
    private let weightDuck = BlurSTFT.buf(1024), weightBloom = BlurSTFT.buf(1024)
    override init() {
        super.init()
        for k in 1..<Self.bins {
            let hz = Float(k) * 44100 / Float(Self.n)
            // Duck: flat 300 Hz–3 kHz, half-octave tapers.
            let lo = log2f(hz / 300), hi = log2f(3000 / hz)
            weightDuck[k] = max(0, min(1, min(lo, hi) / 0.5 + 1))
            // Bloom: bell on ~250 Hz, ±1.3 octaves.
            weightBloom[k] = max(0, 1 - abs(log2f(hz / 250)) / 1.3)
            // Darkening: 0 below 2 kHz, rising one unit per octave above.
            weightDark[k] = max(0, log2f(hz / 2000))
            weightK[k] = hz < 100 ? 0 : (hz > 2000 ? 1.6 : 1)
        }
    }
    override func idle(_ ch: Int) { for k in 0..<Self.bins { G[ch][k] = 1 }; makeup[ch] = 1 }

    // Bass harmonic bleed: the bass (< ~150 Hz) is split off, normalized by
    // its own envelope (so it's level-independent), pushed through an
    // asymmetric tanh, and only the *added* overtones (2nd–5th, band-limited
    // to ~90–600 Hz) are mixed back, up to about the bass.s own level at full
    // strength. The bass spreads upward into a thick, woolly low-mid layer —
    // an overdriven bass amp in a small room. Runs before the STFT, so the
    // duck / mask / bloom then shape it with everything else.
    private var bLP1: [Float] = [0, 0], bLP2: [Float] = [0, 0], bEnv: [Float] = [1e-4, 1e-4]
    private var hHP: [Float] = [0, 0], hHPx: [Float] = [0, 0], hLP1: [Float] = [0, 0], hLP2: [Float] = [0, 0]
    private static let cBass = Float(1 - exp(-2 * Double.pi * 150 / 44100))
    private static let cHP = Float(exp(-2 * Double.pi * 90 / 44100))
    private static let cTop = Float(1 - exp(-2 * Double.pi * 600 / 44100))
    private static let cEnv = Float(1 - exp(-1 / (0.05 * 44100)))
    private static let bias: Float = 0.35
    private static let tb = tanhf(bias), slope0 = 1 - tanhf(bias) * tanhf(bias)

    override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let amt = max(strength, targetStrength)
        if amt > 1e-4 {
            for ch in 0..<2 {
                let x = ch == 0 ? left : right
                var l1 = bLP1[ch], l2 = bLP2[ch], e = bEnv[ch], hp = hHP[ch], hx = hHPx[ch], t1 = hLP1[ch], t2 = hLP2[ch]
                let mix = 2.2 * strength
                for i in 0..<count {
                    l1 += Self.cBass * (x[i] - l1); l2 += Self.cBass * (l1 - l2)
                    e += Self.cEnv * (abs(l2) - e)
                    let ref = max(e, 1e-5)
                    let u = 2.2 * l2 / (ref * 1.6)                     // ~±2 at the bass's peaks
                    let h = (tanhf(u + Self.bias) - Self.tb) - Self.slope0 * u   // overtones only
                    hp = Self.cHP * (hp + h - hx); hx = h               // drop DC / fundamental-ish lows
                    t1 += Self.cTop * (hp - t1); t2 += Self.cTop * (t1 - t2)
                    x[i] += mix * t2 * ref * 1.6
                }
                bLP1[ch] = l1; bLP2[ch] = l2; bEnv[ch] = e; hHP[ch] = hp; hHPx[ch] = hx; hLP1[ch] = t1; hLP2[ch] = t2
            }
        }
        super.process(left: left, right: right, count: count)
    }
    override func spectrum(_ ch: Int) {
        let B = Self.bins, s = strength, g = G[ch]
        var total: Float = 1e-20, bass: Float = 0, bloomBand: Float = 0, kIn: Float = 1e-20
        for k in 1..<B {
            let e = re[k] * re[k] + im[k] * im[k]; p[k] = e; total += e
            if k <= 7 { bass += e }
            if weightBloom[k] > 0.5 { bloomBand += e }
            kIn += e * weightK[k]
        }
        // 1. Duck amount from the bass share.
        let share = bass / total
        bassEnv[ch] += (share > bassEnv[ch] ? coef(0.015) : coef(0.2)) * (share - bassEnv[ch])
        let duckDb = -18 * s * min(1, bassEnv[ch] * 1.6) - 3 * s
        // 4. Bloom, backed off when the band is already heavy vs its average.
        let bs = bloomBand / total
        bloomEnv[ch] += coef(0.4) * (bs - bloomEnv[ch]); bloomLong[ch] += coef(4) * (bs - bloomLong[ch])
        let heavy = max(0, min(1, bloomEnv[ch] / max(bloomLong[ch], 1e-9) - 1))
        let bloomDb = 6 * s * (1 - 0.6 * heavy)
        // 2. Masking curve from the bass bins.
        let slope = 24 - 16 * s, offsetDb = 14 - 14 * s
        let gUp = coef(0.12), gDown = coef(0.02)
        for k in 1..<B {
            var t: Float = 0
            if k > Self.srcBins {
                for j in 1...Self.srcBins where p[j] > 0 {
                    let db = slope * log2f(Float(k) / Float(j)) + offsetDb
                    t = max(t, p[j] * powf(10, -db / 10))
                }
            }
            var gain = t > 0 ? (p[k] / (p[k] + s * 10 * t)).squareRoot() : 1
            gain *= powf(10, (duckDb * weightDuck[k] + bloomDb * weightBloom[k] - 4 * s * weightDark[k]) / 20)
            g[k] += (gain < g[k] ? gDown : gUp) * (gain - g[k])
            re[k] *= g[k]; im[k] *= g[k]
            mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot()
        }
        // Haze: what the masking/duck removed from the mids comes back as a
        // soft fog — magnitudes smeared ±2 bins and over time (60 ms in,
        // 0.6 s out), resynthesized with slowly drifting phases — so the
        // detail isn't just quieter, it's blurred into a cloud under the bass.
        let F = fog[ch], PH = fogPh[ch], fIn = coef(0.06), fOut = coef(0.6)
        let fogMix = 0.9 * s
        for k in 3..<(B - 3) where weightDuck[k] > 0 || weightDark[k] > 0 {
            let sm = (mag[k - 2] + 2 * mag[k - 1] + 3 * mag[k] + 2 * mag[k + 1] + mag[k + 2]) / 9
            F[k] += (sm > F[k] ? fIn : fOut) * (sm - F[k])
            PH[k] += Float.pi / 2 * Float(k) + 0.5 * gauss()
            PH[k] -= 2 * Float.pi * (PH[k] / (2 * Float.pi)).rounded()
            let w = fogMix * max(weightDuck[k], min(1, weightDark[k])) * (1 - g[k])
            re[k] = re[k] * (1 - 0.5 * w) + w * F[k] * cosf(PH[k])
            im[k] = im[k] * (1 - 0.5 * w) + w * F[k] * sinf(PH[k])
        }
        // Loudness hold: the duck, masking and darkening take energy out in
        // bursts (every kick), which made LUFS bob. Compare smoothed
        // K-weighted loudness out vs in (~80 ms) and make the difference up
        // broadband (±10 dB, glided), so the *balance* still sinks the mids
        // under the bass but the overall loudness stays put.
        var kOut: Float = 1e-20
        for k in 1..<B { kOut += (re[k] * re[k] + im[k] * im[k]) * weightK[k] }
        let lc = coef(0.08)
        inLoud[ch] += lc * (kIn - inLoud[ch]); outLoud[ch] += lc * (kOut - outLoud[ch])
        let want = min(3.16, max(0.316, (inLoud[ch] / max(outLoud[ch], 1e-20)).squareRoot()))
        let target = 1 + (want - 1) * min(1, s * 4)          // fully on by 25 %
        makeup[ch] += coef(0.03) * (target - makeup[ch])
        let mg = makeup[ch]
        for k in 1..<B { re[k] *= mg; im[k] *= mg }
    }
}
