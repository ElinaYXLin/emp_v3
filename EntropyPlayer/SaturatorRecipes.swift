import Foundation

// Saturator Recipes: named characters for the Color stage. A recipe doesn't
// replace the Even/Odd saturator knobs — those still set the amount — it
// changes what surrounds and flavours them:
//
//   pre-emphasis (low + high shelf) → even sat → odd sat → harmonic recipe
//   → de-emphasis (exact inverse shelves) → post tone (tilt + low shelf)
//
// • Emphasis: boosting a band before the saturators and cutting it by the
//   same amount after makes that band distort more (or less) while the
//   overall tone stays put — how tape's pre-emphasis flavours its grit.
// • Drive multipliers and the even saturator's tube bias set the balance
//   of the two existing saturators.
// • Harmonic recipe: Chebyshev waveshaping. T_k(cos θ) = cos kθ, so each
//   polynomial adds exactly the k-th harmonic of a full-scale tone, with
//   naturally less of it on quieter material. Scaled by how hard the
//   saturator knobs are driven, so a recipe never adds color at zero drive.
// • Post tone: a final tilt/low shelf that isn't undone (darker, fuller…).
//
// "Classic" is fully neutral — exactly the plain Even/Odd saturators.

struct SaturatorRecipe {
    let name: String
    let blurb: String
    var evenMul = 1.0, oddMul = 1.0      // × knob drive
    var bias = 0.5                       // even saturator bias (× envelope)
    var preLowDb = 0.0                   // 250 Hz low shelf into the saturators (undone after)
    var preHighDb = 0.0                  // 3 kHz high shelf into the saturators (undone after)
    var h2 = 0.0, h3 = 0.0, h4 = 0.0, h5 = 0.0   // Chebyshev harmonic weights
    var harmonicMix = 0.0
    var postHighDb = 0.0                 // 5 kHz high shelf after (kept)
    var postLowDb = 0.0                  // 120 Hz low shelf after (kept)

    static let classic = SaturatorRecipe(name: "Classic", blurb: "the plain even/odd saturators")

