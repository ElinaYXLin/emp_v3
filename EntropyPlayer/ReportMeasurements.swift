import Foundation
import Accelerate

// Offline measurements for the Listener Report. Fresh DSP instances,
// configured like the live chain, so measuring never disturbs playback.
//
// Why more than THD: a single sine's THD saturates as clipping gets harder —
// the waveform tends toward a square wave, whose THD is only ~48% (harmonics
// fall as 1/n) — so "maxed out and unlistenable" still reads ~50–60%. What
// actually wrecks music is (1) intermodulation: many notes clipping together
// make new, non-harmonic tones, (2) aliasing: harmonics above Nyquist fold
// back out of tune, and (3) time smear from the haze effects. Hence:
//
//   • THD            harmonics 2–10 of one tone ÷ fundamental (the classic spec)
//   • THD+N          everything that isn't the fundamental (catches aliasing)
//   • Multitone IMD  five non-harmonic tones at once; share of output power
//                    that is new frequencies — closest to "how mushy music gets"
//   • Smear          a click through the haze chain → C50 clarity (energy in
//                    the first 50 ms vs after, room-acoustics standard) and
//                    centre time (energy's centre of gravity after arrival)

struct ChainSettings {
    var fileTrimDb = 0.0        // fixed local-file trim (export only)
    var preampDb = 0.0
    var postGainDb = 0.0        // export only
    var murk = 0.0
    var lowQuality = false      // offline chain (benchmarks); export uses high
    var eqDb = 0.0
    var evenDb = 0.0, oddDb = 0.0
    var recipe = SaturatorRecipe.classic
    var hysteresis = 0.0, sag = 0.0
    var fuzz = 0.0, bloom = 0.0, fur = 0.0, wobble = 0.0
    var wow = 0.0, erase = 0.0
    var depth = 0.0
    var bandEQ = [0.0, 0.0, 0.0, 0.0]
    var postTube = 0.0
    var gritBits = 0.0, gritClip = 0.0, gritNoise = 0.0, gritCorpus = 0.0, gritRattle = 0.0
    var blurSmear = 0.0, blurWash = 0.0, blurSoften = 0.0, blurDistance = 0.0, blurSwell = 0.0, blurDiffuse = 0.0
    var blurSmoke = 0.0, blurUnderwater = 0.0
    var reverbStyle = "Dark Room", postReverb = 0.0
    var choirVoices = 0.0, choirDetune = 0.0, choirDelay = 0.0, choirVibrato = 0.0
    var rolloff = 0.0
    var compressor = false
    // Haze
    var gdScale = 0.0
    var blur = 0.0
    var grain = 0.0
    var reverbDecaySec = 0.0
    var shimmer = 0.0
}

struct Measurements {
    let thd100: Double, thd1k: Double          // %
    let h2: Double, h3: Double                 // 100 Hz harmonic amplitudes
    let thdn100: Double, thdn1k: Double        // %
    let imdPercent: Double                     // % of output power that is non-input frequencies
    let c50Db: Double                          // clarity, dB (∞ when nothing lands after 50 ms)
    let centerTimeMs: Double
}

enum ReportMeasurer {
    static let sr = 44100.0

    // MARK: Full chain — what actually leaves EMP

