import ClaudeMeterCore
import SwiftUI

/// The burn-rate / pace lines, sparkline and "Maxed N…" line under a tool's limit
/// rows. Claude feeds it `UsageStore`'s history, Codex `SessionMonitor.codexInsights`.
struct UsageInsightsView: View {
    let snapshot: UsageSnapshot?
    let history: [UsageSample]
    let burn: BurnEstimate?
    let paceRatio: Double?
    let now: Date
    var tint: Color = .init(nsColor: MenuBarLabel.claudeOrange)
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.pt(6)) {
            HStack(spacing: scale.pt(4)) {
                if let burn, burn.isBurning {
                    Text("🔥 Spending ~\(Formatting.perHour(burn.percentPerHour))")
                        .font(scale.font(11, weight: .medium))
                    Text(burnDetail(burn))
                        .font(scale.font(11)).foregroundColor(.secondary)
                } else {
                    Text("💤 Idle — not spending right now")
                        .font(scale.font(11)).foregroundColor(.secondary)
                }
            }
            if let line = weeklyPaceLine {
                Text(line).font(scale.font(11)).foregroundColor(.secondary)
            }
            if let ratio = paceRatio, ratio >= 1.2 || ratio <= 0.8 {
                Text(String(format: "%.1f× your usual pace", ratio))
                    .font(scale.font(10)).foregroundColor(.secondary)
            }

            if sparklineValues.count >= 2 {
                Sparkline(values: sparklineValues, color: tint)
                    .frame(height: scale.pt(28))
                    .padding(.top, scale.pt(2))
            }

            if maxedThisWeek > 0 {
                Text("Maxed \(maxedThisWeek) session window\(maxedThisWeek == 1 ? "" : "s") this week")
                    .font(scale.font(10)).foregroundColor(.secondary)
            }
        }
    }

    private func burnDetail(_ burn: BurnEstimate) -> String {
        // A weekly window's verdict is the pace line: an hour's rate says nothing
        // about whether the week will run out.
        guard snapshot?.fiveHour != nil, let eta = burn.etaToLimit else { return "" }
        let reset = snapshot?.primary?.timeUntilReset(now: now)
        if let reset, eta < reset {
            return "· hits limit in ~\(Formatting.countdown(eta))"
        }
        return "· won't max out before reset"
    }

    private var sparklineValues: [Double] {
        UsageStats.currentWindowTrend(samples: history)
    }

    /// Only for weekly-only accounts, where the week is the window that matters.
    private var weeklyPaceLine: String? {
        guard
            snapshot?.fiveHour == nil,
            let weekly = snapshot?.sevenDay,
            let pace = WeeklyPace.estimate(weekly, now: now)
        else {
            return nil
        }
        if let runsOutIn = pace.runsOutIn {
            return "📈 Ahead of the week — runs out in ~\(Formatting.countdown(runsOutIn))"
        }
        return "✅ On track for this week"
    }

    private var maxedThisWeek: Int {
        UsageStats.maxedWindows(samples: history, since: now.addingTimeInterval(-7 * 24 * 3600))
    }
}