    static let all: [SaturatorRecipe] = [
        classic,
        // ── Classic studio characters ──
        .init(name: "Sweeten", blurb: "silky even harmonics on the upper mids",
              evenMul: 1.2, oddMul: 0.3, bias: 0.6, preLowDb: -3, preHighDb: 3,
              h2: 0.5, h4: 0.15, harmonicMix: 0.35, postHighDb: -1),
        .init(name: "Thicken", blurb: "denser low-mids, 2nd + 3rd on the body",
              evenMul: 1.3, oddMul: 0.8, bias: 0.55, preLowDb: 1, preHighDb: -2,
              h2: 0.4, h3: 0.25, harmonicMix: 0.3, postHighDb: -1, postLowDb: 1.5),
        .init(name: "Vintagize", blurb: "worn gear: gritty mids, softened top",
              evenMul: 1.1, oddMul: 0.7, bias: 0.5, preLowDb: 1, preHighDb: 2,
              h2: 0.3, h3: 0.2, h5: 0.05, harmonicMix: 0.25, postHighDb: -4, postLowDb: 1),
        .init(name: "Glow", blurb: "tube bloom that opens up when pushed",
              evenMul: 1.5, oddMul: 0.2, bias: 0.75, preHighDb: 1,
              h2: 0.45, harmonicMix: 0.2, postHighDb: -1),
        .init(name: "Velvet", blurb: "the softest saturation, lows untouched",
              evenMul: 0.7, oddMul: 0, bias: 0.6, preLowDb: -4, preHighDb: -1,
              h2: 0.3, harmonicMix: 0.15, postHighDb: -2),
        .init(name: "Silk", blurb: "airy, smooth top-end sheen",
              evenMul: 1.0, oddMul: 0.2, bias: 0.5, preLowDb: -2, preHighDb: 4,
              h2: 0.35, h4: 0.2, harmonicMix: 0.25, postHighDb: -2),
        .init(name: "Warmth", blurb: "round, cozy low-mids, gently darker",
              evenMul: 1.3, oddMul: 0.4, bias: 0.6, preLowDb: 1, preHighDb: -1,
              h2: 0.5, harmonicMix: 0.3, postHighDb: -2, postLowDb: 1),
        .init(name: "Punch", blurb: "console-style bite on the low end",
              evenMul: 0.9, oddMul: 1.1, bias: 0.45, preLowDb: 1,
              h2: 0.2, h3: 0.3, harmonicMix: 0.2),
        .init(name: "Crunch", blurb: "edgy odd harmonics, lo-fi attitude",
              evenMul: 0.6, oddMul: 1.6, bias: 0.3, preLowDb: -3, preHighDb: 4,
              h3: 0.4, h5: 0.2, harmonicMix: 0.35),
        // ── Emotional / nostalgic characters ──
        .init(name: "First Kiss", blurb: "sweet, breathless, a little shy",
              evenMul: 1.2, oddMul: 0.2, bias: 0.65, preLowDb: -1, preHighDb: 2,
              h2: 0.4, h4: 0.2, harmonicMix: 0.25, postHighDb: -1.5, postLowDb: 0.5),
        .init(name: "Rainy Sunday", blurb: "muted and warm, like a window fogged over",
              evenMul: 1.1, oddMul: 0.3, bias: 0.6, preLowDb: 1, preHighDb: -3,
              h2: 0.35, harmonicMix: 0.2, postHighDb: -3, postLowDb: 1),
        .init(name: "Old Photograph", blurb: "grainy mids, faded highlights",
              evenMul: 1.2, oddMul: 0.6, bias: 0.5, preHighDb: 2,
              h2: 0.3, h3: 0.2, harmonicMix: 0.3, postHighDb: -5, postLowDb: -1),
        .init(name: "Grandma's Kitchen", blurb: "thick, warm, smells like something baking",
              evenMul: 1.4, oddMul: 0.3, bias: 0.7, preLowDb: 0, preHighDb: -2,
              h2: 0.5, h4: 0.1, harmonicMix: 0.3, postHighDb: -2.5, postLowDb: 1),
        .init(name: "Campfire Crackle", blurb: "a bit of sparkle and smoke",
              evenMul: 1.0, oddMul: 1.0, bias: 0.5, preLowDb: 1, preHighDb: 3,
              h2: 0.3, h3: 0.3, h5: 0.1, harmonicMix: 0.35, postHighDb: -2, postLowDb: 1),
        .init(name: "Late Night Diner", blurb: "jukebox grit through a tired speaker",
              evenMul: 1.1, oddMul: 0.8, bias: 0.45, preLowDb: -2, preHighDb: 1,
              h2: 0.25, h3: 0.25, harmonicMix: 0.3, postHighDb: -3, postLowDb: -1),
        .init(name: "Honey & Smoke", blurb: "rich, slow, golden",
              evenMul: 1.5, oddMul: 0.5, bias: 0.7, preLowDb: 0,
              h2: 0.55, h3: 0.1, harmonicMix: 0.35, postHighDb: -3, postLowDb: 1.5),
        .init(name: "Faded Polaroid", blurb: "washed-out highs, soft grain",
              evenMul: 1.0, oddMul: 0.5, bias: 0.55, preLowDb: -1, preHighDb: 3,
              h2: 0.3, h3: 0.15, harmonicMix: 0.25, postHighDb: -6, postLowDb: -2),
        .init(name: "Summer '99", blurb: "boombox bravado, bright and bouncy",
              evenMul: 0.9, oddMul: 1.0, bias: 0.4, preLowDb: 1, preHighDb: 3,
              h2: 0.2, h3: 0.3, harmonicMix: 0.3, postHighDb: -1, postLowDb: 1),
        .init(name: "Lullaby", blurb: "hushed, rounded, nothing sharp",
              evenMul: 0.8, oddMul: 0, bias: 0.6, preLowDb: -2, preHighDb: -3,
              h2: 0.3, harmonicMix: 0.15, postHighDb: -4, postLowDb: 1),
    ]

