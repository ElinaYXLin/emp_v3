import Foundation

// Grit: comforting texture, three controls (each 0…1, 0 = exactly dry).
//
// Bit Depth — quantizes to 10 → 3 bits *relative to the music's own level*
//   (the step follows a 5 ms/120 ms envelope), so the grain is the same at
//   any volume and silence stays silent. No dither (that was the white
//   noise). The quantization error is band-passed to ~150 Hz–2.5 kHz before
//   being added back, so it reads as soft, sandy grit rather than hiss.
// Soft Clip — asymmetric (even-harmonic) soft clipping of the 100 Hz–1.2 kHz
//   band, auto-gained to the band's own level so it always bites (at 100 % it
//   drives ~4× into the curve). Treble stays clean; the band is split off by
//   subtraction, so everything outside it passes untouched.
// Grain Noise — sparse, random-amplitude crackles (film/dust grain rather
//   than smooth hiss), band-limited to ~200 Hz–5 kHz, whose level follows the
//   music's envelope so silences stay clean. Denser and louder as the knob
//   rises (up to ~−24 dB under the music).
// Corpus — a small mix of a wooden-body resonator: ten broad modes shaped
//   like a guitar/cello body (110 Hz–1.9 kHz, Q 8). Each mode sways slowly
//   (±1.5 %, its own 0.05–0.15 Hz) so no resonance can settle into a fixed
//   standing tone. Up to about −10 dB under the music.
// Rattle — a soft sympathetic buzz on bass peaks, like a loose part on an
//   old speaker: the bass waveform's peaks are rectified, clipped and
//   high-passed (above ~1.5 kHz), synced to the bass. Up to ~−24 dB.
final class Grit {
    private static let sr = 44100.0
    private let lock = NSLock()
    private var tBits = 0.0, tClip = 0.0, tNoise = 0.0, tCorpus = 0.0, tRattle = 0.0
    private var bits = 0.0, clip = 0.0, noise = 0.0, corpus = 0.0, rattle = 0.0
    // Corpus modes: per channel state (2 each), shared coefficients updated per block.
    private static let modeHz: [Double] = [110, 205, 290, 390, 470, 610, 780, 1040, 1380, 1900]
    private static let modeGain: [Double] = [1.0, 0.9, 0.8, 0.7, 0.65, 0.55, 0.5, 0.42, 0.35, 0.28]
    private var modeState = [[Double]](repeating: [Double](repeating: 0, count: 40), count: 2)   // x1 x2 y1 y2 ×10
    private var modeLFO: [Double] = (0..<10).map { Double($0) * 0.61 }
    private let modeRate: [Double] = (0..<10).map { 0.05 + 0.1 * Double(($0 * 7) % 10) / 9 }
    private var rattleState = [[Double]](repeating: [0, 0, 0, 0, 0], count: 2)   // bassLP1, bassLP2, env, hp1, hp2
    private var rng: UInt64 = 0x6A17_D057_C0FF_EE11

    private struct Chan { var e1 = 0.0, e2 = 0.0, a1 = 0.0, a2 = 0.0, b1 = 0.0, b2 = 0.0, n1 = 0.0, n2 = 0.0, nh = 0.0, bandEnv = 0.0, qEnv = 0.0, errHPs = 0.0 }
    private var c0 = Chan(), c1 = Chan()
    private var env = 0.0

    func set(bits b: Double, softClip s: Double, noise n: Double, corpus c: Double = 0, rattle ra: Double = 0) {
        lock.lock()
        tBits = max(0, min(1, b)); tClip = max(0, min(1, s)); tNoise = max(0, min(1, n))
        tCorpus = max(0, min(1, c)); tRattle = max(0, min(1, ra))
        lock.unlock()
    }

    @inline(__always) private func rand() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let tb = tBits, tc = tClip, tn = tNoise, tco = tCorpus, tra = tRattle; lock.unlock()
        if tb == 0 && tc == 0 && tn == 0 && tco == 0 && tra == 0
            && bits < 1e-4 && clip < 1e-4 && noise < 1e-4 && corpus < 1e-4 && rattle < 1e-4 {
            bits = 0; clip = 0; noise = 0; corpus = 0; rattle = 0; return
        }
        let g = 1 - exp(-Double(count) / (0.05 * Self.sr))
        bits += (tb - bits) * g; clip += (tc - clip) * g; noise += (tn - noise) * g
        corpus += (tco - corpus) * g; rattle += (tra - rattle) * g
        if corpus > 1e-4 || rattle > 1e-4 { processBody(left: left, right: right, count: count) }
        let sr = Self.sr

        // Bit depth: 12 → 4 bits relative to the envelope; fades in over the first quarter.
        let steps = pow(2, 10 - 7 * bits) / 2
        let bitMix = min(1, bits * 4)
        let errLP = 1 - exp(-2 * Double.pi * 2500 / sr), errHP = 1 - exp(-2 * Double.pi * 150 / sr)
        let qAtk = 1 - exp(-1 / (0.005 * sr)), qRel = 1 - exp(-1 / (0.120 * sr))
        // Soft clip band.
        let lo = 1 - exp(-2 * Double.pi * 100 / sr), hi = 1 - exp(-2 * Double.pi * 1200 / sr)
        let drive = 0.5 + 3.5 * clip, bias = 0.35, clipMix = min(1, clip * 4)
        let off = tanh(bias)
        // Grain noise.
        let rate = (300 + 4000 * noise * noise) / sr                // crackles per sample
        let level = (0.0016 + 0.024 * noise * noise)
        let nLP = 1 - exp(-2 * Double.pi * 5000 / sr), nHP = 1 - exp(-2 * Double.pi * 200 / sr)
        let eAtk = 1 - exp(-1 / (0.010 * sr)), eRel = 1 - exp(-1 / (0.250 * sr))
        var a = c0, b = c1

