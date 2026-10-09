import Foundation

// MARK: - Tape Hysteresis

// Magnetic tape doesn't respond to where the signal *is*, only to where it
// has *been*: magnetization lags and rounds off at every turnaround, then
// saturates. That lag (a hysteresis loop) is what gives tape its soft,
// slightly compressed, "weighted" feel — something a memoryless curve like
// tanh can't do.
//
// Model: a Prandtl–Ishlinskii hysteresis (a weighted sum of "play"/backlash
// operators of different widths — the standard rate-independent hysteresis
// building block) followed by tanh saturation. Loop widths scale with the
// signal's own envelope, mimicking AC bias: quiet passages stay clean
// instead of getting stuck in a dead zone, and the loop keeps the same
// shape at every level. A strength-dependent head bump (+2.5 dB @ 90 Hz)
// and gentle top-end loss complete the tape voicing.
//
// Strength 0…1 scales drive, loop width and voicing together.
final class TapeHysteresis {
    private static let sr = 44100.0
    private static let widths: [Double] = [0.06, 0.14, 0.28]    // × envelope × strength
    private static let w0 = 0.4, wi = 0.2                       // identity + 3 play operators

    private let lock = NSLock()
    private var target = 0.0
    private var strength = 0.0
    private var play = [[Double]](repeating: [0, 0, 0], count: 2)
    private var env = [0.0, 0.0]
    private var lp = [0.0, 0.0]
    private var hpS = [[Double]](repeating: [0, 0, 0, 0], count: 2)
    private let headBump = PeakingBiquad()
    private let envAtk = 1 - exp(-1 / (0.010 * 44100)), envRel = 1 - exp(-1 / (0.200 * 44100))
    private let hp: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) = {
        let w0 = 2 * Double.pi * 10 / 44100, alpha = sin(w0) / (2 * 0.7071), c = cos(w0), a0 = 1 + alpha
        return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
    }()

    init() { headBump.setParameters(frequency: 90, q: 0.9, gainDb: 0) }

    func setStrength(_ s: Double) {
        let v = max(0, min(1, s))
        lock.lock(); target = v; lock.unlock()
        headBump.setParameters(gainDb: 2.5 * v)
    }

    func process(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        lock.lock(); let t = target; lock.unlock()
        if t == 0 && strength < 1e-5 { strength = 0; return }
        let glide = 1 - exp(-1 / (0.05 * Self.sr))
        var p = play[ch], e = env[ch], l = lp[ch], st = hpS[ch]
        let lpCoef = 1 - exp(-2 * Double.pi * (20000 - 11000 * strength) / Self.sr)
        for i in 0..<count {
            if ch == 0 { strength += (t - strength) * glide }
            let s = strength
            let g = 1 + 2 * s
            let x = Double(buf[i])
            let v = x * g
            let a = abs(v)
            e += (a > e ? envAtk : envRel) * (a - e)
            var m = Self.w0 * v
            var shrink = 0.0
            for k in 0..<3 {
                let r = s * Self.widths[k] * e
                if v > p[k] + r { p[k] = v - r } else if v < p[k] - r { p[k] = v + r }
                m += Self.wi * p[k]
                shrink += Self.wi * s * Self.widths[k]
            }
            m /= max(0.2, 1 - shrink)                        // keep small-signal gain ≈ g
            var y = tanh(m) / g                              // saturate, return to unity-ish gain
            // DC guard (play operators can park an offset).
            let o = hp.b0 * y + hp.b1 * st[0] + hp.b2 * st[1] - hp.a1 * st[2] - hp.a2 * st[3]
            st[1] = st[0]; st[0] = y; st[3] = st[2]; st[2] = o
            y = o
            // Top-end loss: one-pole low-pass 20 kHz → 9 kHz with strength
            // (coefficient computed once per block; strength glides slowly).
            l += lpCoef * (y - l)
            // Blend so strength 0 is exactly dry.
            buf[i] = Float(x + (l - x) * min(1, s * 4))
        }
        play[ch] = p; env[ch] = e; lp[ch] = l; hpS[ch] = st
        headBump.process(buf, count: count, channel: ch)
    }
}

// MARK: - Tape Sag