    static func named(_ name: String) -> SaturatorRecipe {
        all.first { $0.name == name } ?? classic
    }
}

// MARK: - Shelf biquad

/// RBJ cookbook low/high shelf (slope S = 1), stereo, parameters swappable
/// from any thread.
final class ShelfBiquad {
    enum Kind { case low, high }
    private let kind: Kind
    private let freq: Double
    private let lock = NSLock()
    private var c = (b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
    private var s = [[Double]](repeating: [0, 0, 0, 0], count: 2)   // x1 x2 y1 y2
    private(set) var isFlat = true

    init(_ kind: Kind, frequency: Double) {
        self.kind = kind
        self.freq = frequency
    }

    func setGain(db: Double, sampleRate sr: Double = 44100) {
        let A = pow(10, db / 40), w0 = 2 * Double.pi * freq / sr
        let cs = cos(w0), alpha = sin(w0) / 2 * 2.0.squareRoot(), sa = 2 * A.squareRoot() * alpha
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .low:
            b0 = A * ((A + 1) - (A - 1) * cs + sa); b1 = 2 * A * ((A - 1) - (A + 1) * cs)
            b2 = A * ((A + 1) - (A - 1) * cs - sa); a0 = (A + 1) + (A - 1) * cs + sa
            a1 = -2 * ((A - 1) + (A + 1) * cs);     a2 = (A + 1) + (A - 1) * cs - sa
        case .high:
            b0 = A * ((A + 1) + (A - 1) * cs + sa); b1 = -2 * A * ((A - 1) + (A + 1) * cs)
            b2 = A * ((A + 1) + (A - 1) * cs - sa); a0 = (A + 1) - (A - 1) * cs + sa
            a1 = 2 * ((A - 1) - (A + 1) * cs);      a2 = (A + 1) - (A - 1) * cs - sa
        }
        lock.lock()
        c = (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        isFlat = abs(db) < 1e-6
        lock.unlock()
    }

    func process(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        lock.lock(); let k = c; let flat = isFlat; lock.unlock()
        var st = s[ch]
        if flat {                        // keep state current so un-flattening is seamless
            for i in 0..<count { let x = Double(buf[i]); st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = x }
            s[ch] = st
            return
        }
        for i in 0..<count {
            let x = Double(buf[i])
            let y = k.b0 * x + k.b1 * st[0] + k.b2 * st[1] - k.a1 * st[2] - k.a2 * st[3]
            st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = y
            buf[i] = Float(y)
        }
        s[ch] = st
    }
}

// MARK: - Recipe stage DSP

/// The shaping around the saturators. Call `pre` before the even/odd
/// saturators and `post` after them.
final class RecipeStage {
    private let preLow  = ShelfBiquad(.low, frequency: 250)
    private let preHigh = ShelfBiquad(.high, frequency: 3000)
    private let deLow   = ShelfBiquad(.low, frequency: 250)
    private let deHigh  = ShelfBiquad(.high, frequency: 3000)
    private let toneHigh = ShelfBiquad(.high, frequency: 5000)
    private let toneLow  = ShelfBiquad(.low, frequency: 120)

    private let lock = NSLock()
    private var h = (h2: 0.0, h3: 0.0, h4: 0.0, h5: 0.0)
    private var mix = 0.0
    // 2nd-order 10 Hz high-pass on the harmonic path (even harmonics carry DC).
    private let hp: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) = {
        let w0 = 2 * Double.pi * 10 / 44100, alpha = sin(w0) / (2 * 0.7071), c = cos(w0), a0 = 1 + alpha
        return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
    }()
    private var hpS = [[Double]](repeating: [0, 0, 0, 0], count: 2)

    private var lowQuality = false
    func setLowQuality(_ on: Bool) { lock.lock(); lowQuality = on; lock.unlock() }

