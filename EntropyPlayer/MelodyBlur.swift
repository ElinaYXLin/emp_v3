import Foundation
import Accelerate

// Blur section: four ways to dissolve the melody when you don't want to
// follow it (each 0…1, 0 = dry).
//
// Smear — each frequency's level is smoothed across neighbours (up to
//   ±¼ octave) and over time (40 → 300 ms), so consecutive notes overlap and
//   melt into each other; pitches drift gently (a smooth ±25-cent field).
// Wash — a slowly averaged copy of the spectrum (~1.5 s memory) is blended
//   in place of the live spectrum: the melody dissolves into a sustained
//   cloud of the song's recent harmonies.
//
//   Both are resynthesized with a phase vocoder (true per-bin frequencies)
//   and *phase-locked* to spectral peaks: every bin follows its nearest
//   peak's steady phase, so a note's bins move as one. No per-frame random
//   phases (that made the old version shake at the frame rate), no beating.
// Soften — transient softener: note attacks are pulled down (fast vs slow
//   envelope), so onsets — what the ear tracks a melody by — blur together.
// Swell — transient-to-pad: every frequency's rise is slowed (attack
//   10 → 400 ms with the knob, quick 80 ms release), so notes bloom in like a
//   pad instead of striking. Done per STFT bin, so chords swell as chords.
// Diffuse — stereo diffusion: a decorrelated copy of the mid (4 allpasses,
//   different lengths, slowly modulated; bass below ~200 Hz kept centred) is
//   added to the sides, so the sound loses its location and surrounds you.
//   Mono-compatible: the decorrelated part cancels in L+R.
// Distance — dips the melody/presence range (a bell at 1.5 kHz, Q 0.8, so
//   roughly 600 Hz–3.5 kHz, up to −10 dB) so the lead sits as if in another
//   room. Applied after the loudness makeup, so it never lifts the low-mids.
//
// STFT 2048 / hop 256 (Hann, 87.5 % overlap), always running so latency is a
// constant 2048 samples (~46 ms). Loudness of Smear/Wash/Soften/Swell is
// matched to the input (up to +9 dB of makeup). Realtime-safe: preallocated buffers.
final class MelodyBlur {
    static let latency = 2048
    private static let n = 2048, hop = 256, bins = 1024     // 87.5 % overlap: fine, fluid steps
    private static let log2n = vDSP_Length(11)
    private static let frameRate = 44100.0 / Double(hop)
    private static let outScale = 1 / (2 * Float(n) * 3.0)      // Hann² OLA at 87.5 % sums to 3

    private let lock = NSLock()
    private var tSmear = 0.0, tWash = 0.0, tSoften = 0.0, tDist = 0.0, tSwell = 0.0, tDiffuse = 0.0
    private var smear = 0.0, wash = 0.0, soften = 0.0, dist = 0.0, swell = 0.0, diffuse = 0.0
    private let swellMag: [UnsafeMutablePointer<Float>]
    // Diffuse: allpass chain on the mid (state in Double), 200 Hz high-pass on its output.
    private static let dLen = [331, 557, 787, 1031]
    private let dBuf: [UnsafeMutablePointer<Float>]
    private var dIdx = [0, 0, 0, 0]
    private var dHP = 0.0, dHPprev = 0.0, dMod = 0.0

