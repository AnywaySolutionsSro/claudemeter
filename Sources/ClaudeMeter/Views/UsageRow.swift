import ClaudeMeterCore
import SwiftUI

/// One rate-limit window: title, a utilization bar, percent-left, and a live reset countdown
/// plus the wall-clock moment it resets (`resets in 4d10h · Sat 28 Nov 06:00`).
/// `isActive` marks the window Anthropic reports as the binding constraint right now.
struct UsageRow: View {
    let title: String
    let bucket: UsageBucket
    var isActive = false
    let now: Date
    /// Bar colour while the window is healthy (Codex rows use Codex green); `nil` is the accent colour.
    var accent: Color?
    /// Shown instead of the reset line when the window has no upcoming reset to count down to.
    var footnote: String?
    @Environment(\.textScale) private var scale
    @EnvironmentObject private var settings: Settings

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

            if let remaining = bucket.timeUntilReset(now: now), let resetsAt = bucket.resetsAt {
                Text(
                    "resets in \(Formatting.countdown(remaining)) · \(Formatting.resetMoment(resetsAt, now: now, style: settings.clockStyle))",
                )
                .font(scale.font(10))
                .foregroundColor(.secondary)
                .monospacedDigit()
            } else if let footnote {
                Text(footnote)
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
        default: accent ?? .accentColor
        }
    }
}