    /// The whole offline chain (the same one Save/export uses), including
    /// Post-Gain, the final tube compressor and the limiter. Mono in (both
    /// channels), mid out, latency removed.
    private static func renderFull(_ s: ChainSettings, _ input: [Float]) -> [Float] {
        let ch = OfflineChain(s), lat = OfflineChain.latency, n = input.count
        var l = input + [Float](repeating: 0, count: lat), r = l
        let total = l.count
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                var i = 0
                while i < total { let c = min(470, total - i); ch.process(left: lb.baseAddress! + i, right: rb.baseAddress! + i, count: c); i += c }
            }
        }
        return (0..<n).map { (l[$0 + lat] + r[$0 + lat]) * 0.5 }
    }

    // MARK: Haze chain (the temporal part) — stereo in, mid out

    private static func renderHaze(_ s: ChainSettings, _ input: [Float]) -> [Float] {
        let n = input.count
        let gd = GroupDelay(); gd.setScale(s.gdScale); gd.flushParameters()
        let bl = SpectralBlur(); bl.setStrength(s.blur)
        let mb = MelodyBlur(); mb.set(smear: 0, wash: s.blurWash, soften: 0, distance: 0, swell: 0, diffuse: s.blurDiffuse)
        let smr = SmearBlur(); smr.setStrength(s.blurSmear); let swl = SwellBlur(); swl.setStrength(s.blurSwell)
        let smk = SmokeBlur(); smk.setStrength(s.blurSmoke); let uw = UnderwaterBlur(); uw.setStrength(s.blurUnderwater)
        let gr = GrainEcho(); gr.setStrength(s.grain)
        let ch = Choir(); ch.setVoices(s.choirVoices); ch.setDetune(s.choirDetune)
        ch.setDelay(s.choirDelay); ch.setVibrato(s.choirVibrato)
        let rv = ConvolutionReverb(); rv.setStyle(s.reverbStyle); rv.setDecay(s.reverbDecaySec); rv.setAmount(pow(s.reverbDecaySec / 60, 1 / 1.5))
        let sh = Shimmer(); sh.setStrength(s.shimmer)
        let dp = Depth(); dp.setAmount(s.depth)
        let gl = GlowGlue(); gl.setAmount(max(s.shimmer, s.depth))
        var l = input, r = input
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                var i = 0
                while i < n {
                    let c = min(470, n - i), a = lb.baseAddress! + i, b = rb.baseAddress! + i
                    ch.process(left: a, right: b, count: c)
                    mb.process(left: a, right: b, count: c)
                    smr.process(left: a, right: b, count: c)
                    swl.process(left: a, right: b, count: c)
                    smk.process(left: a, right: b, count: c)
                    uw.process(left: a, right: b, count: c)
                    gd.process(left: a, right: b, count: c)
                    bl.process(left: a, right: b, count: c)
                    gr.process(left: a, right: b, count: c)
                    sh.process(left: a, right: b, count: c)
                    dp.process(left: a, right: b, count: c)
                    gl.process(left: a, right: b, count: c)
                    rv.process(left: a, right: b, count: c)
                    i += c
                }
            }
        }
        return (0..<n).map { (l[$0] + r[$0]) * 0.5 }
    }

    // MARK: Analysis helpers

    /// Power spectrum (Hann, 2^16 points) of the last 65 536 samples.
    /// Tones are then measured as the energy in a ±3.5 % band around each
    /// frequency: with Wow/Flutter on, the pitch wobbles by up to ~±2 %, so
    /// an exact-frequency probe missed most of the fundamental (THD+N read
    /// over 100 %).
    private static func powerSpectrum(_ x: [Float]) -> [Double] {
        let log2n = vDSP_Length(16), N = 1 << 16
        let seg = Array(x.suffix(N))
        var win = [Float](repeating: 0, count: N); vDSP_hann_window(&win, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        var w = [Float](repeating: 0, count: N); vDSP_vmul(seg, 1, win, 1, &w, 1, vDSP_Length(N))
        var re = [Float](repeating: 0, count: N / 2), im = re
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            w.withUnsafeBufferPointer { wb in
                wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(N / 2)) }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        } }
        return (0..<(N / 2)).map { Double(re[$0] * re[$0] + im[$0] * im[$0]) }
    }

    /// Energy within ±3.5 % (at least ±4 Hz) of `f`.
    private static func bandPower(_ P: [Double], _ f: Double) -> Double {
        let N = Double(1 << 16), bw = max(4, 0.035 * f)
        let lo = max(1, Int((f - bw) / sr * N)), hi = min(P.count - 1, Int((f + bw) / sr * N))
        return lo <= hi ? P[lo...hi].reduce(0, +) : 0
    }

    /// Total energy 20 Hz–20 kHz.
    private static func totalPower(_ P: [Double]) -> Double {
        let N = Double(1 << 16)
        return P[Int(20 / sr * N)...Int(20000 / sr * N)].reduce(0, +)
    }

    // MARK: Measurements

    static func measure(_ s: ChainSettings) -> Measurements {
        // 5 s settle (level-tracking stages, compressors), then analyze the last
        // 65 536 samples (~1.5 s).
        let n = Int(sr) * 6 + (1 << 16)

        func toneTest(_ f: Double) -> (thd: Double, thdn: Double, h2: Double, h3: Double) {
            // −6 dB re a full-scale input.
            let x = (0..<n).map { Float(0.5 * sin(2 * Double.pi * f * Double($0) / sr)) }
            let y = renderFull(s, x)       // after every stage, Post-Gain and limiter
            let P = powerSpectrum(y)
            let p1 = bandPower(P, f)
            var sum = 0.0, p2 = 0.0, p3 = 0.0
            for k in 2...10 where f * Double(k) * 1.04 < 20000 {
                let pk = bandPower(P, f * Double(k))
                if k == 2 { p2 = pk }; if k == 3 { p3 = pk }
                sum += pk
            }
            let residual = max(0, totalPower(P) - p1)
            return (p1 > 0 ? (sum / p1).squareRoot() * 100 : 0,
                    p1 > 0 ? (residual / p1).squareRoot() * 100 : 0, p2.squareRoot(), p3.squareRoot())
        }
        let t100 = toneTest(100), t1k = toneTest(1000)

        // Multitone: five non-harmonically related tones, same −6 dB peak budget.
        let tones: [Double] = [67, 223, 587, 1409, 3163]
        let each = 0.5 / Double(tones.count) * 1.6        // crest-factor allowance
        let mt = (0..<n).map { i -> Float in
            let t = Double(i) / sr
            return Float(tones.enumerated().reduce(0) { acc, e in
                acc + each * sin(2 * Double.pi * e.element * t + Double(e.offset) * 1.1) })
        }
        let ym = renderFull(s, mt)
        let Pm = powerSpectrum(ym)
        let total = totalPower(Pm)
        let toneEnergy = tones.reduce(0) { $0 + bandPower(Pm, $1) }
        let imd = total > 0 ? max(0, total - toneEnergy) / total * 100 : 0

        // Smear: a click (after 0.5 s of silence so effect glides settle) through the haze chain.
        let pre = Int(sr / 2), len = Int(sr * 3.5)
        var click = [Float](repeating: 0, count: len); click[pre] = 0.5
        let h = renderHaze(s, click)
        let e = h.map { Double($0) * Double($0) }
        let peak = h.map { abs($0) }.max() ?? 0
        let t0 = h.firstIndex { abs($0) >= 0.1 * peak } ?? pre       // arrival (after all latencies)
        let w50 = Int(0.050 * sr)
        let early = e[t0..<min(len, t0 + w50)].reduce(0, +)
        let late = t0 + w50 < len ? e[(t0 + w50)...].reduce(0, +) : 0
        let c50 = late > 0 ? 10 * log10(early / late) : Double.infinity
        var num = 0.0, den = 0.0
        for i in t0..<len { num += Double(i - t0) * e[i]; den += e[i] }
        let ts = den > 0 ? num / den / sr * 1000 : 0

        return Measurements(thd100: t100.thd, thd1k: t1k.thd, h2: t100.h2, h3: t100.h3,
                            thdn100: t100.thdn, thdn1k: t1k.thdn, imdPercent: imd,
                            c50Db: c50, centerTimeMs: ts)
    }
}
