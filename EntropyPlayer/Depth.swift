import Foundation
import Accelerate

// Depth: undertones (subharmonics) under the music — f/2, f/3, f/4, f/5,
// generated in the frequency domain and heavily spectrally blurred.
//
// A phase vocoder (1024-point Hann STFT, hop 256, 75 % overlap) measures the
// true frequency of every bin in the 700 Hz–5 kHz band of the (mono) input,
// then writes each one's magnitude to the bins at f/2, f/3, f/4 and f/5
// (keeping the strongest contributor per output bin). Output phases advance
// at exactly those frequencies, so the undertones are clean, steady tones,
// not the grainy, comb-filtered sound of a time-domain pitch shifter.
//
// Heavy spectral blur: each output bin's magnitude swells in and lingers,
// both set by the Shimmer knob (0.05→0.30 s swell, 0.3→2.0 s linger), so the
// undertones bloom and dissolve like a pad. They are then darkened (4-pole
// 1.1 kHz low-pass, 24 dB/oct), kept above 80 Hz, and run
// through a short allpass diffuser per side for a slight stereo spread.
//
// Latency of the undertones: 1024 samples (~23 ms). The dry signal is not
// delayed. The knob adds undertones one at a time: at 0 only the original
// note; at 25 % the octave below fades in, then f/3, f/4 and f/5 by 100 %,
// each a little quieter. Power-compensated, so turning it up deepens rather
// than louders. Realtime-safe: all buffers preallocated.
final class Depth {
    private static let sr = 44100.0
    private static let n = 1024, hop = 256, bins = 512
    private static let log2n = vDSP_Length(10)
    private static let frameRate = sr / Double(hop)
    private static let outScale = 1 / (2 * Float(n) * 1.5)       // zrip round trip ×2N, Hann² OLA at 75 % = 1.5
    private static let kLo = Int(700 / sr * Double(n)), kHi = Int(5000 / sr * Double(n))
    private static let divisors = [2.0, 3.0, 4.0, 5.0]
    private static let levels = [0.70, 0.55, 0.45, 0.38]
    private static let calib: Float = 1.6                         // single-bin output vs. a Hann main lobe
    private static let apLen = [[223, 367, 491, 613], [241, 389, 467, 659]]
    private static let apG = 0.55

    private let lock = NSLock()
    private var target = 0.0, amount = 0.0, blurTarget = 0.5, blur = 0.5

    private let fft = vDSP_create_fftsetup(Depth.log2n, FFTRadix(kFFTRadix2))!
    private let window, inBuf, accum, ready, frame, re, im, prevPhase, outPhase, smooth, magOut, freqOut: UnsafeMutablePointer<Float>
    private var fill = 0, readPos = 0
    private var lpA = 0.0, lpB = 0.0, lpC2 = 0.0, lpD = 0.0, hpS = 0.0, hPrev = 0.0
    private let ap: [[UnsafeMutablePointer<Double>]]
    private var apIdx = [[0, 0, 0, 0], [0, 0, 0, 0]]

    init() {
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        let n = Self.n, b = Self.bins
        window = buf(n); vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf = buf(n); accum = buf(n); ready = buf(Self.hop); frame = buf(n)
        re = buf(b); im = buf(b); prevPhase = buf(b); outPhase = buf(b); smooth = buf(b); magOut = buf(b); freqOut = buf(b)
        ap = Self.apLen.map { $0.map { c in
            let p = UnsafeMutablePointer<Double>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p } }
    }
    deinit {
        vDSP_destroy_fftsetup(fft)
        [window, inBuf, accum, ready, frame, re, im, prevPhase, outPhase, smooth, magOut, freqOut].forEach { $0.deallocate() }
        ap.flatMap { $0 }.forEach { $0.deallocate() }
    }

    func setAmount(_ a: Double) { lock.lock(); target = max(0, min(1, a)); lock.unlock() }
    /// Swell and linger follow the Shimmer knob (0…1): 0.05→0.30 s swell, 0.3→2.0 s linger.
    func setBlur(_ b: Double) { lock.lock(); blurTarget = max(0, min(1, b)); lock.unlock() }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let t = target, bt = blurTarget; lock.unlock()
        blur += (bt - blur) * (1 - exp(-Double(count) / (0.05 * Self.sr)))
        let H = Self.hop, N = Self.n
        let off = t == 0 && amount < 1e-4
        if off { amount = 0 } else { amount += (t - amount) * (1 - exp(-Double(count) / (0.05 * Self.sr))) }
        var power = 0.0
        for k in 0..<4 { let g = min(1, max(0, amount * 4 - Double(k))) * Self.levels[k]; power += g * g * 0.5 }
        let comp = 1 / (1 + power).squareRoot()
        let lpC = 1 - exp(-2 * Double.pi * 1100 / Self.sr)
        let hpOut = exp(-2 * Double.pi * 80 / Self.sr)