    private let fft = vDSP_create_fftsetup(MelodyBlur.log2n, FFTRadix(kFFTRadix2))!
    private let window: UnsafeMutablePointer<Float>
    private let inBuf, accum, ready, avg: [UnsafeMutablePointer<Float>]
    private let frame, re, im, mag, prefix: UnsafeMutablePointer<Float>
    // Fluid motion: smeared magnitudes are smoothed over ~40 ms, and phases
    // drift slowly (a random walk) instead of jumping to new random values
    // every frame, which made the sound shake at the frame rate.
    private let smMag, washPh: [UnsafeMutablePointer<Float>]
    private let drift: [UnsafeMutablePointer<Float>]
    // Phase vocoder: each bin's true frequency (in bins), from how its phase
    // advances, smoothed (fast for Smear, slow for Wash) — steady phases spin
    // at these, so neighbouring bins of one note stay coherent (no beating).
    private let prevPh, freqFast, freqSlow: [UnsafeMutablePointer<Float>]
    // Smear's pitch drift: a detune field that varies smoothly across
    // log-frequency and slowly in time (three swaying sines, up to ±25
    // cents). Neighbouring bins — the same note — share nearly the same
    // detune and stay coherent; different notes drift independently.
    private let detuneField: UnsafeMutablePointer<Float>
    // Phase locking: each bin follows the nearest spectral peak's steady
    // phase (keeping its original offset from it), so a note's bins move
    // as one and never beat against each other.
    private let tgt, swG: UnsafeMutablePointer<Float>
    private let peakS, peakW: UnsafeMutablePointer<Int>
    private var fieldT: Float = 0
    private var fill = 0
    private var rng: UInt64 = 0xB1D5_0F7E_0DD5_EED5
    private let bell = PeakingBiquad()
    private var envFast = [0.0, 0.0], envSlow = [0.0, 0.0]
    // Loudness makeup: input and output power tracked over ~300 ms; the
    // output is raised to match (up to +14 dB), so blurring never just
    // makes things quieter.
    private var pIn = 0.0, pOut = 0.0, makeup = 1.0

    init() {
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        let n = Self.n, b = Self.bins
        window = buf(n); vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf = [buf(n), buf(n)]; accum = [buf(n), buf(n)]; ready = [buf(Self.hop), buf(Self.hop)]; avg = [buf(b), buf(b)]
        frame = buf(n); re = buf(b); im = buf(b); mag = buf(b); prefix = buf(b + 1)
        smMag = [buf(b), buf(b)]; washPh = [buf(b), buf(b)]; drift = [buf(b), buf(b)]
        prevPh = [buf(b), buf(b)]; freqFast = [buf(b), buf(b)]; freqSlow = [buf(b), buf(b)]
        detuneField = buf(b); tgt = buf(b); swG = buf(b)
        swellMag = [buf(b), buf(b)]
        dBuf = Self.dLen.map { buf($0 + 64) }
        peakS = .allocate(capacity: b); peakS.initialize(repeating: 0, count: b)
        peakW = .allocate(capacity: b); peakW.initialize(repeating: 0, count: b)
        for c in 0..<2 { for k in 0..<b { freqFast[c][k] = Float(k); freqSlow[c][k] = Float(k) } }
        bell.setParameters(frequency: 1500, q: 0.8, gainDb: 0)
    }
    deinit {
        vDSP_destroy_fftsetup(fft)
        peakS.deallocate(); peakW.deallocate()
        (inBuf + accum + ready + avg + smMag + washPh + drift + prevPh + freqFast + freqSlow + swellMag + dBuf + [detuneField, tgt, swG, window, frame, re, im, mag, prefix]).forEach { $0.deallocate() }
    }

    func set(smear s: Double, wash w: Double, soften so: Double, distance d: Double, swell sw: Double = 0, diffuse df: Double = 0) {
        lock.lock()
        tSmear = max(0, min(1, s)); tWash = max(0, min(1, w)); tSoften = max(0, min(1, so)); tDist = max(0, min(1, d))
        tSwell = max(0, min(1, sw)); tDiffuse = max(0, min(1, df))
        lock.unlock()
        bell.setParameters(gainDb: -10 * max(0, min(1, d)))
    }

    @inline(__always) private func gauss() -> Float {          // ~N(0,1), cheap (sum of 4 uniforms)
        (rand() + rand() + rand() + rand() - 2) * 1.73
    }

    @inline(__always) private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let ts = tSmear, tw = tWash, tso = tSoften, td = tDist, tsw = tSwell, tdf = tDiffuse; lock.unlock()
        let g = 1 - exp(-Double(count) / (0.05 * 44100))
        smear += (ts - smear) * g; wash += (tw - wash) * g; soften += (tso - soften) * g; dist += (td - dist) * g
        swell += (tsw - swell) * g; diffuse += (tdf - diffuse) * g

        let pc = 1 - exp(-1 / (0.300 * 44100))
        for i in 0..<count { let a = Double(left[i]), b = Double(right?[i] ?? left[i]); pIn += pc * ((a * a + b * b) * 0.5 - pIn) }

