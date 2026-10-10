import Foundation

// Depth: the Shimmer engine pitched further down. Where Shimmer adds f/2,
// Depth adds the undertones f/3, f/4, f/5, f/6, f/7 and f/8, each from its
// own shifter reading the same delay line, then diffused, recirculated and
// loosened exactly like Shimmer (see Shimmer.swift). Its glow is high-passed
// at 25 Hz (Shimmer's is 60 Hz) so the deep undertones survive, and it
// doesn't cascade further octaves down.
//
// Timing follows consonance: the octave undertones (f/4 18 ms, f/8 25 ms)
// arrive right after Shimmer's f/2 (12 ms) and fuse with the note; the
// non-octave ones (f/3 35, f/6 40, f/5 45, f/7 50 ms) smear in later.
//
// Each undertone has its own 2-pole low-pass, lower the deeper it is (f/3
// 700 Hz down to f/8 263 Hz), so the stack stays dark and doesn't ring in
// the ~500 Hz region.
//
// The knob fades the undertones in one at a time (f/3 first, f/8 last) and
// sets the glow's level and sustain the same way Shimmer's knob does.
// At 0 only the original note. No added latency.
final class Depth {
    static let latency = 0
    /// Undertone timing, ordered by consonance rather than depth: the
    /// octaves (f/4, f/8) land soon after Shimmer's f/2 (12 ms) so they fuse
    /// with the note; the non-octave undertones (f/3, f/6, f/5, f/7), which
    /// can clash with chords, smear in later as texture. Up to 50 ms.
    static let cascadeDelays: [Double] = [35, 18, 45, 40, 50, 25]   // f/3 … f/8
    /// Each undertone's own 2-pole low-pass, lower for deeper ones:
    /// 2100 Hz × ratio → f/3 700 Hz, f/4 525, f/5 420, f/6 350, f/7 300, f/8 263.
    static let lowPasses: [Double] = (3...8).map { 2100 / Double($0) }
    private let engine = Shimmer(ratios: [1.0 / 3, 1.0 / 4, 1.0 / 5, 1.0 / 6, 1.0 / 7, 1.0 / 8],
                                 hpHz: 25, cascade: false, progressive: true,
                                 delaysMs: Depth.cascadeDelays, lowPassHz: Depth.lowPasses)

    func setAmount(_ a: Double) { engine.setStrength(a) }
    func setLowQuality(_ on: Bool) { engine.setLowQuality(on) }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        engine.process(left: left, right: right, count: count)
    }
}

// MARK: - Glow glue

// A light shared saturation right after Shimmer and Depth (before the
// reverb). Because the dry music and the glow go through the same gentle
// curve together, they intermodulate into one body: partials that would
// clash become low-mid density instead of audible beating. Drive follows the
// stronger of Shimmer/Depth (unity small-signal gain, tanh(g·x)/g); with both
// at 0 it is bypassed exactly.
final class GlowGlue {
    private let lock = NSLock()
    private var target = 0.0, amount = 0.0
    func setAmount(_ a: Double) { lock.lock(); target = max(0, min(1, a)); lock.unlock() }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock(); let t = target; lock.unlock()
        if t == 0 && amount < 1e-4 { amount = 0; return }
        let step = (t - amount) * (1 - exp(-Double(count) / (0.05 * 44100))) / Double(count)
        for i in 0..<count {
            amount += step
            let g = Float(1 + 2.5 * amount)
            left[i] = tanhf(left[i] * g) / g
            if let r = right { r[i] = tanhf(r[i] * g) / g }
        }
    }
}