        for i in 0..<count {
            let xl = Double(left[i]), xr = right.map { Double($0[i]) } ?? xl
            let m = max(abs(xl), abs(xr))
            env += (m > env ? eAtk : eRel) * (m - env)
            // Shared grain impulse (mono grain reads as texture, not width).
            var imp = 0.0
            if noise > 1e-4 && rand() < rate { imp = (rand() * 2 - 1) * level * env * 4 }
            func run(_ c: inout Chan, _ x: Double, _ jitter: Double) -> Double {
                var y = x
                if clip > 1e-4 {
                    c.a1 += hi * (y - c.a1); c.a2 += hi * (c.a1 - c.a2)          // < 1.2 kHz
                    c.b1 += lo * (c.a2 - c.b1); c.b2 += lo * (c.b1 - c.b2)       // < 100 Hz
                    let band = c.a2 - c.b2
                    let ab = abs(band)
                    c.bandEnv += (ab > c.bandEnv ? qAtk : qRel) * (ab - c.bandEnv)
                    // Auto-gain: the band's own peak level hits the curve at `drive`.
                    let k = drive / max(c.bandEnv, 1e-5)
                    let shaped = (tanh(band * k + bias) - off) / k
                    y += (shaped - band) * clipMix
                }
                if bits > 1e-4 {
                    // Quantize relative to the envelope; keep only the band-passed error.
                    let a = abs(y)
                    c.qEnv += (a > c.qEnv ? qAtk : qRel) * (a - c.qEnv)
                    let q = max(c.qEnv, 1e-5) / steps
                    let err = (y / q).rounded() * q - y
                    c.e1 += errLP * (err - c.e1); c.e2 += errLP * (c.e1 - c.e2)
                    c.errHPs += errHP * (c.e2 - c.errHPs)
                    y += (c.e2 - c.errHPs) * bitMix * 3
                }
                if noise > 1e-4 {
                    c.n1 += nLP * (imp * jitter - c.n1); c.n2 += nLP * (c.n1 - c.n2)
                    c.nh += nHP * (c.n2 - c.nh)
                    y += (c.n2 - c.nh) * 6
                }
                return y
            }
            left[i] = Float(run(&a, xl, 1))
            if let r = right { r[i] = Float(run(&b, xr, 0.85)) }
        }
        c0 = a; c1 = b
    }

    /// Corpus resonator + rattle (run before the other grit stages).
    private func processBody(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        let sr = Self.sr
        // Corpus: band-pass modes (RBJ constant 0 dB peak), coefficients per block.
        var b0 = [Double](repeating: 0, count: 10), a1 = b0, a2 = b0
        let q = 8.0
        for m in 0..<10 {
            modeLFO[m] += 2 * Double.pi * modeRate[m] * Double(count) / sr
            let f = Self.modeHz[m] * (1 + 0.015 * sin(modeLFO[m]))
            let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            b0[m] = alpha / a0; a1[m] = -2 * cos(w) / a0; a2[m] = (1 - alpha) / a0
        }
        let wet = 1.0 * corpus                                         // ≈ −10 dB at full
        let lpB = 1 - exp(-2 * Double.pi * 150 / sr)
        let hpR = exp(-2 * Double.pi * 1500 / sr)
        let envA = 1 - exp(-1 / (0.005 * sr)), envR = 1 - exp(-1 / (0.150 * sr))
        let rLevel = 0.95 * rattle
        for ch in 0..<(right == nil ? 1 : 2) {
            let p = ch == 0 ? left : right!
            var st = modeState[ch], rs = rattleState[ch]
            for i in 0..<count {
                let x = Double(p[i])
                var y = x
                if corpus > 1e-4 {
                    var body = 0.0
                    for m in 0..<10 {
                        let o = 4 * m
                        let out = b0[m] * x - b0[m] * st[o + 1] - a1[m] * st[o + 2] - a2[m] * st[o + 3]
                        st[o + 1] = st[o]; st[o] = x; st[o + 3] = st[o + 2]; st[o + 2] = out
                        body += out * Self.modeGain[m]
                    }
                    y += body * wet
                }
                if rattle > 1e-4 {
                    rs[0] += lpB * (x - rs[0]); rs[1] += lpB * (rs[0] - rs[1])
                    let bass = rs[1], ab = abs(bass)
                    rs[2] += (ab > rs[2] ? envA : envR) * (ab - rs[2])
                    // Buzz only on the top of bass peaks (loose part lifting off).
                    let th = 0.6 * rs[2]
                    let lift = max(0, ab - th) / max(rs[2], 1e-6)
                    let buzz = tanh(lift * 12) * (bass >= 0 ? 1 : -1) * rs[2]
                    let hp = hpR * (rs[3] + buzz - rs[4]); rs[4] = buzz; rs[3] = hp
                    y += hp * rLevel
                }
                p[i] = Float(y)
            }
            modeState[ch] = st; rattleState[ch] = rs
        }
    }
}