    /// amount 0…1: how hard the saturator knobs are driven (scales the harmonic recipe).
    func configure(_ r: SaturatorRecipe, amount: Double) {
        preLow.setGain(db: r.preLowDb);   deLow.setGain(db: -r.preLowDb)
        preHigh.setGain(db: r.preHighDb); deHigh.setGain(db: -r.preHighDb)
        toneHigh.setGain(db: r.postHighDb)
        toneLow.setGain(db: r.postLowDb)
        lock.lock()
        h = (r.h2, r.h3, r.h4, r.h5)
        mix = r.harmonicMix * max(0, min(1, amount))
        lock.unlock()
    }

    func pre(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        preLow.process(buf, count: count, channel: ch)
        preHigh.process(buf, count: count, channel: ch)
    }

    func post(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        lock.lock(); let w = h; let m = mix; let lq = lowQuality; lock.unlock()
        if m > 1e-6 {
            var st = hpS[ch]
            for i in 0..<count {
                let x = Double(buf[i])
                // Bounded for the polynomials (Padé approximation in low quality).
                let u: Double
                if lq { u = x > 3 ? 1 : (x < -3 ? -1 : x * (27 + x * x) / (27 + 9 * x * x)) } else { u = tanh(x) }
                let u2 = u * u
                let t2 = 2 * u2 - 1, t3 = (4 * u2 - 3) * u
                let t4 = 8 * u2 * u2 - 8 * u2 + 1, t5 = (16 * u2 * u2 - 20 * u2 + 5) * u
                // Remove the polynomials' static offsets (T2(0) = −1, T4(0) = 1).
                let harm = w.h2 * (t2 + 1) + w.h3 * t3 + w.h4 * (t4 - 1) + w.h5 * t5
                let y = hp.b0 * harm + hp.b1 * st[0] + hp.b2 * st[1] - hp.a1 * st[2] - hp.a2 * st[3]
                st[1] = st[0]; st[0] = harm; st[3] = st[2]; st[2] = y
                buf[i] = Float(x + m * y)
            }
            hpS[ch] = st
        }
        deLow.process(buf, count: count, channel: ch)
        deHigh.process(buf, count: count, channel: ch)
        toneHigh.process(buf, count: count, channel: ch)
        toneLow.process(buf, count: count, channel: ch)
    }
}

// MARK: - Post tube (compressor + saturator)

