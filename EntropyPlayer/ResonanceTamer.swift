import Foundation
import Accelerate

// Resonance tamer: catches narrow resonances that build up when several
// effects stack colour in the same place (e.g. ~400–500 Hz) and gently pulls
// them down — a "soothing" dynamic EQ. Runs last, after the output limiter.
// (Earlier tuning — 60 ms smoothing, 5/3.5 dB thresholds — treated ordinary
// musical harmonics as resonances and cut 3–4 dB across clean dry music.)
//
// STFT (2048 Hann, hop 256). Per bin, the magnitude is smoothed over ~1 s
// (so only *sustained* peaks count, not transients) and compared with a
// local spectral envelope: the mean power over ±⅓ octave. Where a bin stands
// more than 8 dB above its surroundings (6 dB in 250–900 Hz and 1–4 kHz, where stacked
// effect copies ring on held vocal notes; range 150 Hz–5 kHz), its gain is
// lowered by 0.5 dB per dB of excess, plus a cut that grows the longer the
// peak persists (+3 dB/s), up to −12 dB; gains glide (40 ms down, 300 ms back)
// and are smoothed across neighbouring bins. Only real gains are applied —
// phases are untouched — so it can't add warble or stutter. With nothing
// sticking out it is an exact pass-through (constant 2048-sample latency).
final class ResonanceTamer {
    static let latency = 2048
    private static let n = 2048, hop = 256, bins = 1024
    private static let log2n = vDSP_Length(11)
    private static let frameRate = 44100.0 / Double(hop)
    private static let outScale = 1 / (2 * Float(n) * 3.0)
    private static let kLo = Int(150.0 / 44100 * 2048), kHi = Int(5000.0 / 44100 * 2048)

    private let fft = vDSP_create_fftsetup(ResonanceTamer.log2n, FFTRadix(kFFTRadix2))!
    private let window: UnsafeMutablePointer<Float>
    private let inBuf, accum, ready: [UnsafeMutablePointer<Float>]
    private let smPow, gain, persist: [UnsafeMutablePointer<Float>]     // per channel
    // De-harsh: slow 1–4 kHz vs 200 Hz–1 kHz energy balance, per channel.
    private var harshE = [Float](repeating: 0, count: 2), refE = [Float](repeating: 0, count: 2)
    private let frame, re, im, prefix, target: UnsafeMutablePointer<Float>
    private var fill = 0

    private let lock = NSLock()
    private var enabled = true
    func setEnabled(_ on: Bool) { lock.lock(); enabled = on; lock.unlock() }

