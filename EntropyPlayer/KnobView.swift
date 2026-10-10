import SwiftUI
import AppKit

// Parameter control: a vertical glass cylinder that fills from the bottom
// with the value, its colour blending from the interface grey to the
// accent, with a small line icon inside (like the filament of a tube) that
// identifies the parameter. Click or drag to the height you want.
struct KnobView: View {
    let label: String
    let sublabel: String
    @Binding var value: Double          // 0–100
    let display: (Double) -> String
    var labelWidth: CGFloat = 70
    /// Mini mode: title on top, smaller cylinder, in a small inset box.
    var compact: Bool = false
    /// SF Symbol drawn inside the cylinder.
    var symbol: String = "circle.dotted"

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var fullBody: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#d9d1bf"))
                if !sublabel.isEmpty {
                    Text(sublabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(hex: "#8f8778"))
                }
            }
            .frame(width: labelWidth, alignment: .leading)

            VStack(spacing: 4) {
                CylinderControl(value: $value, symbol: symbol, width: 26, height: 62)
                Text(display(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "#8f8778"))
                    .frame(width: 48)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var compactBody: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "#d9d1bf"))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: 22)
            CylinderControl(value: $value, symbol: symbol, width: 22, height: 44)
            Text(display(value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Color(hex: "#8f8778"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 5).padding(.horizontal, 3)
        .frame(width: 72)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// The cylinder itself (also usable on its own).
struct CylinderControl: View {
    @Binding var value: Double
    let symbol: String
    let width: CGFloat
    let height: CGFloat
    @State private var startValue: Double = 0

    // Interface grey → accent.
    private static let grey = (r: 66.0, g: 63.0, b: 58.0)       // #423f3a
    private static let accent = (r: 255.0, g: 122.0, b: 61.0)   // #ff7a3d
    private var fillColor: Color {
        let t = max(0, min(1, value / 100))
        func mix(_ a: Double, _ b: Double) -> Double { (a + (b - a) * t) / 255 }
        return Color(red: mix(Self.grey.r, Self.accent.r), green: mix(Self.grey.g, Self.accent.g), blue: mix(Self.grey.b, Self.accent.b))
    }

    var body: some View {
        let radius = width / 2.6
        let fillH = height * CGFloat(max(0, min(1, value / 100)))
        ZStack(alignment: .bottom) {
            // Body: the interface grey, shaded so it reads as round glass.
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(hex: "#2e2a25"))
            // Fill from the bottom, grey → accent.
            RoundedRectangle(cornerRadius: radius)
                .fill(fillColor)
                .frame(height: max(fillH, value > 0.5 ? radius * 1.2 : 0))
                .shadow(color: fillColor.opacity(value > 1 ? 0.55 : 0), radius: 4)
            // Roundness: light down the middle, dark at the edges.
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.38),
                    .init(color: .white.opacity(0.05), location: 0.55),
                    .init(color: .black.opacity(0.5), location: 1)],
                    startPoint: .leading, endPoint: .trailing))
            // The "filament": a small line icon for the parameter.
            Image(systemName: symbol)
                .font(.system(size: width * 0.45, weight: .light))
                .foregroundColor(Color(hex: "#f2ead8").opacity(0.55 + 0.4 * value / 100))
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: radius)
                .stroke(Color.black.opacity(0.6), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        // Click anywhere on the cylinder to set the value to that height;
        // dragging follows the pointer exactly (absolute, not relative —
        // the old relative drag re-based itself on every change and raced
        // to the maximum). Hold ⌥ for fine adjustment (¼ speed, relative).
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if NSEvent.modifierFlags.contains(.option) {
                        let delta = Double(-drag.translation.height) / Double(height) * 25
                        value = max(0, min(100, (startValue + delta).rounded()))
                    } else {
                        let v = Double(1 - drag.location.y / height) * 100
                        value = max(0, min(100, v.rounded()))
                    }
                }
                .onEnded { _ in startValue = value }
        )
        .onAppear { startValue = value }
        .help(String(format: "%.0f%% — click to set, ⌥-drag for fine control", value))
    }
}

/// Slender vertical two-handle range slider (min at the bottom, max at the
/// top), a lighter version of the interface grey.
struct RangeSliderV: View {
    @Binding var minValue: Double      // 0–100
    @Binding var maxValue: Double      // 0–100
    var height: CGFloat = 62

    var body: some View {
        let track = Color(hex: "#6e6a62"), active = Color(hex: "#a39d92"), handle = Color(hex: "#c4bdb0")
        let yMax = height * CGFloat(1 - maxValue / 100), yMin = height * CGFloat(1 - minValue / 100)
        ZStack(alignment: .top) {
            Capsule().fill(track.opacity(0.55)).frame(width: 2, height: height)
            Capsule().fill(active).frame(width: 3, height: max(1, yMin - yMax)).offset(y: yMax)
            // Max handle
            Capsule().fill(handle).frame(width: 11, height: 4)
                .offset(y: yMax - 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    let v = Double(1 - d.location.y / height) * 100
                    maxValue = Swift.max(minValue + 1, Swift.min(100, v.rounded()))
                })
            // Min handle
            Capsule().fill(handle).frame(width: 11, height: 4)
                .offset(y: yMin - 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    let v = Double(1 - d.location.y / height) * 100
                    minValue = Swift.max(0, Swift.min(maxValue - 1, v.rounded()))
                })
        }
        .frame(width: 14, height: height, alignment: .top)
        .coordinateSpace(name: "range")
        .help(String(format: "Range %.0f–%.0f%%", minValue, maxValue))
    }
}
