import Foundation

// Downward Shimmer: the signal is pitched down an octave,
// diffused, darkened and fed back into itself, building a warm, deep glow
// under the music — the inverse of the classic bright "shimmer" reverb,
// which tends to sound piercing. Each trip round the loop drops another
// octave; a 60 Hz high-pass and 2.5 kHz low-pass inside the loop keep the
// cascade from turning into rumble or fizz.
//
// One strength control (0…1) scales both how loud the glow is (up to 0 dB
// re dry) and how long it sustains: the diffused glow recirculates at its
// own pitch (sustain 0.35 → 0.75 per ~95 ms trip, through a slowly
// wandering ±3 ms loop delay and a 3 kHz damping filter so the loop never
// rings like a fixed resonator) and a
// smaller share (up to 0.08) goes back through the shifter for the next
// octave down. Their sum stays below 1, so the loop is always stable.
//
// Octave-down shifter: a delay line read by two taps whose delays ramp at
// 0.5 samples/sample (→ half speed), half a cycle apart, crossfaded with
// sin² windows (four heads a quarter-window apart in high quality, which
// averages out the window-rate ripple two heads produced on sustained
// notes). Realtime-safe: fixed buffers only.
//
// Timing: the octave-down glow arrives ~12 ms after the note (23 ms
// shifter window plus a fixed delay); Depth's deeper undertones cascade in
// later, up to 50 ms for f/8 (see Depth.swift). A soft saturation in the
// loop roughens the glow a touch so it isn't glassy-clean. (The wandering
// "looseness" lag is still available via maxLagSec but is off.)
final class Shimmer {

    private static let sampleRate = 44100.0
    private static let maxMix = 1.0
    private static let shiftSize = 1 << 14             // room for the 200 ms looseness delay
    private static let apDelays: [[Int]] = [[556, 441, 341, 225], [579, 464, 356, 248]]
    private static let apGain: Float = 0.5
    private static let loopDelay = 2600              // ~59 ms before feeding back (centre)
    private static let dampCoef = Float(1 - exp(-2 * Double.pi * 3000 / 44100))
    private static let loopSize = 4096
    private static let envAtk = Float(1 - exp(-1 / (0.030 * 44100)))
    private static let envRel = Float(1 - exp(-1 / (0.300 * 44100)))               // room for the modulated read
    private static let loopMod = 130.0               // ±3 ms slow wander of the loop delay

    private let lock = NSLock()
    private var targetStrength: Double = 0
    private var strength: Double = 0
    private var lowQuality = false
    private var lowQualityTarget = false

    func setLowQuality(_ on: Bool) { lock.lock(); lowQualityTarget = on; lock.unlock() }

    private let shiftBuf = UnsafeMutablePointer<Float>.allocate(capacity: Shimmer.shiftSize)
    private var shiftWrite = 0
    // Pitch ratios read from the shared delay line (Shimmer: ½; Depth: ⅓…⅛).
    private let ratios: UnsafeMutablePointer<Double>
    private let phases: UnsafeMutablePointer<Double>
    private let ratioCount: Int
    // High-quality grain heads: 4 per ratio, each with its own phase and window.
    private let headPh: UnsafeMutablePointer<Double>
    private let headW: UnsafeMutablePointer<Double>
    private var rng: UInt64 = 0x5EED_0F_5717_33AA
    private let cascade: Bool            // feed the glow back through the shifter (next octave down)
    private let progressive: Bool        // knob fades ratios in one at a time
    private let window: Double           // shifter window (samples); average added delay ≈ half of it
    private let maxLagSec: Double        // the wandering "looseness" lag at full strength
    private let extraDelay: UnsafeMutablePointer<Double>   // per ratio, samples (the undertone cascade)
    private let ratioLPCoef: UnsafeMutablePointer<Float>    // per ratio 2-pole low-pass (1 = off)
    private let ratioLP: UnsafeMutablePointer<Float>        // per ratio filter state, 2 each
    private var lagFrom = 0.8, lagTo = 0.8, lagPos = 0.0, lagLen = 88200.0, lagRng: UInt64 = 0x51A3_70E1_D00D_F00D

    // Per channel: 4 allpasses + a loop delay.
    private let apBufs: [[UnsafeMutablePointer<Float>]]
    private var apIdx = [[Int]](repeating: [0, 0, 0, 0], count: 2)
    private let loopBuf: [UnsafeMutablePointer<Float>]
    private var loopIdx = 0
    private var modPh = (0.0, 0.37)                    // loop-delay LFO phases (L, R)
    private var damp: (Float, Float) = (0, 0)          // treble damping inside the loop

