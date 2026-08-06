import SwiftUI
import ClaudeMeterCore

/// One session in the Live Sessions list: live dot, project + origin, models,
/// and the headline token total (with cached + burn-rate secondary detail).
struct SessionRow: View {
    let session: SessionUsage
    let now: Date
    var terminalKind: TerminalKind = .unknown
    /// Non-nil when the session can't be armed; shown as the toggle's tooltip.
    /// Mirrors the widget: a disabled toggle is dimmed, not just non-interactive.
    var armDisabledReason: String?
    var isArmed: Bool = false
    var onArmChange: (Bool) -> Void = { _ in }
    @Environment(\.textScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: scale.pt(10)) {
            runningDot
                .padding(.top, scale.pt(3))

            VStack(alignment: .leading, spacing: scale.pt(2)) {
                HStack(spacing: scale.pt(6)) {
                    Text(session.projectName)
                        .font(scale.font(12, weight: .semibold))
                        .lineLimit(1)
                    originBadge
                }
                Text(subtitle)
                    .font(scale.font(10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: scale.pt(8))

            VStack(alignment: .trailing, spacing: scale.pt(2)) {
                Text(Formatting.tokenCount(session.totalTokens))
                    .font(scale.font(12, weight: .semibold))
                    .monospacedDigit()
                Text(secondary)
                    .font(scale.font(9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            let canArm = armDisabledReason == nil
            Toggle("", isOn: Binding(get: { isArmed }, set: { onArmChange($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .disabled(!canArm)
                .opacity(canArm ? 1 : 0.35)
                .help(armDisabledReason ?? "Auto-resume this session when quota refreshes")
        }
        .padding(.vertical, scale.pt(3))
    }

    private var runningDot: some View {
        Circle()
            .fill(session.running == .running ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: scale.pt(8), height: scale.pt(8))
    }

    private var originBadge: some View {
        Text(session.origin == .cli ? "CLI" : "APP")
            .font(scale.font(8, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, scale.pt(4))
            .padding(.vertical, scale.pt(1))
            .background(RoundedRectangle(cornerRadius: scale.pt(3)).fill(Color.secondary.opacity(0.12)))
    }

    private var subtitle: String {
        // The model currently in use, not the alphabetically-last one ever seen.
        let model = (session.lastModel ?? session.models.last).map(shortModel) ?? "—"
        return "\(model) · \(relativeActivity)"
    }

    private var secondary: String {
        var parts: [String] = []
        if session.cacheReadTokens > 0 { parts.append("+\(Formatting.tokenCount(session.cacheReadTokens)) cached") }
        if session.burnRate >= 1 { parts.append("\(Int(session.burnRate.rounded())) t/m") }
        return parts.joined(separator: " · ")
    }

    private var relativeActivity: String {
        let elapsed = now.timeIntervalSince(session.lastActivity)
        if elapsed < 0 { return "now" }
        return "\(Formatting.countdown(elapsed)) ago"
    }

    /// Trim the common `claude-` prefix for compact display, e.g. `opus-4-8`.
    private func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}
