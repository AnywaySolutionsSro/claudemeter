import SwiftUI
import ClaudeMeterCore

/// One rate-limit window: title, a utilization bar, percent-left, and a live reset countdown.
struct UsageRow: View {
    let title: String
    let bucket: UsageBucket
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Formatting.percent(bucket.percentRemaining)) left")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: bucket.utilization, total: 100)
                .progressViewStyle(.linear)
                .tint(tint)

            if let remaining = bucket.timeUntilReset(now: now) {
                Text("resets in \(Formatting.countdown(remaining))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var tint: Color {
        switch bucket.percentRemaining {
        case ..<10: return .red
        case ..<25: return .orange
        default: return .accentColor
        }
    }
}