    init() {
        func buf(_ c: Int, _ v: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: v, count: c); return p
        }
        let n = Self.n, b = Self.bins
        window = buf(n); vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf = [buf(n), buf(n)]; accum = [buf(n), buf(n)]; ready = [buf(Self.hop), buf(Self.hop)]
        smPow = [buf(b), buf(b)]; gain = [buf(b, 1), buf(b, 1)]; persist = [buf(b), buf(b)]
        frame = buf(n); re = buf(b); im = buf(b); prefix = buf(b + 1); target = buf(b, 1)
    }
    deinit {
        vDSP_destroy_fftsetup(fft)
        (inBuf + accum + ready + smPow + gain + persist + [window, frame, re, im, prefix, target]).forEach { $0.deallocate() }
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        let H = Self.hop, N = Self.n
        for i in 0..<count {
            let l = left[i], r = right?[i] ?? l
            left[i] = ready[0][fill]; right?[i] = ready[1][fill]
            inBuf[0][N - H + fill] = l; inBuf[1][N - H + fill] = r
            fill += 1
            if fill == H { fill = 0; frameStep(0); frameStep(1) }
        }
    }

    private func frameStep(_ ch: Int) {
        let N = Self.n, H = Self.hop, B = Self.bins
        lock.lock(); let on = enabled; lock.unlock()
        vDSP_vmul(inBuf[ch], 1, window, 1, frame, 1, vDSP_Length(N))
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        let P = smPow[ch], G = gain[ch], PS = persist[ch]
        let dt = Float(1 / Self.frameRate)
        let pC = Float(1 - exp(-1 / (1.0 * Self.frameRate)))
        let gDown = Float(1 - exp(-1 / (0.040 * Self.frameRate)))
        let gUp = Float(1 - exp(-1 / (0.300 * Self.frameRate)))
        for k in 1..<B { P[k] += pC * ((re[k] * re[k] + im[k] * im[k]) - P[k]) }
        P[0] = P[1]
        prefix[0] = 0
        for k in 0..<B { prefix[k + 1] = prefix[k] + P[k] }
        // Target gains from excess over the ±⅓-octave envelope.
        for k in 0..<B { target[k] = 1 }
        if on {
            for k in Self.kLo...Self.kHi {
                let w = max(3, Int(Float(k) * 0.26))
                let lo = max(1, k - w), hi = min(B - 1, k + w)
                let env = (prefix[hi + 1] - prefix[lo] - P[k]) / Float(hi - lo)
                guard env > 1e-14 else { PS[k] = 0; continue }
                let excessDb = 10 * log10f(P[k] / env)
                // More sensitive where stacked effect copies pile up on held
                // vocal notes (250–900 Hz).
                let hz = Float(k) * 44100 / Float(N)
                // …and 1–4 kHz, where the ear is most sensitive and stacked
                // saturator harmonics pile up (piercing, whistly peaks).
                let thresh: Float = (hz > 250 && hz < 900) || (hz > 1000 && hz < 4000) ? 6 : 8
                if excessDb > thresh {
                    // Persistence: the longer a narrow peak keeps sticking out
                    // (a sustained note ringing), the deeper the cut grows
                    // (+3 dB per second, up to −12 dB in total).
                    // Only peaks that stay at the same frequency for > 1.5 s
                    // are treated as resonances. A played note is also a
                    // narrow peak; cutting it as soon as it stuck out dipped
                    // and released every slow piano note — which itself
                    // sounded like ringing. Real effect resonances sit at a
                    // fixed frequency across many notes, so they still build up.
                    PS[k] = min(4, PS[k] + dt)
                    if PS[k] > 1.5 {
                        let cutDb = min(12, (excessDb - thresh) * 0.5 + (PS[k] - 1.5) * 3)
                        target[k] = powf(10, -cutDb / 20)
                    }
                } else {
                    PS[k] = max(0, PS[k] - 0.5 * dt)
                }
            }
        }
        // De-harsh: a broad dynamic cut centred on ~2.2 kHz. When the 1–4 kHz
        // band carries more energy than a natural (pink-ish) balance against
        // 200 Hz–1 kHz — i.e. it has turned shrill, not merely loud — it is
        // pulled down by 0.6 dB per dB over, up to −6 dB. Level-independent
        // (a ratio), ~150 ms attack / 600 ms release, gains only.
        if on {
            var h: Float = 0, r: Float = 0
            let k1 = Int(1000.0 / 44100 * Double(N)), k4 = Int(4000.0 / 44100 * Double(N)), k02 = Int(200.0 / 44100 * Double(N))
            for k in k1...k4 { h += P[k] }
            for k in k02..<k1 { r += P[k] }
            let rise = harshE[ch] < h ? Float(0.04) : Float(0.01)
            harshE[ch] += rise * (h - harshE[ch]); refE[ch] += 0.02 * (r - refE[ch])
            if refE[ch] > 1e-12 {
                // 1–4 kHz is 2 octaves vs 2.3 for the reference: pink balance ≈ −0.6 dB.
                let overDb = 10 * log10f(max(harshE[ch], 1e-20) / refE[ch]) + 1
                if overDb > 0 {
                    let cut = min(6, overDb * 0.6)
                    for k in (k1 / 2)...min(B - 1, k4 * 2) {
                        let oct = log2f(Float(k) / Float(k1 * 2))       // 0 at ~2 kHz
                        let w = max(0, 1 - abs(oct) / 1.6)
                        target[k] = min(target[k], powf(10, -cut * w / 20))
                    }
                }
            }
        }
        // Glide, smooth across neighbours, apply (gain only — phase untouched).
        for k in 1..<B {
            let t = min(target[k], 0.5 * (target[k] + min(target[max(1, k - 1)], target[min(B - 1, k + 1)])))
            G[k] += (t < G[k] ? gDown : gUp) * (t - G[k])
            re[k] *= G[k]; im[k] *= G[k]
        }

        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(B)) }
        var scale = Self.outScale
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(N))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(N))
        vDSP_vadd(accum[ch], 1, frame, 1, accum[ch], 1, vDSP_Length(N))
        ready[ch].assign(from: accum[ch], count: H)
        accum[ch].assign(from: accum[ch] + H, count: N - H)
        vDSP_vclr(accum[ch] + (N - H), 1, vDSP_Length(H))
        inBuf[ch].assign(from: inBuf[ch] + H, count: N - H)
    }
}

// MARK: - Stereo balancer

