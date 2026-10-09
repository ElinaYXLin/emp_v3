import Foundation

// Depth: the Shimmer engine pitched further down. Where Shimmer adds f/2,
// Depth adds the undertones f/3, f/4, f/5, f/6, f/7 and f/8, each from its
// own shifter reading the same delay line, then diffused, recirculated and
// loosened exactly like Shimmer (see Shimmer.swift). Its glow is high-passed
// at 25 Hz (Shimmer's is 60 Hz) so the deep undertones survive, and it
// doesn't cascade further octaves down.
//
// The undertones cascade in time: deeper ones arrive later, from f/3 at
// ~18 ms to f/8 at 50 ms behind the note (Shimmer's f/2 is at 12 ms), so
// they unfold downward from the note instead of all landing at once.
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
    /// Undertone cascade: Shimmer's f/2 arrives 12 ms after the note, f/8
    /// 50 ms, evenly spaced in between (f/3 ≈ 18 ms … f/7 ≈ 44 ms).
    static func cascadeMs(_ divisor: Double) -> Double { 12 + (divisor - 2) / 6 * 38 }
    /// Each undertone's own 2-pole low-pass, lower for deeper ones:
    /// 2100 Hz × ratio → f/3 700 Hz, f/4 525, f/5 420, f/6 350, f/7 300, f/8 263.
    static let lowPasses: [Double] = (3...8).map { 2100 / Double($0) }
    static let cascadeDelays: [Double] = (3...8).map { cascadeMs(Double($0)) }
    private let engine = Shimmer(ratios: [1.0 / 3, 1.0 / 4, 1.0 / 5, 1.0 / 6, 1.0 / 7, 1.0 / 8],
                                 hpHz: 25, cascade: false, progressive: true,
                                 delaysMs: Depth.cascadeDelays, lowPassHz: Depth.lowPasses)

    func setAmount(_ a: Double) { engine.setStrength(a) }
    func setLowQuality(_ on: Bool) { engine.setLowQuality(on) }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        engine.process(left: left, right: right, count: count)
    }
}