        for i in 0..<count {
            let l = Double(left[i]), r = right.map { Double($0[i]) } ?? l
            // Undertone sample out, mono sample in (STFT runs even when off so it's warm).
            let u = Double(ready[fill])
            inBuf[N - H + fill] = Float((l + r) * 0.5)
            fill += 1
            if fill == H { fill = 0; processFrame(active: !off) }
            if off { continue }

            // 4-pole low-pass at 1.1 kHz (24 dB/oct): undertones stay round, never harsh.
            lpA += lpC * (u - lpA); lpB += lpC * (lpA - lpB)
            lpC2 += lpC * (lpB - lpC2); lpD += lpC * (lpC2 - lpD)
            hpS = hpOut * (hpS + lpD - hPrev); hPrev = lpD
            var outL = hpS, outR = hpS
            for ch in 0..<2 {
                var v = ch == 0 ? outL : outR
                let bufs = ap[ch]
                for a in 0..<4 {
                    let b = bufs[a], len = Self.apLen[ch][a], k = apIdx[ch][a]
                    let dly = b[k]
                    let wv = v + Self.apG * dly
                    b[k] = wv
                    v = dly - Self.apG * wv
                    apIdx[ch][a] = k + 1 == len ? 0 : k + 1
                }
                if ch == 0 { outL = v } else { outR = v }
            }
            left[i] = Float((l + outL) * comp)
            right?[i] = Float((r + outR) * comp)
        }
    }

    private func processFrame(active: Bool) {
        let N = Self.n, H = Self.hop, B = Self.bins
        vDSP_vmul(inBuf, 1, window, 1, frame, 1, vDSP_Length(N))
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        let twoPi = Float.pi * 2, expect = twoPi * Float(H) / Float(N)
        vDSP_vclr(magOut, 1, vDSP_Length(B))
        for j in 0..<B { freqOut[j] = Float(j) }

        // Source bins: true frequency (in bins) from the phase difference.
        var gains = (Float(0), Float(0), Float(0), Float(0))
        if active {
            func g(_ k: Int) -> Float { Float(min(1, max(0, amount * 4 - Double(k))) * Self.levels[k]) }
            gains = (g(0), g(1), g(2), g(3))
        }
        for k in Self.kLo...Self.kHi {
            let x = re[k], y = im[k]
            let ph = atan2f(y, x)
            var d = ph - prevPhase[k] - expect * Float(k)
            prevPhase[k] = ph
            d -= twoPi * (d / twoPi).rounded()
            guard active else { continue }
            let f = Float(k) + d / expect                              // true frequency, bins
            let m = (x * x + y * y).squareRoot()
            for (idx, div) in Self.divisors.enumerated() {
                let gk: Float = idx == 0 ? gains.0 : idx == 1 ? gains.1 : idx == 2 ? gains.2 : gains.3
                if gk == 0 { continue }
                let fj = f / Float(div)
                let j = Int(fj.rounded())
                guard j >= 1 && j < B else { continue }
                let v = m * gk
                if v > magOut[j] { magOut[j] = v; freqOut[j] = fj }
            }
        }
        // Make sure bins below kLo keep their phase tracking when only reading.
        if !active {
            vDSP_vclr(smooth, 1, vDSP_Length(B))
            vDSP_vclr(ready, 1, vDSP_Length(H))
            inBuf.assign(from: inBuf + H, count: N - H)
            return
        }

        // Heavy spectral blur + phase accumulation at the undertone frequencies.
        let aAtk = Float(1 - exp(-1 / ((0.05 + 0.25 * blur) * Self.frameRate)))
        let aRel = Float(1 - exp(-1 / ((0.3 + 1.7 * blur) * Self.frameRate)))
        re[0] = 0; im[0] = 0                                           // DC / Nyquist pack
        for j in 1..<B {
            var s = smooth[j]
            let m = magOut[j] * Self.calib
            s += (m > s ? aAtk : aRel) * (m - s)
            smooth[j] = s
            var p = outPhase[j] + expect * freqOut[j]
            p -= twoPi * (p / twoPi).rounded()
            outPhase[j] = p
            re[j] = s * cosf(p); im[j] = s * sinf(p)
        }

        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(B)) }
        var scale = Self.outScale
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(N))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(N))
        vDSP_vadd(accum, 1, frame, 1, accum, 1, vDSP_Length(N))
        ready.assign(from: accum, count: H)
        accum.assign(from: accum + H, count: N - H)
        vDSP_vclr(accum + (N - H), 1, vDSP_Length(H))
        inBuf.assign(from: inBuf + H, count: N - H)
    }
}