/// Keeps the two ears equally loud. Choir voice panning, the blur engines'
/// random phases, group-delay randomness and the reverb's independent L/R
/// tails all wander, so for seconds at a time one side could sit a few dB
/// louder. This tracks each side's loudness over ~3 s (K-weighting-ish
/// high-pass so bass doesn't dominate) and trims the louder side / lifts
/// the quieter one by up to ±3 dB, gliding slowly so it never pumps.
/// The stereo image (width, placement of individual sounds) is untouched —
/// only the long-term L/R level is evened out.
final class StereoBalancer {
    private var hpL = 0.0, hpR = 0.0, xL = 0.0, xR = 0.0
    private var eL = 1e-6, eR = 1e-6
    private var gL: Float = 1, gR: Float = 1
    private let hpA = exp(-2 * Double.pi * 150 / 44100)
    private let envA = 1 - exp(-1 / (3.0 * 44100))        // ~3 s loudness window
    private static let maxDb = 3.0

    func process(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count n: Int) {
        for i in 0..<n {
            let a = Double(l[i]), b = Double(r[i])
            hpL = hpA * (hpL + a - xL); xL = a
            hpR = hpA * (hpR + b - xR); xR = b
            eL += envA * (hpL * hpL - eL); eR += envA * (hpR * hpR - eR)
        }
        // Target: each side moved halfway toward the other (in dB), capped.
        // Below ~-60 dBFS (silence, fades) hold the current gains.
        var tL = gL, tR = gR
        if max(eL, eR) > 1e-7 {
            let diffDb = 10 * log10(max(eL, 1e-12) / max(eR, 1e-12))   // + = left louder
            let c = max(-Self.maxDb, min(Self.maxDb, diffDb / 2))
            tL = Float(pow(10, -c / 20)); tR = Float(pow(10, c / 20))
        }
        // Glide over this block (~0.5 s time constant) — no zipper noise.
        let k = Float(1 - exp(-Double(n) / (0.5 * 44100)))
        let nL = gL + (tL - gL) * k, nR = gR + (tR - gR) * k
        let inv = 1 / Float(n)
        for i in 0..<n {
            let t = Float(i + 1) * inv
            l[i] *= gL + (nL - gL) * t
            r[i] *= gR + (nR - gR) * t
        }
        gL = nL; gR = nR
    }
}

// MARK: - Ring guard

/// Stops notes from "resonating": after a sound stops in the *original*
/// audio, whatever the effects leave behind around that pitch (Wash cloud,
/// Underwater, Smear, Scatter, reverbs — which, being in series, extend each
/// other's tails) must die away at least at a natural room's rate.
///
/// STFT (2048 / hop 256) on the processed signal and on the dry input
/// (delayed by the chain's latency up to this point). Per bin, the dry power
/// — smoothed over ±⅓ octave, and also taken an octave up so Shimmer/Depth
/// undertones count as "explained" — feeds an envelope with instant attack,
/// 60 ms hold and a 50 dB/s fall (≈ 1.2 s RT60). Processed energy may sit
/// up to 3 dB above that envelope (scaled by the chain's long-term gain, so
/// "as loud as the source" is measured at this point's normal level); anything beyond is pulled down (gains
/// only, glided 20 ms down / 120 ms up). Held notes are untouched — the dry
/// input still carries them — and level-independent (ratios only).
final class RingGuard {
    static let latency = 2048
    /// Chain latency from the dry tap to this stage (STFT blurs, group delay,
    /// tape sag, wow & flutter, Murk).
    static let upstreamLatency = 512 + 64 + 2048 + 88 + 88 + MelodyBlur.latency + 3 * 2048
    private static let n = 2048, hop = 256, bins = 1024
    private static let log2n = vDSP_Length(11)
    private static let frameRate = 44100.0 / Double(hop)
    private static let outScale = 1 / (2 * Float(n) * 3.0)
    private static let dlySize = 16384

    private let fft = vDSP_create_fftsetup(RingGuard.log2n, FFTRadix(kFFTRadix2))!
    private let window: UnsafeMutablePointer<Float>
    private let inBuf, accum, ready, dryBuf: [UnsafeMutablePointer<Float>]
    private let env, hold, gain: [UnsafeMutablePointer<Float>]
    private let frame, re, im, dre, dim, pDry, pOut, prefix: UnsafeMutablePointer<Float>
    private let dly = UnsafeMutablePointer<Float>.allocate(capacity: RingGuard.dlySize)
    private var dlyW = 0
    // Long-term (≈3 s) processed vs dry power: the chain's normal gain here.
    private var longOut: Float = 1e-12, longDry: Float = 1e-12
    private var fill = 0

