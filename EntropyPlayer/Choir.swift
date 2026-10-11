import Foundation

// MARK: - Choir

// A crowd of virtual singers, each replaying the music with its own small
// delay, pitch offset and vibrato, from its own place in the room.
//
// Each voice is a two-head pitch shifter reading a shared mono delay line:
// the heads sweep a 40 ms window at a rate set by the voice's pitch ratio
// and crossfade triangularly, so the voice holds a steady detune instead of
// the back-and-forth wobble of a plain chorus.
//
// Per voice, fixed for the life of the player:
//   • stereo position (−1…1) and distance (0…1). Distance lowers the level,
//     darkens the tone and adds up to 15 ms of extra delay.
//   • a "tendency" t in [−½, ½] for detune and another for delay: the
//     systematic centre that voice's wander drifts around.
//   • a vibrato rate, re-drawn in 3–20 Hz every segment (gliding).
// Every 10 s (staggered per voice) each voice draws a new target u in [−1, 1]
// and glides to it over the next 10 s. Its detune is then (t + u)·d cents and
// its delay (½ + (t + u)/2)·D ms (clamped ≥ 0), so the knobs scale the
// wander live.
//
// Each voice also has its own saturator — a curve from a bank of eight, its
// own bias (even/odd balance) and drive, fixed for the life of the player —
// and the saturated voices are summed and pulled together by a gentle glue
// compressor (2:1 above −20 dBFS, ≤ 6 dB) before joining the dry signal.
//
// Knobs (0…1): Voices (0–16 singers, the newest fading in continuously),
// Detune (d up to ±35 cents), Delay (D up to 60 ms), Vibrato (up to ±40 cents).
// Voices 0 is exactly dry. Dry + choir are power-matched so adding singers
// thickens without getting louder. Realtime-safe: all buffers preallocated.
final class Choir {
    private static let sr = 44100.0
    static let maxVoices = 16
    private static let lineSize = 16384                          // > 60 + 15 + 40 ms + slack
    private static let window = 0.040 * sr                        // shifter window, samples
    private static let segment = 10.0 * sr                        // new target every 10 s

    private struct Voice {
        var pan = 0.0, dist = 0.0
        var tendDet = 0.0, tendDel = 0.0
        var detFrom = 0.0, detTo = 0.0, delFrom = 0.0, delTo = 0.0
        var rateFrom = 0.0, rateTo = 0.0
        var segPos = 0.0                                          // samples into the segment
        var phase = 0.0                                           // shifter phase 0…1
        var vibPhase = 0.0                                        // 0…1
        var lp = 0.0, delay = 0.0                                 // distance tone, current base delay (samples)
        var gl = 0.0, gr = 0.0
        // Each voice's own saturator (fixed for the life of the player):
        // a curve from the bank, a bias (sets its even/odd balance) and a
        // drive, normalized to unity small-signal gain; plus a DC blocker.
        var shape = 0, bias = 0.0, drive = 1.0, norm = 1.0, off = 0.0
        var hpX = 0.0, hpY = 0.0
    }

    /// Bank of saturation curves (all odd-symmetric, |f| ≤ ~1); the bias
    /// shifts each voice's operating point to make them asymmetric.
    @inline(__always) static func curve(_ i: Int, _ u: Double) -> Double {
        switch i {
        case 0: return tanh(u)                                          // classic tube-ish
        case 1: return u / (1 + u * u).squareRoot()                     // algebraic, softer knee
        case 2: return 2 / Double.pi * atan(Double.pi / 2 * u)          // arctangent, long tail
        case 3: let c = max(-1, min(1, u)); return 1.5 * (c - c * c * c / 3)   // cubic, hard-ish
        case 4: return u >= 0 ? 1 - exp(-u) : -(1 - exp(u))             // exponential
        case 5: return sin(max(-Double.pi / 2, min(Double.pi / 2, u)))  // sine fold, rounded
        case 6: return u / (1 + abs(u))                                 // rational, very soft
        default: return tanh(u + 0.15 * u * u * u)                      // steeper tanh, gritty
        }
    }

    private let lock = NSLock()
    private var tVoices = 0.0, tDetune = 0.0, tDelay = 0.0, tVib = 0.0
    private var voicesK = 0.0, detuneK = 0.0, delayK = 0.0, vibK = 0.0
    private var maxActive = Choir.maxVoices
    private var tLowQ = false

    private let line = UnsafeMutablePointer<Float>.allocate(capacity: Choir.lineSize)
    private var w = 0
    private let v = UnsafeMutablePointer<Voice>.allocate(capacity: Choir.maxVoices)
    private var rng: UInt64 = 0xC401C401_5EED1234
    // Wet bus for the saturated voices, then a gentle glue compressor.
    private static let maxBlock = 16384
    private let wetL = UnsafeMutablePointer<Double>.allocate(capacity: Choir.maxBlock)
    private let wetR = UnsafeMutablePointer<Double>.allocate(capacity: Choir.maxBlock)
    private var glueEnv = 0.0, glueGain = 1.0