        // Time-domain pre-stages: soften, distance.
        if soften > 1e-4 {
            let fA = 1 - exp(-1 / (0.001 * 44100)), fR = 1 - exp(-1 / (0.040 * 44100))
            let sA = 1 - exp(-1 / (0.030 * 44100)), sR = fR
            for ch in 0..<(right == nil ? 1 : 2) {
                let p = ch == 0 ? left : right!
                var ef = envFast[ch], es = envSlow[ch]
                for i in 0..<count {
                    let a = Double(abs(p[i]))
                    ef += (a > ef ? fA : fR) * (a - ef)
                    es += (a > es ? sA : sR) * (a - es)
                    let gain = min(1, es / max(ef, 1e-9))
                    p[i] *= Float(pow(gain, 1.5 * soften))
                }
                envFast[ch] = ef; envSlow[ch] = es
            }
        }

        // STFT stage (always runs: constant latency).
        let H = Self.hop, N = Self.n
        for i in 0..<count {
            let l = left[i], r = right?[i] ?? l
            left[i] = ready[0][fill]; right?[i] = ready[1][fill]
            inBuf[0][N - H + fill] = l; inBuf[1][N - H + fill] = r
            fill += 1
            if fill == H { fill = 0; frameStep(0); frameStep(1) }
        }

        // Loudness makeup (glides back to unity when everything is off).
        let active = max(smear, wash, soften, swell) > 1e-3
        for i in 0..<count {
            let a = Double(left[i]), b = Double(right?[i] ?? left[i])
            pOut += pc * ((a * a + b * b) * 0.5 - pOut)
            let want = active ? max(1, min(2.8, ((pIn + 1e-12) / (pOut + 1e-12)).squareRoot())) : 1
            makeup += (want - makeup) * 0.0005
            left[i] = Float(a * makeup); right?[i] = Float(b * makeup)
        }

        // Distance last, outside the makeup: dipping the melody range must not
        // be "compensated" by lifting everything else — that raised a hump
        // in the low-mids (~250–350 Hz) that sounded like a standing wave.
        if dist > 1e-4 || td > 0 {
            bell.process(left, count: count, channel: 0)
            if let r = right { bell.process(r, count: count, channel: 1) }
        }