    init() {
        func buf(_ c: Int, _ v: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: v, count: c); return p
        }
        let n = Self.n, b = Self.bins
        window = buf(n); vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf = [buf(n), buf(n)]; accum = [buf(n), buf(n)]; ready = [buf(Self.hop), buf(Self.hop)]; dryBuf = [buf(n)]
        env = [buf(b), buf(b)]; hold = [buf(b), buf(b)]; gain = [buf(b, 1), buf(b, 1)]
        frame = buf(n); re = buf(b); im = buf(b); dre = buf(b); dim = buf(b); pDry = buf(b); pOut = buf(b); prefix = buf(b + 1)
        dly.initialize(repeating: 0, count: Self.dlySize)
    }

    /// `dry` is the mono dry input for these samples (undelayed; delayed here).
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                 dry: UnsafePointer<Float>, count: Int) {
        let H = Self.hop, N = Self.n, D = Self.upstreamLatency, mask = Self.dlySize - 1
        for i in 0..<count {
            dly[dlyW & mask] = dry[i]
            let dd = dly[(dlyW &- D) & mask]
            dlyW &+= 1
            let l = left[i], r = right[i]
            left[i] = ready[0][fill]; right[i] = ready[1][fill]
            inBuf[0][N - H + fill] = l; inBuf[1][N - H + fill] = r
            dryBuf[0][N - H + fill] = dd
            fill += 1
            if fill == H { fill = 0; frameStep() }
        }
    }

    private func forward(_ src: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ m: UnsafeMutablePointer<Float>) {
        vDSP_vmul(src, 1, window, 1, frame, 1, vDSP_Length(Self.n))
        var split = DSPSplitComplex(realp: r, imagp: m)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.bins)) }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
    }

    /// ±⅓-octave smoothed power into `dst` from `re`/`im`.
    private func smoothPower(_ r: UnsafeMutablePointer<Float>, _ m: UnsafeMutablePointer<Float>, into dst: UnsafeMutablePointer<Float>) {
        let B = Self.bins
        prefix[0] = 0
        for k in 0..<B { prefix[k + 1] = prefix[k] + (k == 0 ? 0 : r[k] * r[k] + m[k] * m[k]) }
        for k in 1..<B {
            let w = max(2, Int(Float(k) * 0.26))
            let lo = max(1, k - w), hi = min(B - 1, k + w)
            dst[k] = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
        }
    }

    private func frameStep() {
        let N = Self.n, H = Self.hop, B = Self.bins
        // Dry reference envelope (shared by both channels).
        forward(dryBuf[0], dre, dim)
        smoothPower(dre, dim, into: pDry)
        let fall = powf(10, -50 / 10 / Float(Self.frameRate))     // 50 dB/s
        let holdFrames = Float(0.06 * Self.frameRate)
        let E = env[0], HD = hold[0]
        for k in 1..<B {
            // Undertones: energy an octave up explains energy here.
            let ref = max(pDry[k], 2 * k < B ? pDry[2 * k] : 0)
            if ref >= E[k] { E[k] = ref; HD[k] = holdFrames }
            else if HD[k] > 0 { HD[k] -= 1 }
            else { E[k] = max(ref, E[k] * fall) }
        }
        // Chain gain: what "as loud as the source" means at this point.
        var sumDry: Float = 0, sumOut: Float = 0
        for k in 1..<B { sumDry += pDry[k] }
        let lc = Float(1 - exp(-1 / (3.0 * Self.frameRate)))
        let gDown = Float(1 - exp(-1 / (0.020 * Self.frameRate)))
        let gUp = Float(1 - exp(-1 / (0.120 * Self.frameRate)))
        for ch in 0..<2 {
            forward(inBuf[ch], re, im)
            smoothPower(re, im, into: pOut)
            let G = gain[ch]
            if ch == 0 { for k in 1..<B { sumOut += pOut[k] } }
            let chainGain = max(1, longOut / max(longDry, 1e-20))
            for k in 1..<B {
                let allowed = 2 * E[k] * chainGain                     // +3 dB over the source, at the chain's gain
                let t = pOut[k] > allowed && pOut[k] > 1e-14 ? (allowed / pOut[k]).squareRoot() : 1
                G[k] += (t < G[k] ? gDown : gUp) * (t - G[k])
                re[k] *= G[k]; im[k] *= G[k]
            }
            var split = DSPSplitComplex(realp: re, imagp: im)
            vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))
            frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(B)) }
            var scale = Self.outScale
            vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(N))
            vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(N))
            vDSP_vadd(accum[ch], 1, frame, 1, accum[ch], 1, vDSP_Length(N))
            ready[ch].assign(from: accum[ch], count: H)
            accum[ch].assign(from: accum[ch] + H, count: N - H)
            vDSP_vclr(accum[ch] + (N - H), 1, vDSP_Length(H))
            inBuf[ch].assign(from: inBuf[ch] + H, count: N - H)
        }
        dryBuf[0].assign(from: dryBuf[0] + H, count: N - H)
        if sumDry > 1e-10 { longDry += lc * (sumDry - longDry); longOut += lc * (sumOut - longOut) }
    }
}
