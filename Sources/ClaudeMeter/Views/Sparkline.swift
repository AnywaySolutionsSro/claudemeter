import SwiftUI

/// A minimal line chart of values (percent), oldest → newest, from 0 at the bottom to
/// `top` at the top (`SparklineScale.top`).
struct Sparkline: View {
    let values: [Double]
    var top: Double = 100
    var color: Color = .init(nsColor: MenuBarLabel.claudeOrange)
    @Environment(\.textScale) private var scale

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let stepX = geo.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { index, value in
                    CGPoint(
                        x: CGFloat(index) * stepX,
                        y: geo.size.height - CGFloat(min(top, max(0, value)) / max(top, 1)) * geo.size.height,
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