        // Diffuse (stereo): decorrelated mid into the sides.
        if let rp = right, diffuse > 1e-4 || tdf > 0 {
            let hpC = exp(-2 * Double.pi * 200 / 44100)
            let df = Float(diffuse)
            for i in 0..<count {
                let m = (left[i] + rp[i]) * 0.5
                var v = m
                dMod += 0.37 / 44100; if dMod > 1 { dMod -= 1 }
                let wob = Float(sin(2 * Double.pi * dMod)) * 24                 // slow ±24-sample sway
                for a in 0..<4 {
                    let len = Self.dLen[a], b = dBuf[a], idx = dIdx[a]
                    // modulated read (linear interp) for the first stage only
                    var dly: Float
                    if a == 0 {
                        let pos = Float(idx) - Float(len) - wob + Float(len + 64)
                        let p0 = Int(pos) % (len + 64), fr = pos - Float(Int(pos))
                        dly = b[(p0 + len + 64) % (len + 64)] * (1 - fr) + b[(p0 + 1 + len + 64) % (len + 64)] * fr
                    } else {
                        dly = b[(idx + 64) % (len + 64)]
                    }
                    let w = v + 0.6 * dly
                    b[idx] = w
                    v = dly - 0.6 * w
                    dIdx[a] = (idx + 1) % (len + 64)
                }
                // keep bass centred
                let hp = hpC * (dHP + Double(v) - dHPprev); dHPprev = Double(v); dHP = hp
                let d = Float(hp) * 0.8 * df
                let keep = 1 - 0.25 * df
                let sd = (left[i] - rp[i]) * 0.5
                left[i] = m * keep + sd + d
                rp[i] = m * keep - sd - d
            }
        }
    }

    private func frameStep(_ ch: Int) {
        let N = Self.n, H = Self.hop, B = Self.bins
        vDSP_vmul(inBuf[ch], 1, window, 1, frame, 1, vDSP_Length(N))
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        let sm = Float(smear), wa = Float(wash)
        let A = avg[ch], S = smMag[ch], WP = washPh[ch], D = drift[ch]
        let PP = prevPh[ch], FF = freqFast[ch], FS = freqSlow[ch]
        let aCoef = Float(1 - exp(-1 / (1.5 * Self.frameRate)))
        // Smear also smooths each frequency over time (40 → 300 ms with the
        // knob), so consecutive notes overlap and melt into each other.
        let sCoef = Float(1 - exp(-1 / ((0.04 + 0.26 * smear) * Self.frameRate)))
        let expect = 2 * Float.pi * Float(H) / Float(N)
        let swAtk = Float(1 - exp(-1 / ((0.01 + 0.39 * swell) * Self.frameRate)))
        let swRel = Float(1 - exp(-1 / (0.08 * Self.frameRate)))
        if ch == 0 && smear > 1e-4 {
            fieldT += 1 / Float(Self.frameRate)
            let t = fieldT
            for k in 1..<B {
                let o = log2f(Float(k))                                   // octaves
                detuneField[k] = (sinf(o * 4.1 + t * 1.3) + sinf(o * 6.7 - t * 0.9 + 1.7) + sinf(o * 2.3 + t * 2.1 + 4.2)) / 3
            }
        }
        // True-frequency estimate per bin (always, so it's warm).
        let ffC: Float = 0.35, fsC = Float(1 - exp(-1 / (0.4 * Self.frameRate)))
        for k in 1..<B {
            let lp = atan2f(im[k], re[k])
            var d = lp - PP[k] - expect * Float(k)
            d -= 2 * Float.pi * (d / (2 * Float.pi)).rounded()
            PP[k] = lp
            let f = Float(k) + d / expect
            // Weight the frequency update by how much live energy this bin
            // carries relative to its long-term level: near-silent bins (whose
            // phase is mostly noise) hold their frequency, so Wash's sustained
            // cloud doesn't wander and flutter on quiet passages.
            let m = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            let trust = min(1, m / max(avg[ch][k], 1e-9))
            FF[k] += ffC * trust * (f - FF[k]); FS[k] += fsC * trust * (f - FS[k])
        }
        let sw = Float(swell)
        if sm > 1e-4 || wa > 1e-4 || sw > 1e-4 {
            for k in 1..<B { mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
            mag[0] = 0
            prefix[0] = 0
            for k in 0..<B { prefix[k + 1] = prefix[k] + mag[k] }
            // Pass 1: smeared, time-smoothed magnitudes; update the Wash average.
            for k in 1..<B {
                let m = mag[k]
                var target = m
                if sm > 1e-4 {
                    let w = Int(1 + Float(k) * 0.19 * sm)
                    let lo = max(1, k - w), hi = min(B - 1, k + w)
                    target = m + sm * ((prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1) - m)
                    S[k] += sCoef * (target - S[k])
                    target = m + (S[k] - m) * min(1, sm * 2)
                } else {
                    S[k] = m
                }
                if sw > 1e-4 {
                    // Swell: slow rise, quick fall — tracked per bin, but
                    // applied below as a gain curve smoothed across
                    // neighbouring bins (a many-band envelope), so a note's
                    // bins rise together instead of being reshaped one by one
                    // (which sounded metallic).
                    let SWm = swellMag[ch]
                    let c = target > SWm[k] ? swAtk : swRel
                    SWm[k] += c * (target - SWm[k])
                    swG[k] = min(1, SWm[k] / max(target, 1e-12))
                } else {
                    swellMag[ch][k] = target
                    swG[k] = 1
                }
                tgt[k] = target
                A[k] += aCoef * (target - A[k])
            }
            if sw > 1e-4 {
                let mix = min(1, sw * 4)
                prefix[0] = 0
                for k in 0..<B { prefix[k + 1] = prefix[k] + (k == 0 ? 1 : swG[k]) }
                for k in 1..<B {
                    let w = max(2, Int(Float(k) * 0.06))
                    let lo = max(1, k - w), hi = min(B - 1, k + w)
                    let gs = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
                    tgt[k] *= 1 + mix * (gs - 1)
                }
            }
            // Pass 2: nearest peak for every bin (live spectrum for Smear,
            // the Wash average for Wash).
            func nearestPeaks(_ x: UnsafeMutablePointer<Float>, _ out: UnsafeMutablePointer<Int>) {
                var last = 1
                for k in 1..<B {
                    let isPeak = k == 1 || k == B - 1 || (x[k] >= x[k - 1] && x[k] >= x[k + 1])
                    if isPeak { last = k }
                    out[k] = last
                }
                var next = B - 1
                var k = B - 1
                while k >= 1 {
                    let isPeak = k == 1 || k == B - 1 || (x[k] >= x[k - 1] && x[k] >= x[k + 1])
                    if isPeak { next = k }
                    if next - k < k - out[k] { out[k] = next }
                    k -= 1
                }
            }
            nearestPeaks(tgt, peakS)
            if wa > 1e-4 { nearestPeaks(A, peakW) }
            // Pass 3: advance the steady phases of the peaks only.
            for k in 1..<B {
                if peakS[k] == k {
                    let detune = 1 + sm * 0.0145 * detuneField[k]        // up to ±25 cents at full Smear
                    // Mostly-live bins spin at the live frequency; mostly
                    // lingering ones keep the slow-tracked (previous) one.
                    let liveFrac = min(1, mag[k] / max(tgt[k], 1e-9))
                    let f = liveFrac * FF[k] + (1 - liveFrac) * FS[k]
                    var sp = D[k] + expect * f * detune
                    sp -= 2 * Float.pi * (sp / (2 * Float.pi)).rounded()
                    D[k] = sp
                }
                // Wash cloud: every bin's phase advances at its cloud peak's
                // tracked frequency plus its own smooth random walk — a soft,
                // noise-like cloud. (Steady tones locked to peaks made Wash a
                // spectral resonator, with neighbouring peaks beating at
                // 20–30 Hz.) Continuous, so no frame-rate jumps.
                if wa > 1e-4 {
                    // Frequency-locked to the nearest cloud peak (so one note's
                    // bins share a pitch and can't beat), phase free (so it
                    // stays a soft cloud, not a resonator).
                    var wp = WP[k] + expect * FS[peakW[k]] + 0.15 * gauss()
                    wp -= 2 * Float.pi * (wp / (2 * Float.pi)).rounded()
                    WP[k] = wp
                }
            }
            // Pass 4: every other bin follows its peak, keeping its original
            // phase offset from it; then build the spectrum.
            for k in 1..<B {
                let ps = peakS[k]
                let sp = ps == k ? D[k] : D[ps] + (PP[k] - PP[ps])
                let lp = PP[k]
                let bx = (1 - sm) * cosf(lp) + sm * cosf(sp), by = (1 - sm) * sinf(lp) + sm * sinf(sp)
                let ph = atan2f(by, bx)
                // Live (smeared/swelled) part with its own phase, plus the
                // Wash cloud added on top: average spectrum, lightly smoothed
                // across neighbouring bins, with its noise-like phases.
                let live = tgt[k] * (1 - wa)
                let cloud = wa > 1e-4 ? wa * (0.25 * A[max(1, k - 1)] + 0.5 * A[k] + 0.25 * A[min(B - 1, k + 1)]) : 0
                re[k] = live * cosf(ph) + cloud * cosf(WP[k])
                im[k] = live * sinf(ph) + cloud * sinf(WP[k])
            }
            // Non-peak bins remember their derived phases so they continue
            // smoothly if they become peaks next frame.
            for k in 1..<B {
                if peakS[k] != k { D[k] = D[peakS[k]] + (PP[k] - PP[peakS[k]]) }
            }
        } else {
            // Keep state warm so Smear/Wash fade in from the current sound.
            for k in 1..<B {
                let m = (re[k] * re[k] + im[k] * im[k]).squareRoot()
                A[k] += aCoef * (m - A[k]); S[k] = m; swellMag[ch][k] = m
                // Keep the steady phases locked to the live sound while off,
                // so turning Smear/Wash up starts seamlessly.
                WP[k] = PP[k]; D[k] = PP[k]
            }
        }

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
