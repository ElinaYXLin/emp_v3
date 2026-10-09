import Foundation

// MARK: - Tube Amp

// Loose, fuzzy tube-amp bass. Three controls:
//
// Fuzz — transformer saturation. A transformer core saturates on magnetic
//   flux, the running integral of the voltage, and flux builds up in
//   proportion to 1/frequency. So the signal is integrated (leaky, 12 Hz
//   corner), the flux is saturated (tanh), and the result is differentiated
//   back with the exact inverse of the integrator. Without saturation that
//   round trip is the identity; with it, 40 Hz fuzzes ~5× harder than 200 Hz
//   and 1 kHz stays nearly clean. The knob raises the core drive, so the fuzz
//   creeps up from the lowest notes and its low-vs-high gradient steepens.
//   Only the fuzz *products* (output − input) pass through a speaker/cabinet
//   low-pass (2-pole, 4.5 kHz → 3 kHz with the knob), so the fuzz is round
//   and woolly; the clean signal is untouched.
//
// Bloom — bass-driven supply sag. A bass-band envelope (< ~150 Hz) pulls the
//   gain down quickly on each hit; it then recovers over 100–300 ms (slower
//   as the knob rises). The bass band takes the full dip, the rest of the
//   spectrum about a third of it, so the whole amp breathes with the kick.
//
// Fur — bias shift. Loud bass charges a slow "bias" envelope; while it
//   discharges (the decay after a loud note) the fuzz core is pushed
//   off-centre (adding a little asymmetric grit when Fuzz is up) and rare,
//   soft crackles fire. Both the crackle rate and level rise with the knob.
//   Crackles go through the cabinet low-pass with the fuzz, so they stay soft.
//
// All three at 0 is exactly dry. Realtime-safe: no allocation in process().
final class TubeAmp {
    private static let sr = 44100.0
    private static let leak = exp(-2 * Double.pi * 12 / sr)        // flux integrator corner
    private static let k = 2 * Double.pi * 100 / sr                 // flux = 1 at 100 Hz, amplitude 1

    private let lock = NSLock()
    private var tFuzz = 0.0, tBloom = 0.0, tFur = 0.0
    private var fuzz = 0.0, bloom = 0.0, fur = 0.0

    private struct Chan { var flux = 0.0, fluxEnv = 0.0, cab1 = 0.0, cab2 = 0.0, lowA = 0.0, lowB = 0.0, crackle = 0.0 }
    private var c0 = Chan(), c1 = Chan()
    // Shared (stereo-linked)
    private var bassEnv = 0.0, biasEnv = 0.0, gain = 1.0
    private var rng: UInt64 = 0x2545F4914F6CDD1D
    private var active = false

    func setFuzz(_ v: Double)  { lock.lock(); tFuzz = max(0, min(1, v)); lock.unlock() }
    func setBloom(_ v: Double) { lock.lock(); tBloom = max(0, min(1, v)); lock.unlock() }
    func setFur(_ v: Double)   { lock.lock(); tFur = max(0, min(1, v)); lock.unlock() }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let tf = tFuzz, tb = tBloom, tu = tFur; lock.unlock()
        if tf == 0 && tb == 0 && tu == 0 && fuzz < 1e-5 && bloom < 1e-5 && fur < 1e-5 {
            if active { reset() }
            fuzz = 0; bloom = 0; fur = 0
            return
        }
        active = true
        let sr = Self.sr, leak = Self.leak, k = Self.k
        // Per-block glide toward the targets (~50 ms).
        let g = 1 - exp(-Double(count) / (0.05 * sr))
        fuzz += (tf - fuzz) * g; bloom += (tb - bloom) * g; fur += (tu - fur) * g

        let drive = 14.0 * pow(fuzz, 1.2)                          // core drive
        let cabHz = 4500 - 1500 * fuzz
        let cab = 1 - exp(-2 * Double.pi * cabHz / sr)
        let lowC = 1 - exp(-2 * Double.pi * 150 / sr)
        let envAtk = 1 - exp(-1 / (0.005 * sr)), envRel = 1 - exp(-1 / (0.060 * sr))
        let biasAtk = 1 - exp(-1 / (0.030 * sr)), biasRel = 1 - exp(-1 / (0.600 * sr))
        let dipAtk = 1 - exp(-1 / (0.008 * sr))
        let dipRel = 1 - exp(-1 / ((0.100 + 0.200 * bloom) * sr))
        let depth = 24 * bloom * (0.5 + 0.5 * bloom)
        let crackRate = (2 + 60 * fur * fur) / sr                // events/sample at full decay
        let crackLevel = 0.25 + 1.0 * fur
        let crackDecay = exp(-1 / (0.0012 * sr))
        let biasShift = 1.2 * fur
        let fluxAtk = 1 - exp(-1 / (0.002 * sr)), fluxRel = 1 - exp(-1 / (0.150 * sr))
        var a = c0, b = c1, rg = rng

