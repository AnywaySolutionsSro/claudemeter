import ClaudeMeterCore
import SwiftUI

/// One rate-limit window: title, a utilization bar, percent-left, and a live reset countdown.
/// `isActive` marks the window Anthropic reports as the binding constraint right now.
struct UsageRow: View {
    let title: String
    let bucket: UsageBucket
    var isActive = false
    let now: Date
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.pt(5)) {
            HStack {
                Text(title)
                    .font(scale.font(12, weight: .semibold))
                if isActive {
                    Text("limiting")
                        .font(scale.font(9, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, scale.pt(5))
                        .padding(.vertical, scale.pt(1))
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .help("Anthropic reports this window as the limit currently in effect")
                }
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
