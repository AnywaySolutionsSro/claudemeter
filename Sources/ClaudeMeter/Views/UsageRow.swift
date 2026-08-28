import ClaudeMeterCore
import SwiftUI

/// One rate-limit window: title, a utilization bar, percent-left, and a live reset countdown.
struct UsageRow: View {
    let title: String
    let bucket: UsageBucket
    let now: Date
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.pt(5)) {
            HStack {
                Text(title)
                    .font(scale.font(12, weight: .semibold))
                Spacer()
                Text("\(Formatting.percent(bucket.percentRemaining)) left")
                    .font(scale.font(12))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: bucket.utilization, total: 100)
                .progressViewStyle(.linear)
                .tint(tint)

            if let remaining = bucket.timeUntilReset(now: now) {
                Text("resets in \(Formatting.countdown(remaining))")
                    .font(scale.font(10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var tint: Color {
        switch bucket.percentRemaining {
        case ..<10: .red
        case ..<25: .orange
        default: .accentColor
        }
    }
}
