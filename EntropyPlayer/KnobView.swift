import SwiftUI

struct KnobView: View {
    let label: String
    let sublabel: String
    @Binding var value: Double          // 0–100
    let display: (Double) -> String
    var labelWidth: CGFloat = 70
    /// Mini mode: title on top, smaller knob, in a small inset box.
    var compact: Bool = false

    @State private var startValue: Double = 0

    var body: some View {
        if compact { compactBody } else { fullBody }
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
            knob(size: 32)
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
                knob(size: 40)

                Text(display(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "#8f8778"))
                    .frame(width: 44)
            }
        }
    }

    private func knob(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: "#55504a"), Color(hex: "#1e1b17")],
                    center: .init(x: 0.34, y: 0.28),
                    startRadius: 0, endRadius: size * 0.55))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))

            // indicator dot
            Circle()
                .fill(Color(hex: "#ff7a3d"))
                .frame(width: 3, height: 3)
                .shadow(color: Color(hex: "#ff7a3d"), radius: 4)
                .offset(y: -size * 0.33)
                .rotationEffect(.degrees(-135 + value / 100 * 270))
        }
        // Without this, only the inscribed circle registers drags —
        // the corners of its own 40x40 bounding box (still visually
        // "on the knob" to a user) are dead space by SwiftUI's default
        // hit-testing for a Circle shape.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let delta = Double(-drag.translation.height) * 0.55
                    value = max(0, min(100, startValue + delta))
                }
                .onEnded { _ in startValue = value }
        )
        .onAppear { startValue = value }
    }
}
