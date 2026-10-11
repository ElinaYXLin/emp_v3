import Foundation
import Accelerate

// Spectral Scatter (replaces Spectral Blur): a spectral delay. Each frequency
// band is echoed back at its own delay — 30–400 ms, varying smoothly across
// pitch — with feedback, so the music breaks into cascading, time-scattered
// fragments that trail behind it.
//
// STFT (2048 Hann, hop 256, 87.5 % overlap). Per bin, a delay line of complex
// spectra (72 frames ≈ 418 ms). Strength 0…1 scales together: the echo level
// (0 → 0.85), feedback (0 → 0.5), how far the delays reach (¼ → full), and
// the live level (1 → 0.55). At 0 the output is the input exactly (latency is
// a constant 2048 samples). Delayed spectra keep their own phases, so the
// echoes are clean copies of the band, not resynthesized texture.
final class SpectralBlur {
    private static let n = 2048, hop = 256, bins = 1024
    private static let log2n = vDSP_Length(11)
    private static let depth = 72
    private static let outScale = 1 / (2 * Float(n) * 3.0)

    private let lock = NSLock()
    private var targetStrength = 0.0, strength = 0.0

    private let fft = vDSP_create_fftsetup(SpectralBlur.log2n, FFTRadix(kFFTRadix2))!
    private let window: UnsafeMutablePointer<Float>
    private let inBuf, accum, ready, lineRe, lineIm: [UnsafeMutablePointer<Float>]
    private let frame, re, im: UnsafeMutablePointer<Float>
    private let maxDelay: UnsafeMutablePointer<Int>             // per bin, in frames, at full strength
    private var w = [0, 0]
    private var fill = 0

    init() {
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        let n = Self.n, b = Self.bins, D = Self.depth
        window = buf(n); vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf = [buf(n), buf(n)]; accum = [buf(n), buf(n)]; ready = [buf(Self.hop), buf(Self.hop)]
        lineRe = [buf(b * D), buf(b * D)]; lineIm = [buf(b * D), buf(b * D)]
        frame = buf(n); re = buf(b); im = buf(b)
        maxDelay = .allocate(capacity: b)
        for k in 0..<b {
            let o = log2f(Float(max(k, 1)))
            let v = 0.5 + 0.5 * (sinf(o * 3.1 + 0.7) * 0.6 + sinf(o * 7.3 + 2.0) * 0.4)
            maxDelay[k] = max(5, min(70, Int(5 + v * 64)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        (inBuf + accum + ready + lineRe + lineIm + [window, frame, re, im]).forEach { $0.deallocate() }
        maxDelay.deallocate()
    }

    /// strength: 0 (dry) … 1 (full scatter).
    func setStrength(_ s: Double) {
        lock.lock(); targetStrength = max(0, min(1, s)); lock.unlock()
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        let H = Self.hop, N = Self.n
        for i in 0..<count {
            let l = left[i], r = right?[i] ?? l
            left[i] = ready[0][fill]
            right?[i] = ready[1][fill]
            inBuf[0][N - H + fill] = l
            inBuf[1][N - H + fill] = r
            fill += 1
            if fill == H {
                fill = 0
                lock.lock(); let t = targetStrength; lock.unlock()
                strength += (t - strength) * 0.08                  // per-frame glide
                frameStep(0); frameStep(1)
            }
        }
    }

    private func frameStep(_ ch: Int) {
        let N = Self.n, H = Self.hop, B = Self.bins, D = Self.depth
        vDSP_vmul(inBuf[ch], 1, window, 1, frame, 1, vDSP_Length(N))
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        let s = Float(strength), LR = lineRe[ch], LI = lineIm[ch], wi = w[ch]
        let wet = 0.85 * s, dry = 1 - 0.45 * s, fb = 0.5 * s
        let reach = 0.25 + 0.75 * s
        for k in 1..<B {
            let d = max(5, Int(Float(maxDelay[k]) * reach))
            let ri = ((wi - d) % D + D) % D
            let dr = LR[k * D + ri], di = LI[k * D + ri]
            LR[k * D + wi] = re[k] + fb * dr; LI[k * D + wi] = im[k] + fb * di
            if s > 1e-4 {
                re[k] = dry * re[k] + wet * dr; im[k] = dry * im[k] + wet * di
            }
        }
        w[ch] = (wi + 1) % D

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