// An old tape machine struggling under loud passages: its level dips, its
// top end dulls, and its motor briefly slows — pitch sags a touch — then
// everything recovers as the music relaxes. Driven by a slow RMS envelope,
// so it breathes with the song rather than reacting to single transients.
//
// Strength 0…1 scales all three: up to −6 dB of dip, cutoff down to 6 kHz,
// and up to 4 ms of extra (smoothed) delay → a small, slow pitch droop.
final class TapeSag {
    private static let sr = 44100.0
    private static let bufSize = 1024
    private static let baseDelay = 88.0                 // 2 ms, constant latency
    private static let maxExtraDelay = 176.0            // +4 ms at full sag

    private let lock = NSLock()
    private var target = 0.0
    private var strength = 0.0
    private var power = 0.0
    private var delaySmooth = 0.0
    private var lp: [Float] = [0, 0]
    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: TapeSag.bufSize)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: TapeSag.bufSize)
    private var w = 0
    private let atk = 1 - exp(-1 / (0.030 * 44100)), rel = 1 - exp(-1 / (0.400 * 44100))
    private let delayGlide = 1 - exp(-1 / (0.150 * 44100))

    init() {
        bufL.initialize(repeating: 0, count: Self.bufSize)
        bufR.initialize(repeating: 0, count: Self.bufSize)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    func setStrength(_ s: Double) {
        lock.lock(); target = max(0, min(1, s)); lock.unlock()
    }

    @inline(__always) private func read(_ b: UnsafeMutablePointer<Float>, _ d: Double) -> Float {
        let pos = Double(w) - d, i = Int(floor(pos)), t = Float(pos - Double(i)), mask = Self.bufSize - 1
        let a = b[i & mask], c = b[(i &+ 1) & mask]
        return a + (c - a) * t
    }

    /// Stereo in place (always runs so its 2 ms latency stays constant).
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let t = target; lock.unlock()
        let glide = 1 - exp(-1 / (0.05 * Self.sr))
        let mask = Self.bufSize - 1
        for i in 0..<count {
            strength += (t - strength) * glide
            let l = left[i], r = right?[i] ?? l
            bufL[w & mask] = l; bufR[w & mask] = r
            w &+= 1

            let p = Double(max(l * l, r * r))
            power += (p > power ? atk : rel) * (p - power)
            let level = power.squareRoot()
            let over = max(0, min(1, (level - 0.1) / 0.9))        // above ~−20 dBFS
            let sag = strength * over

            delaySmooth += (Self.maxExtraDelay * sag - delaySmooth) * delayGlide
            let d = Self.baseDelay + delaySmooth
            var yl = read(bufL, d), yr = read(bufR, d)

            let gain = Float(1 - 0.5 * sag)                       // up to −6 dB
            let fc = 18000 - 12000 * sag
            let a = Float(1 - exp(-2 * Double.pi * fc / Self.sr))
            lp[0] += a * (yl - lp[0]); lp[1] += a * (yr - lp[1])
            if strength > 1e-5 { yl = lp[0] * gain; yr = lp[1] * gain }
            left[i] = yl
            right?[i] = yr
        }
    }
}

// MARK: - Wow & Flutter

// Speed instability of a tape transport, as a modulated delay (pitch
// deviation = −d(delay)/dt):
//   • wow: slow drift from an uneven reel. A sine whose rate wanders
//     0.4–1.6 Hz, plus a once-per-rotation bump (a sharper pulse at the
//     same rate), up to ±0.5 % speed (≈ ±9 cents) at full strength.
//   • flutter: capstan/roller ripple, 6–14 Hz wandering, up to ±0.12 %.
// Both channels share the transport (same modulation), as on real tape.
// A fixed 2 ms centre delay is always present, so latency stays constant and
// strength 0 is a pure 2 ms delay. Realtime-safe.
final class TapeWowFlutter {
    private static let sr = 44100.0
    static let latency = 88                                       // 2 ms centre
    private static let size = 1024

    private let lock = NSLock()
    private var target = 0.0, strength = 0.0
    private let buf = [UnsafeMutablePointer<Float>.allocate(capacity: TapeWowFlutter.size),
                       UnsafeMutablePointer<Float>.allocate(capacity: TapeWowFlutter.size)]
    private var w = 0
    private var wowPh = 0.0, flPh = 0.0
    private var wowRate = 0.9, wowRateT = 0.9, flRate = 9.0, flRateT = 9.0
    private var retarget = 0
    private var rng: UInt64 = 0x77F1_7A7E_0BAD_CAFE

