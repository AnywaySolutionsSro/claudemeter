import ClaudeMeterCore
import SwiftUI

/// "Extra usage" block in the dropdown: what the paid overage allowance has cost this
/// month, how close it is to the monthly cap, and links to manage it on claude.ai.
///
/// Renders nothing when the account has no extra-usage allowance at all, or when the
/// reading could not be parsed completely — a partially-read amount must never appear
/// as a confident zero.
struct ExtraUsageSection: View {
    let usage: ExtraUsage?
    @Environment(\.textScale) private var scale

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: scale.pt(5)) {
                Divider()
                header(usage)
                if usage.isEnabled {
                    details(usage)
                }
                links(usage)
            }
        }
    }

    private func header(_ usage: ExtraUsage) -> some View {
        HStack {
            Text("Extra usage").font(scale.font(12, weight: .semibold))
            Spacer()
            if usage.isEnabled, let percent = usage.percentUsed {
                Text(Formatting.percent(percent))
                    .font(scale.font(12)).foregroundColor(.secondary).monospacedDigit()
            } else if !usage.isEnabled {
                Text("off").font(scale.font(12)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func details(_ usage: ExtraUsage) -> some View {
        HStack(spacing: scale.pt(4)) {
            Text(usage.headline).font(scale.font(11)).monospacedDigit()
            if usage.limit != nil {
                Text("this month").font(scale.font(11)).foregroundColor(.secondary)
            } else {
                Text("· no limit set").font(scale.font(11)).foregroundColor(.secondary)
            }
        }

        if let percent = usage.percentUsed {
            ProgressView(value: percent, total: 100)
                .progressViewStyle(.linear)
                .tint(tint(percent))
        }

        if let blocked = usage.blockedMessage {
            Label(blocked, systemImage: "exclamationmark.octagon")
                .font(scale.font(10)).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func links(_ usage: ExtraUsage) -> some View {
        HStack(spacing: scale.pt(10)) {
            Spacer()
            link(usage.isEnabled ? "Manage" : "Turn on at claude.ai")
            // Only when the server says this account can buy at all — on most
            // subscription plans it cannot, and a dead button is worse than none.
            if usage.canPurchase {
                link("Buy credits")
            }
        }
    }

    private func link(_ title: String) -> some View {
        Button {
            ClaudeLinks.open(ClaudeLinks.usageSettings)
        } label: {
            HStack(spacing: scale.pt(2)) {
                Text(title).font(scale.font(11))
                Image(systemName: "arrow.up.forward.square").font(scale.font(9))
            }
        }
        .buttonStyle(.link)
        .help("Opens claude.ai — ClaudeMeter never changes your billing itself")
    }

    /// Matches `UsageRow`'s ramp, read from the spent side rather than the left side.
    private func tint(_ percentUsed: Double) -> Color {
        switch percentUsed {
        case 95...: .red
        case 80...: .orange
        default: .accentColor
        }
    }
}