    init() {
        line.initialize(repeating: 0, count: Self.lineSize)
        v.initialize(repeating: Voice(), count: Self.maxVoices)
        for i in 0..<Self.maxVoices {
            var x = Voice()
            x.pan = rand() * 2 - 1
            x.dist = rand()
            x.gl = cos((x.pan + 1) * .pi / 4); x.gr = sin((x.pan + 1) * .pi / 4)
            x.tendDet = rand() - 0.5; x.tendDel = rand() - 0.5
            x.detFrom = rand() * 2 - 1; x.detTo = rand() * 2 - 1
            x.delFrom = rand() * 2 - 1; x.delTo = rand() * 2 - 1
            x.rateFrom = 3 + 17 * rand(); x.rateTo = 3 + 17 * rand()
            x.segPos = rand() * Self.segment                      // stagger the switches
            x.phase = rand(); x.vibPhase = rand()
            x.delay = -1
            // Saturator identity: shapes spread across voices, bias ±0.45,
            // drive 1.5–5× (the choir runs at ~-12 dBFS, so this is gentle).
            x.shape = (i * 5 + 3) % 8
            x.bias = (rand() * 2 - 1) * 0.45
            x.drive = 1.5 + 3.5 * rand()
            x.off = Self.curve(x.shape, x.bias)
            let slope = (Self.curve(x.shape, x.bias + 1e-4) - Self.curve(x.shape, x.bias - 1e-4)) / 2e-4
            x.norm = 1 / max(slope * x.drive, 1e-6)
            v[i] = x
        }
    }

    deinit { line.deallocate(); v.deallocate(); wetL.deallocate(); wetR.deallocate() }

