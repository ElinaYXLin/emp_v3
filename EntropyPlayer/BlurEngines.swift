import Foundation
import Accelerate

// Blur section engines that run in their own STFT (Smoke, Underwater). Each
// always runs (constant 2048-sample latency) and passes the input through
// exactly at strength 0. Smear, Wash, Swell and Diffuse live in MelodyBlur.swift.
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
            let out = S[k] * tilt
            let live = min(m, S[k]) * tilt / max(m, 1e-12)
            let e = max(0, out - m * tilt)
            re[k] = re[k] * live + e * cosf(P[k]); im[k] = im[k] * live + e * sinf(P[k])
        }
    }
    override func idle(_ ch: Int) { for k in 1..<1024 { st[ch][k] = (re[k]*re[k] + im[k]*im[k]).squareRoot() } }
}
