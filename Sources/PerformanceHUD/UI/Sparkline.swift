import SwiftUI

/// A tiny line chart for a rolling history of values, filled under the line.
struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cap = max(maxValue, 0.0001)

            ZStack {
                // Fill under the line.
                linePath(w: w, h: h, cap: cap, closed: true)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                // The line itself.
                linePath(w: w, h: h, cap: cap, closed: false)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }

    private func linePath(w: CGFloat, h: CGFloat, cap: Double, closed: Bool) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let stepX = w / CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                let clamped = min(max(values[i], 0), cap)
                let y = h - (CGFloat(clamped / cap) * h)
                return CGPoint(x: CGFloat(i) * stepX, y: y)
            }
            path.move(to: point(0))
            for i in 1..<values.count { path.addLine(to: point(i)) }
            if closed {
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
            }
        }
    }
}