        for i in 0..<count {
            // Stereo-linked bass detector.
            let xl = Double(left[i]), xr = right.map { Double($0[i]) } ?? xl
            a.lowA += lowC * (xl - a.lowA); a.lowB += lowC * (a.lowA - a.lowB)
            b.lowA += lowC * (xr - b.lowA); b.lowB += lowC * (b.lowA - b.lowB)
            let bassPeak = max(abs(a.lowB), abs(b.lowB))
            bassEnv += (bassPeak > bassEnv ? envAtk : envRel) * (bassPeak - bassEnv)
            biasEnv += (bassEnv > biasEnv ? biasAtk : biasRel) * (bassEnv - biasEnv)

            // Bloom: quick dip, slow recovery.
            let target = 1 / (1 + depth * bassEnv)
            gain += (target < gain ? dipAtk : dipRel) * (target - gain)
            let midGain = 1 - 0.35 * (1 - gain)

            // Fur: how far into a post-loud-bass decay we are.
            let decay = biasEnv > 1e-4 ? max(0, (biasEnv - bassEnv) / biasEnv) : 0
            let bias = biasShift * biasEnv * decay

            func run(_ c: inout Chan, _ x: Double) -> Double {
                // Transformer fuzz.
                let prev = c.flux
                c.flux = leak * c.flux + k * x
                var products = 0.0
                // Saturation depth cap: on very loud sub-bass the core would
                // saturate so deeply it only conducts in brief bursts near
                // the flux zero crossings, whose edges click. Cap drive×flux
                // at 2.5 and always keep a 20 % linear path, so the fuzz
                // stays thick and woolly instead of turning into a pulse train.
                let af = abs(c.flux)
                c.fluxEnv += (af > c.fluxEnv ? fluxAtk : fluxRel) * (af - c.fluxEnv)
                let dEff = min(drive, 2.5 / max(c.fluxEnv, 1e-6))
                if dEff > 1e-4 {
                    // Both samples go through the *same* curve (this sample's
                    // drive and bias). Reusing the previous sample's stored
                    // output instead turned every drive/bias change into a
                    // step, which the ÷k differentiator blew up into a pop.
                    let m = 0.2, off = tanh(dEff * bias)
                    let sat  = (1 - m) * (tanh(dEff * (c.flux + bias)) - off) / dEff + m * c.flux
                    let satP = (1 - m) * (tanh(dEff * (prev + bias)) - off) / dEff + m * prev
                    products = (sat - leak * satP) / k - x                // exact inverse of the integrator
                }
                // Bias-shift crackle.
                if fur > 1e-4 && decay > 0.05 {
                    rg ^= rg << 13; rg ^= rg >> 7; rg ^= rg << 17
                    let u = Double(rg >> 11) / Double(1 << 53)
                    if u < crackRate * decay {
                        let v = u / (crackRate * decay)                     // reuse as a fresh uniform
                        c.crackle += (v < 0.5 ? -1 : 1) * crackLevel * biasEnv * (0.4 + 1.2 * abs(v - 0.5))
                    }
                }
                products += c.crackle
                c.crackle *= crackDecay
                // Speaker/cabinet low-pass on the fuzz products only.
                c.cab1 += cab * (products - c.cab1)
                c.cab2 += cab * (c.cab1 - c.cab2)
                // Bloom: bass band takes the full dip, the rest about a third.
                let wet = x + c.cab2
                return c.lowB * gain + (wet - c.lowB) * midGain
            }
            left[i] = Float(run(&a, xl))
            if let r = right { r[i] = Float(run(&b, xr)) }
        }
        c0 = a; c1 = b; rng = rg
    }

    private func reset() {
        active = false
        c0 = Chan(); c1 = Chan()
        bassEnv = 0; biasEnv = 0; gain = 1
    }
}