    // Cohesion with the music:
    //  • the glow follows the dry signal's level (30 ms attack / 300 ms
    //    release): it can never sustain on its own once the music moves on,
    //    so it reads as the note's resonance rather than a separate drone;
    //  • a short "room" (two longer allpasses per side, ~25–32 ms) places the
    //    glow slightly behind the music in the same space.
    private var dryEnv: Float = 0, glowEnv: Float = 0, followGain: Float = 1
    private static let roomLen = [[1031, 1327], [1103, 1409]]
    private let roomBufs: [[UnsafeMutablePointer<Float>]]
    private var roomIdx = [[0, 0], [0, 0]]

    private var lpState: Float = 0, hpState: Float = 0, hpPrev: Float = 0
    private let lpCoef = Float(1 - exp(-2 * Double.pi * 2500 / 44100))
    private let hpCoef: Float

    /// ratios: pitch ratios to generate (default one octave down). hpHz: the
    /// glow's high-pass. cascade: feed the glow back through the shifter for
    /// further octaves. progressive: the knob fades the ratios in one by one.
    init(ratios rs: [Double] = [0.5], hpHz: Double = 60, cascade: Bool = true, progressive: Bool = false,
         window: Double = 1024, maxLagSec: Double = 0, delaysMs: [Double]? = [12], lowPassHz: [Double]? = nil) {
        self.window = window
        self.maxLagSec = maxLagSec
        // Each ratio's average delay behind the note: the shifter itself adds
        // ~4 + W/2 samples, the rest is a fixed extra delay.
        extraDelay = UnsafeMutablePointer<Double>.allocate(capacity: rs.count)
        ratioLPCoef = UnsafeMutablePointer<Float>.allocate(capacity: rs.count)
        ratioLP = UnsafeMutablePointer<Float>.allocate(capacity: rs.count * 2)
        ratioLP.initialize(repeating: 0, count: rs.count * 2)
        for k in 0..<rs.count {
            if let hz = lowPassHz?[k] { ratioLPCoef[k] = Float(1 - exp(-2 * Double.pi * hz / 44100)) } else { ratioLPCoef[k] = 1 }
        }
        let built = 4 + window / 2
        for k in 0..<rs.count {
            let target = (delaysMs?[k] ?? 0) / 1000 * 44100
            extraDelay[k] = max(0, target - built)
        }
        ratioCount = rs.count
        headPh = UnsafeMutablePointer<Double>.allocate(capacity: rs.count * 4)
        headW = UnsafeMutablePointer<Double>.allocate(capacity: rs.count * 4)
        for h in 0..<(rs.count * 4) {
            headPh[h] = Double(h % 4) * 0.25 + 0.03 * Double(h / 4)
            headW[h] = window * (0.85 + 0.3 * Double((h * 37) % 11) / 10)
        }
        ratios = UnsafeMutablePointer<Double>.allocate(capacity: rs.count)
        phases = UnsafeMutablePointer<Double>.allocate(capacity: rs.count)
        for (k, v) in rs.enumerated() { ratios[k] = v; phases[k] = Double(k) / Double(rs.count) }
        hpCoef = Float(exp(-2 * Double.pi * hpHz / 44100))
        self.cascade = cascade
        self.progressive = progressive
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        shiftBuf.initialize(repeating: 0, count: Self.shiftSize)
        apBufs = Self.apDelays.map { $0.map { buf($0) } }
        loopBuf = [buf(Self.loopSize), buf(Self.loopSize)]
        roomBufs = Self.roomLen.map { $0.map { buf($0) } }
    }

    deinit {
        shiftBuf.deallocate(); ratios.deallocate(); phases.deallocate(); headPh.deallocate(); headW.deallocate(); extraDelay.deallocate(); ratioLPCoef.deallocate(); ratioLP.deallocate()
        apBufs.flatMap { $0 }.forEach { $0.deallocate() }
        loopBuf.forEach { $0.deallocate() }
        roomBufs.flatMap { $0 }.forEach { $0.deallocate() }
    }

    /// strength: 0 (off) … 1 (loud, long-sustaining glow).
    func setStrength(_ s: Double) {
        lock.lock()
        targetStrength = max(0, min(1, s))
        lock.unlock()
    }

