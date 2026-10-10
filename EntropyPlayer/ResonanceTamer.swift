import Foundation
import Accelerate

// Resonance tamer: catches narrow resonances that build up when several
// effects stack colour in the same place (e.g. ~400–500 Hz) and gently pulls
// them down — a "soothing" dynamic EQ.
//
// STFT (2048 Hann, hop 256). Per bin, the magnitude is smoothed over ~60 ms
// (so only *sustained* peaks count, not transients) and compared with a
// local spectral envelope: the mean power over ±⅓ octave. Where a bin stands
// more than 5 dB above its surroundings (150 Hz–4 kHz), its gain is lowered by
// 0.8 dB per dB of excess, up to −8 dB; gains glide (40 ms down, 300 ms back)
// and are smoothed across neighbouring bins. Only real gains are applied —
// phases are untouched — so it can't add warble or stutter. With nothing
// sticking out it is an exact pass-through (constant 2048-sample latency).
final class ResonanceTamer {
    static let latency = 2048
    private static let n = 2048, hop = 256, bins = 1024
    private static let log2n = vDSP_Length(11)
    private static let frameRate = 44100.0 / Double(hop)
    private static let outScale = 1 / (2 * Float(n) * 3.0)
    private static let kLo = Int(150.0 / 44100 * 2048), kHi = Int(4000.0 / 44100 * 2048)

    private let fft = vDSP_create_fftsetup(ResonanceTamer.log2n, FFTRadix(kFFTRadix2))!
    private let window: UnsafeMutablePointer<Float>
    private let inBuf, accum, ready: [UnsafeMutablePointer<Float>]
    private let smPow, gain: [UnsafeMutablePointer<Float>]     // per channel
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
        smPow = [buf(b), buf(b)]; gain = [buf(b, 1), buf(b, 1)]
        frame = buf(n); re = buf(b); im = buf(b); prefix = buf(b + 1); target = buf(b, 1)
    }
    deinit {
        vDSP_destroy_fftsetup(fft)
        (inBuf + accum + ready + smPow + gain + [window, frame, re, im, prefix, target]).forEach { $0.deallocate() }
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

        let P = smPow[ch], G = gain[ch]
        let pC = Float(1 - exp(-1 / (0.060 * Self.frameRate)))
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
                guard env > 1e-14 else { continue }
                let excessDb = 10 * log10f(P[k] / env)
                if excessDb > 5 {
                    let cutDb = min(8, (excessDb - 5) * 0.8)
                    target[k] = powf(10, -cutDb / 20)
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
