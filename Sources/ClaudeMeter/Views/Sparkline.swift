import SwiftUI

/// A minimal line chart of values (0–100), oldest → newest.
struct Sparkline: View {
    let values: [Double]
    var color: Color = .init(nsColor: MenuBarLabel.claudeOrange)
    @Environment(\.textScale) private var scale

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let stepX = geo.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { index, value in
                    CGPoint(
                        x: CGFloat(index) * stepX,
                        y: geo.size.height - CGFloat(min(100, max(0, value)) / 100) * geo.size.height,
                    )
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.15))

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: scale.pt(1.5), lineJoin: .round))
                }
            }
        }
    }
}