    private func clear() {
        shiftBuf.assign(repeating: 0, count: Self.shiftSize)
        for (ch, bufs) in apBufs.enumerated() {
            for (a, b) in bufs.enumerated() { b.assign(repeating: 0, count: Self.apDelays[ch][a]) }
        }
        loopBuf.forEach { $0.assign(repeating: 0, count: Self.loopSize) }; damp = (0, 0)
        lpState = 0; hpState = 0; hpPrev = 0
        roomBufs.enumerated().forEach { ch, bs in bs.enumerated().forEach { a, b in b.assign(repeating: 0, count: Self.roomLen[ch][a]) } }
        dryEnv = 0; glowEnv = 0; followGain = 1
        ratioLP.assign(repeating: 0, count: ratioCount * 2)
    }

    @inline(__always) private func readShift(_ delay: Double) -> Float {
        let pos = Double(shiftWrite) - delay
        let i = Int(floor(pos)), t = Float(pos - Double(i))
        let mask = Self.shiftSize - 1
        let a = shiftBuf[i & mask], b = shiftBuf[(i &+ 1) & mask]
        return a + (b - a) * t
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock()
        let target = targetStrength
        lowQuality = lowQualityTarget
        lock.unlock()
        if target == 0 && strength < 1e-5 {                          // fully off: bypass
            if strength != 0 { clear() }                             // don't resurrect an old tail later
            strength = 0
            return
        }

        let glide = 1 - exp(-1 / (0.05 * Self.sampleRate))
        let mask = Self.shiftSize - 1
        let W = window
        func lagRand() -> Double {
            lagRng ^= lagRng << 13; lagRng ^= lagRng >> 7; lagRng ^= lagRng << 17
            return Double(lagRng >> 11) / Double(1 << 53)
        }

        for i in 0..<count {
            strength += (target - strength) * glide
            let sustain = Float(0.35 + 0.40 * strength)
            let octaveFb = cascade ? Float(0.08 * strength) : 0
            let mix = Float(strength * Self.maxMix)

            let l = left[i], r = right?[i] ?? l
            // Loop input: dry mono + fed-back glow.
            // Loop read with a slowly wandering delay (different rate per side)
            // so the loop's resonances never settle into a metallic ring, and
            // damp the treble on every trip.
            modPh.0 += 0.31 / Self.sampleRate; if modPh.0 >= 1 { modPh.0 -= 1 }
            modPh.1 += 0.43 / Self.sampleRate; if modPh.1 >= 1 { modPh.1 -= 1 }
            func loopRead(_ b: UnsafeMutablePointer<Float>, _ ph: Double) -> Float {
                let d = Double(Self.loopDelay) + Self.loopMod * sin(2 * Double.pi * ph)
                let pos = Double(loopIdx) - d, fl = pos.rounded(.down), fr = Float(pos - fl)
                let i0 = Int(fl) & (Self.loopSize - 1), i1 = (i0 + 1) & (Self.loopSize - 1)
                return b[i0] + (b[i1] - b[i0]) * fr
            }
            damp.0 += Self.dampCoef * (loopRead(loopBuf[0], modPh.0) - damp.0)
            damp.1 += Self.dampCoef * (loopRead(loopBuf[1], modPh.1) - damp.1)
            let fbL = damp.0, fbR = damp.1
            shiftBuf[shiftWrite & mask] = (l + r) * 0.5 + octaveFb * (fbL + fbR) * 0.5
            shiftWrite &+= 1

            // Wandering lag: 0.6–1.0 × (200 ms × strength), cosine glides.
            lagPos += 1
            if lagPos >= lagLen {
                lagPos = 0; lagFrom = lagTo
                lagTo = 0.6 + 0.4 * lagRand()
                lagLen = (1.5 + 2.5 * lagRand()) * Self.sampleRate
            }
            let e = 0.5 - 0.5 * cos(Double.pi * lagPos / lagLen)
            let lag = (lagFrom + (lagTo - lagFrom) * e) * maxLagSec * Self.sampleRate * strength

            // Pitch shifters (one per ratio), sharing the delay line. High
            // quality: exact sin² crossfade. Low: parabola 4p(1−p) ≈ sin(πp).
            var y: Float = 0, gSum: Float = 0
            for k in 0..<ratioCount {
                var gk: Float = 1
                if progressive {
                    gk = Float(min(1, max(0, strength * Double(ratioCount) - Double(k))))
                    if gk == 0 { phases[k] += (1 - ratios[k]) / W; if phases[k] >= 1 { phases[k] -= 1 }; continue }
                }
                let p1 = phases[k]
                let d0 = 4 + lag + extraDelay[k]
                var v: Float = 0
                if lowQuality {
                    // Low quality: two heads, parabolic windows.
                    let p2 = p1 + 0.5 - (p1 >= 0.5 ? 1 : 0)
                    let g1 = Float(4 * p1 * (1 - p1)), g2 = Float(4 * p2 * (1 - p2))
                    v = readShift(d0 + p1 * W) * g1 * g1 + readShift(d0 + p2 * W) * g2 * g2
                } else {
                    // Four independent grain heads, each restarting with a
                    // randomized window length (±30 %), normalized by their
                    // summed window weight. Lockstep heads interfered with
                    // themselves periodically at the window rate (~21 Hz for an
                    // octave down) — an audible stutter on sustained notes;
                    // decorrelated heads leave only a soft, irregular texture.
                    var wsum: Float = 0
                    let r = ratios[k]
                    for j in 0..<4 {
                        let h = k * 4 + j
                        let pj = headPh[h]
                        let gj = Float(sin(Double.pi * pj)); let w2 = gj * gj
                        v += readShift(d0 + pj * headW[h]) * w2
                        wsum += w2
                        var np = pj + (1 - r) / headW[h]
                        if np >= 1 {
                            np -= 1
                            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                            headW[h] = W * (0.7 + 0.6 * Double(rng >> 11) / Double(1 << 53))
                        }
                        headPh[h] = np
                    }
                    v /= max(wsum, 0.25)
                }
                let c = ratioLPCoef[k]
                if c < 1 {                                       // this undertone's own low-pass
                    ratioLP[2 * k] += c * (v - ratioLP[2 * k])
                    ratioLP[2 * k + 1] += c * (ratioLP[2 * k] - ratioLP[2 * k + 1])
                    v = ratioLP[2 * k + 1]
                }
                y += v * gk
                gSum += gk * gk
                phases[k] += (1 - ratios[k]) / W
                if phases[k] >= 1 { phases[k] -= 1 }
            }
            if gSum > 1 { y /= gSum.squareRoot() }               // several undertones: keep the glow's level
            // A touch of soft saturation so the glow isn't glassy-clean.
            let drive = Float(1 + 1.5 * strength)
            y = Float(tanh(Double(y * drive))) / drive

            // Darken + keep out of the sub-bass.
            lpState += lpCoef * (y - lpState)
            y = lpState
            let hp = hpCoef * (hpState + y - hpPrev)
            hpPrev = y; hpState = hp
            y = hp

            // Stereo diffusion (different allpass lengths per side).
            var outs: (Float, Float) = (y, y)
            for ch in 0..<2 {
                var v = (ch == 0 ? outs.0 : outs.1) + sustain * (ch == 0 ? fbL : fbR)
                for a in 0..<(lowQuality ? 2 : 4) {        // low quality: half the diffusion
                    let b = apBufs[ch][a], len = Self.apDelays[ch][a]
                    let idx = apIdx[ch][a]
                    let delayed = b[idx]
                    let w = v + Self.apGain * delayed
                    b[idx] = w
                    v = delayed - Self.apGain * w
                    apIdx[ch][a] = idx + 1 == len ? 0 : idx + 1
                }
                if ch == 0 { outs.0 = v } else { outs.1 = v }
            }

            loopBuf[0][loopIdx] = outs.0
            loopBuf[1][loopIdx] = outs.1
            loopIdx = (loopIdx + 1) & (Self.loopSize - 1)

            // Level compensation (measured on pink noise): the sustained glow
            // otherwise adds up to ~4.3 dB at full strength.
            let comp = Float(1 / (1 + 1.69 * pow(strength, 3.5)).squareRoot())

            // Same space, slightly behind: short room on the glow only.
            var gl = outs.0, gr = outs.1
            for ch in 0..<2 {
                var v = ch == 0 ? gl : gr
                for a in 0..<2 {
                    let b = roomBufs[ch][a], len = Self.roomLen[ch][a], idx = roomIdx[ch][a]
                    let d = b[idx], w = v + 0.5 * d
                    b[idx] = w; v = d - 0.5 * w
                    roomIdx[ch][a] = idx + 1 == len ? 0 : idx + 1
                }
                if ch == 0 { gl = v } else { gr = v }
            }
            // Follow the music: limit the glow to the dry signal's envelope.
            let dl = max(abs(l), abs(r)), gLevel = max(abs(gl), abs(gr)) * mix
            dryEnv += (dl > dryEnv ? Self.envAtk : Self.envRel) * (dl - dryEnv)
            glowEnv += (gLevel > glowEnv ? Self.envAtk : Self.envRel) * (gLevel - glowEnv)
            let want = min(1, 1.2 * dryEnv / max(glowEnv, 1e-6))
            followGain += (want < followGain ? 0.004 : 0.0008) * (want - followGain)
            let wet = mix * followGain
            left[i] = (l + gl * wet) * comp
            right?[i] = (r + gr * wet) * comp
        }
    }
}