    private func rand() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    func setVoices(_ x: Double)  { lock.lock(); tVoices = max(0, min(1, x)); lock.unlock() }
    func setDetune(_ x: Double)  { lock.lock(); tDetune = max(0, min(1, x)); lock.unlock() }
    func setDelay(_ x: Double)   { lock.lock(); tDelay  = max(0, min(1, x)); lock.unlock() }
    func setVibrato(_ x: Double) { lock.lock(); tVib    = max(0, min(1, x)); lock.unlock() }
    /// Lo-Q: at most 6 singers.
    func setLowQuality(_ on: Bool) { lock.lock(); tLowQ = on; lock.unlock() }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count total: Int) {
        var done = 0
        while done < total {
            let c = min(Self.maxBlock, total - done)
            processBlock(left: left + done, right: right.map { $0 + done }, count: c)
            done += c
        }
    }

    private func processBlock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock()
        let tv = tVoices, td = tDetune, tl = tDelay, tb = tVib
        maxActive = tLowQ ? 6 : Self.maxVoices
        lock.unlock()
        let N = Self.lineSize, mask = N - 1

        // Always write the line so turning Voices up starts from real audio.
        if tv == 0 && voicesK < 1e-4 {
            voicesK = 0
            for i in 0..<count {
                line[w] = right.map { (left[i] + $0[i]) * 0.5 } ?? left[i]
                w = (w + 1) & mask
            }
            return
        }

        let sr = Self.sr, W = Self.window, seg = Self.segment
        let g = 1 - exp(-Double(count) / (0.05 * sr))
        voicesK += (tv - voicesK) * g; detuneK += (td - detuneK) * g
        delayK += (tl - delayK) * g; vibK += (tb - vibK) * g

        let count16 = voicesK * Double(maxActive)                 // fractional singer count
        let active = min(maxActive, Int(count16.rounded(.up)))
        let dCents = 35 * detuneK, dMs = 60 * delayK, vibCents = 40 * vibK
        let cpr = log(2.0) / 1200                                 // cents → ratio − 1 (small-angle)
        // Power-match dry vs. choir.
        let wet = min(1, count16) * 0.95
        let dryG = 1 / (1 + wet * wet).squareRoot(), wetG = wet * dryG / max(1, count16).squareRoot()
            / (0.4 * 0.5 * 2 / 3).squareRoot()   // distance loss E[(1+1.5d)^-2] = 0.4, equal-power pan ½, triangular head crossfade ⅔
        let distLP = { (d: Double) in 1 - exp(-2 * Double.pi * (12000 - 9000 * d) / sr) }

        // Precompute per-voice block values.
        for k in 0..<active {
            var x = v[k]
            x.segPos += Double(count)
            if x.segPos >= seg {
                x.segPos -= seg
                x.detFrom = x.detTo; x.detTo = rand() * 2 - 1
                x.delFrom = x.delTo; x.delTo = rand() * 2 - 1
                x.rateFrom = x.rateTo; x.rateTo = 3 + 17 * rand()
            }
            v[k] = x
        }

        for i in 0..<count { wetL[i] = 0; wetR[i] = 0 }
        let hpC = exp(-2 * Double.pi * 15 / sr)
        for k in 0..<active {
            var x = v[k]
            let shp = x.shape, bias = x.bias, drv = x.drive, nrm = x.norm, off = x.off
            var hx = x.hpX, hy = x.hpY
            let s = x.segPos / seg, e = 0.5 - 0.5 * cos(.pi * s)   // cosine glide over the segment
            let det = (x.tendDet + x.detFrom + (x.detTo - x.detFrom) * e) * dCents
            let delMs = max(0, (0.5 + 0.5 * (x.tendDel + x.delFrom + (x.delTo - x.delFrom) * e))) * dMs
                + 15 * x.dist + 1
            let target = delMs * 0.001 * sr
            if x.delay < 0 { x.delay = target }
            let dStep = (target - x.delay) / Double(count)
            let rate = x.rateFrom + (x.rateTo - x.rateFrom) * e
            let vInc = rate / sr
            let lpc = distLP(x.dist)
            let level = min(1, max(0, count16 - Double(k))) / (1 + 1.5 * x.dist) * wetG
            let gl = x.gl * level, gr = x.gr * level
            var phase = x.phase, vph = x.vibPhase, lp = x.lp, base = x.delay
            var wp = w
            for i in 0..<count {
                // Mono input into the line (once, on the first voice).
                if k == 0 {
                    line[wp] = right.map { (left[i] + $0[i]) * 0.5 } ?? left[i]
                }
                // Pitch: steady detune + vibrato (parabolic sine, cheap).
                let t = vph * 2 - 1                                // −1…1
                let sine = 4 * t * (1 - abs(t))                    // ≈ sin(π·t) shape
                let cents = det + vibCents * sine
                phase += -(cents * cpr) / W                        // ratio > 1 → read head catches up
                phase -= phase.rounded(.down)
                vph += vInc; if vph >= 1 { vph -= 1 }
                base += dStep
                let p2 = phase + 0.5 - (phase + 0.5 >= 1 ? 1 : 0)
                let g1 = 1 - abs(2 * phase - 1)
                func tap(_ d: Double) -> Double {
                    let pos = Double(wp) - d
                    let fl = pos.rounded(.down), fr = pos - fl
                    let i0 = Int(fl) & mask, i1 = (i0 + 1) & mask
                    return Double(line[i0]) + Double(line[i1] - line[i0]) * fr
                }
                let y = tap(base + phase * W) * g1 + tap(base + p2 * W) * (1 - g1)
                lp += lpc * (y - lp)
                // This voice's own saturator (unity small-signal gain), DC-blocked.
                let sat = (Self.curve(shp, lp * drv + bias) - off) * nrm
                hy = hpC * (hy + sat - hx); hx = sat
                wetL[i] += hy * gl
                wetR[i] += hy * gr
                wp = (wp + 1) & mask
            }
            x.phase = phase; x.vibPhase = vph; x.lp = lp; x.delay = base
            x.hpX = hx; x.hpY = hy
            v[k] = x
        }
        if active > 0 {
            // Gentle glue on the voice bus: stereo-linked, 2:1 above −20 dBFS,
            // 20 ms attack / 250 ms release, at most 6 dB of reduction — it
            // pulls the voices together without flattening the dynamics.
            let gA = 1 - exp(-1 / (0.020 * sr)), gR = 1 - exp(-1 / (0.250 * sr))
            let thr = 0.1
            for i in 0..<count {
                let a = max(abs(wetL[i]), abs(wetR[i]))
                glueEnv += (a > glueEnv ? gA : gR) * (a - glueEnv)
                let want = glueEnv > thr ? max(0.5, (thr * (glueEnv / thr).squareRoot()) / glueEnv) : 1
                glueGain += (want < glueGain ? gA : gR) * (want - glueGain)
                left[i] = Float(Double(left[i]) * dryG + wetL[i] * glueGain)
                if let r = right { r[i] = Float(Double(r[i]) * dryG + wetR[i] * glueGain) }
            }
        }
        if active == 0 {
            for i in 0..<count { line[(w + i) & mask] = right.map { (left[i] + $0[i]) * 0.5 } ?? left[i] }
        }
        w = (w + count) & mask
        // Voices that faded out keep their wander clock running.
        for k in active..<Self.maxVoices { v[k].segPos = (v[k].segPos + Double(count)).truncatingRemainder(dividingBy: seg) }
    }
}