    init() { buf.forEach { $0.initialize(repeating: 0, count: Self.size) } }
    deinit { buf.forEach { $0.deallocate() } }

    func setStrength(_ s: Double) { lock.lock(); target = max(0, min(1, s)); lock.unlock() }

    private func rand() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let t = target; lock.unlock()
        let sr = Self.sr, mask = Self.size - 1
        strength += (t - strength) * (1 - exp(-Double(count) / (0.05 * sr)))
        // Rates wander: a new target every ~3 s, glided.
        retarget -= count
        if retarget <= 0 {
            retarget = Int(sr * (2 + 2 * rand()))
            wowRateT = 0.4 + 1.2 * rand(); flRateT = 6 + 8 * rand()
        }
        let rg = 1 - exp(-Double(count) / (1.5 * sr))
        wowRate += (wowRateT - wowRate) * rg; flRate += (flRateT - flRate) * rg
        // Delay amplitude for a given peak speed deviation: A = dev / (2π f).
        let wowA = 0.005 * strength / (2 * .pi * wowRate) * sr
        let flA = 0.0012 * strength / (2 * .pi * flRate) * sr
        let wInc = wowRate / sr, fInc = flRate / sr
        let centre = Double(Self.latency)
        let L = buf[0], R = buf[1]
        for i in 0..<count {
            L[w] = left[i]; R[w] = right?[i] ?? left[i]
            wowPh += wInc; if wowPh >= 1 { wowPh -= 1 }
            flPh += fInc; if flPh >= 1 { flPh -= 1 }
            let a = 2 * Double.pi * wowPh
            // Sine + once-per-rotation bump (sin³ sharpens the peak).
            let s = sin(a), bump = s * s * s
            let d = centre + wowA * (0.75 * s + 0.25 * bump) + flA * sin(2 * .pi * flPh)
            let pos = Double(w) - d
            let fl = pos.rounded(.down), fr = Float(pos - fl)
            let i0 = Int(fl) & mask, i1 = (i0 + 1) & mask
            left[i] = L[i0] + (L[i1] - L[i0]) * fr
            right?[i] = R[i0] + (R[i1] - R[i0]) * fr
            w = (w + 1) & mask
        }
    }
}

// MARK: - Self-Erasure

// Tape saturates high frequencies first: during loud, bright passages the
// recording bias partly erases the treble it is laying down, so the top end
// squashes while the mids stay put. Model: split at ~3.5 kHz (complementary
// one-pole pair, so the bands sum back exactly), follow the treble band's
// envelope (1 ms attack / 120 ms release), and compress and softly saturate
// only that band. Strength sets how hard: up to ~−12 dB of treble on loud
// bright material, nothing on quiet or dark material. Strength 0 is exact.
final class TapeSelfErasure {
    private static let sr = 44100.0
    private let lock = NSLock()
    private var target = 0.0, strength = 0.0
    private var lp = [0.0, 0.0], env = [0.0, 0.0]
    private let split = 1 - exp(-2 * Double.pi * 3500 / 44100)
    private let atk = 1 - exp(-1 / (0.001 * 44100)), rel = 1 - exp(-1 / (0.120 * 44100))

    func setStrength(_ s: Double) { lock.lock(); target = max(0, min(1, s)); lock.unlock() }

    func process(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        lock.lock(); let t = target; lock.unlock()
        if ch == 0 { strength += (t - strength) * (1 - exp(-Double(count) / (0.05 * Self.sr))) }
        var l = lp[ch], e = env[ch]
        if t == 0 && strength < 1e-5 {
            for i in 0..<count { l += split * (Double(buf[i]) - l) }   // keep the split warm
            lp[ch] = l; env[ch] = 0; return
        }
        let k = 30 * strength * strength + 6 * strength         // compression depth
        let drive = 1 + 3 * strength
        for i in 0..<count {
            let x = Double(buf[i])
            l += split * (x - l)
            let h = x - l
            let a = abs(h)
            e += (a > e ? atk : rel) * (a - e)
            let g = 1 / (1 + k * e)
            let hc = tanh(h * g * drive) / drive                    // soft ceiling on the treble
            buf[i] = Float(l + hc)
        }
        lp[ch] = l; env[ch] = e
    }
}