// The Tube knob after the 4-band EQ: like a vintage valve compressor.
//
//  1. Compressor (opto-style, stereo-linked): threshold 10 dB above the
//     music's own 3 s average (EMP often runs 20–30 dB under full scale here;
//     push into it with Pre-Amp), ratio 2 → 4:1 with the knob, 3 ms attack,
//     two-stage release (80 ms for short peaks, 1.5 s for sustained loudness),
//     half the average reduction made up. Evens out peaks so the tube is hit
//     consistently instead of transients breaking up first.
//  2. Level reference: the signal is brought to −18 dBFS for the tube and
//     restored after, so it acts the same at any listening level.
//  3. Recipe emphasis EQ (pre/post), as in the Color stage.
//  4. Drive 0 → 12 dB (× the recipe's even multiplier, clamped), applied
//     once (not squared), so most of the knob sits in the warm zone.
//  5. A soft, asymmetric tube curve: saturation fades in gradually (a
//     high-order soft knee rather than tanh's sudden bend), the negative half
//     compresses a little sooner than the positive (even harmonics), and the
//     recipe's bias shifts the operating point. Normalized to unity
//     small-signal gain and re-centred so silence stays silent.
//  6. 4× oversampling around the curve (windowed-sinc, 96 taps), so its
//     harmonics don't fold back as inharmonic fizz. Lo-Q skips it.
//  7. A low-pass after the tube that closes as the knob rises (18 kHz →
//     7 kHz), like valve gear rolling off its top.
// At "off" (0) the whole stage, low-pass included, is bypassed exactly; the
// first quarter of the knob fades the stage in from dry.
final class PostTubeSaturator {
    private static let os = 4, taps = 96
    private static let fir: [Float] = {
        // Low-pass prototype at the 4× rate: cutoff ~20 kHz, Blackman window.
        let n = PostTubeSaturator.taps, fc = 20000.0 / (44100.0 * Double(PostTubeSaturator.os))
        var h = [Float](repeating: 0, count: n); var sum = 0.0
        for i in 0..<n {
            let m = Double(i) - Double(n - 1) / 2
            let sinc = m == 0 ? 2 * fc : sin(2 * Double.pi * fc * m) / (Double.pi * m)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * w); sum += sinc * w
        }
        return h.map { $0 / Float(sum) }
    }()

    private let stage = RecipeStage()
    private let lock = NSLock()
    private var targetMix = 0.0, mix = 0.0, amount = 0.0
    private var driveLin = 1.0, bias = 0.3, norm = 1.0, off = 0.0
    private var lowQ = false

    // Compressor / level state
    private var compEnv = 0.0, fastRel = 1.0, slowRel = 1.0, avgGR = 1.0, longRMS = 0.01
    // Oversampling histories (per channel) and post low-pass
    // Circular histories (no allocation on the audio thread): the 24 most
    // recent input samples per channel for the polyphase interpolator, and
    // the 96 most recent 4× samples for the decimation filter.
    private let upBuf = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 32)
    private let dnBuf = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 128)
    private var upW = [0, 0], dnW = [0, 0]
    private var lpA = [0.0, 0.0], lpB = [0.0, 0.0]
    private let dryL = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let dryR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let refBuf = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    // The oversampling filters delay the wet path by ~24 samples; the dry
    // path (used while the knob fades the stage in) is delayed to match, so
    // the blend doesn't comb-filter.
    private static let osLatency = 24
    private let dryDelay = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 32)
    private var ddW = 0

    init() {
        upBuf.initialize(repeating: 0, count: 64); dnBuf.initialize(repeating: 0, count: 256)
        dryDelay.initialize(repeating: 0, count: 64)
    }
    deinit { dryL.deallocate(); dryR.deallocate(); refBuf.deallocate(); upBuf.deallocate(); dnBuf.deallocate(); dryDelay.deallocate() }

    /// The tube curve: soft high-order knee, slightly asymmetric.
    @inline(__always) private static func curve(_ z: Double) -> Double {
        let k = z >= 0 ? 1.0 : 0.85                       // negative half compresses a bit sooner
        let a = abs(z) / k
        return (z >= 0 ? 1 : -1) * k * a / pow(1 + pow(a, 2.5), 0.4)
    }

    /// amount 0…1, recipe as selected in the dropdown.
    func configure(amount a0: Double, recipe r: SaturatorRecipe) {
        let a = max(0, min(1, a0))
        let mul = max(0.7, min(1.4, r.evenMul))
        let d = pow(10, a * 12 * mul / 20)
        let b = 0.15 + 0.5 * r.bias * a                    // recipe bias, deeper with the knob
        let o = Self.curve(b)
        let slope = (Self.curve(b + 1e-4) - Self.curve(b - 1e-4)) / 2e-4
        stage.configure(r, amount: a * 0.75)
        lock.lock()
        targetMix = min(1, a * 4); amount = a; driveLin = d; bias = b; off = o; norm = 1 / max(slope * d, 1e-6)
        lock.unlock()
    }

    func setLowQuality(_ on: Bool) { lock.lock(); lowQ = on; lock.unlock(); stage.setLowQuality(on) }

    func process(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count n: Int) {
        lock.lock()
        let t = targetMix, amt = amount, d = driveLin, b = bias, o = off, nm = norm, lq = lowQ
        lock.unlock()
        if t == 0 && mix < 1e-4 { mix = 0; return }       // "off": exact bypass, low-pass included
        let sr = 44100.0
        let rmsC = 1 - exp(-1 / (3.0 * sr))
        let ratio = 2 + 2 * amt
        let atk = 1 - exp(-1 / (0.003 * sr))
        let fR = 1 - exp(-1 / (0.080 * sr)), sR = 1 - exp(-1 / (1.5 * sr)), sA = 1 - exp(-1 / (0.050 * sr))
        let avgC = 1 - exp(-1 / (3.0 * sr))
        let lpHz = 18000 * pow(7.0 / 18.0, amt)             // closes as the knob rises
        let lpC = 1 - exp(-2 * Double.pi * lpHz / sr)
        let h = Self.fir, OS = Self.os, T = Self.taps
        var done = 0
        while done < n {
            let c = min(4096, n - done), a = l + done, bb = r + done
            dryL.assign(from: a, count: c); dryR.assign(from: bb, count: c)
            let step = (t - mix) / Double(c)
            for i in 0..<c {
                // 1. Compressor + level tracking (stereo-linked).
                let x0 = Double(a[i]), x1 = Double(bb[i])
                longRMS += rmsC * ((x0 * x0 + x1 * x1) * 0.5 - longRMS)
                let thr = max(1e-5, longRMS.squareRoot() * 3.162 * 1.414)
                let lvl = max(abs(x0), abs(x1))
                compEnv += (lvl > compEnv ? atk : fR) * (lvl - compEnv)
                let want = compEnv > thr ? pow(compEnv / thr, 1 / ratio - 1) : 1
                fastRel = want < fastRel ? want : fastRel + fR * (want - fastRel)
                slowRel = slowRel + (want < slowRel ? sA : sR) * (want - slowRel)
                let gr = min(fastRel, slowRel)
                avgGR += avgC * (gr - avgGR)
                let comp = gr / max(avgGR.squareRoot(), 0.5)
                // 2. Level reference for the tube (kept per sample to undo it exactly).
                let ref = min(100, 0.126 / max(longRMS.squareRoot(), 1e-5))
                refBuf[i] = Float(ref)
                a[i] = Float(x0 * comp * ref); bb[i] = Float(x1 * comp * ref)
            }
            for ch in 0..<2 {
                let q = ch == 0 ? a : bb
                stage.pre(q, count: c, channel: ch)
                let ub = upBuf + ch * 32, db = dnBuf + ch * 128
                var uw = upW[ch], dw = dnW[ch]
                for i in 0..<c {
                    if lq {
                        q[i] = Float((Self.curve(Double(q[i]) * d + b) - o) * nm)
                        continue
                    }
                    // 6. 4× oversampled curve: polyphase interpolation → curve → FIR → decimate.
                    ub[uw & 31] = q[i]
                    var outSample: Float = 0
                    for ph in 0..<OS {
                        var v: Float = 0
                        var k = ph, j = 0
                        while k < T { v += h[k] * ub[(uw - j) & 31]; k += OS; j += 1 }
                        v *= Float(OS)
                        db[dw & 127] = Float((Self.curve(Double(v) * d + b) - o) * nm)
                        if ph == OS - 1 {
                            var acc: Float = 0
                            for m in 0..<T { acc += h[m] * db[(dw - m) & 127] }
                            outSample = acc
                        }
                        dw += 1
                    }
                    uw += 1
                    q[i] = outSample
                }
                upW[ch] = uw; dnW[ch] = dw
                stage.post(q, count: c, channel: ch)
                // 7. Valve roll-off, then undo the level reference.
                var la = lpA[ch], lb = lpB[ch]
                for i in 0..<c {
                    la += lpC * (Double(q[i]) - la); lb += lpC * (la - lb)
                    q[i] = Float(lb)
                }
                lpA[ch] = la; lpB[ch] = lb
            }
            let L = lq ? 0 : Self.osLatency
            for i in 0..<c {
                mix += step
                let w = Float(mix)
                // Dry delayed to line up with the oversampled wet path.
                var dl = dryL[i], dr = dryR[i]
                if L > 0 {
                    dryDelay[ddW & 31] = dl; dryDelay[32 + (ddW & 31)] = dr
                    dl = dryDelay[(ddW - L) & 31]; dr = dryDelay[32 + ((ddW - L) & 31)]
                    ddW += 1
                }
                let ref = refBuf[max(0, i - L)]
                a[i] = dl + (a[i] / ref - dl) * w
                bb[i] = dr + (bb[i] / ref - dr) * w
            }
            done += c
        }
    }
}
