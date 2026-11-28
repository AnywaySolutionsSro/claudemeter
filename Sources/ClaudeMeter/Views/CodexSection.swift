import ClaudeMeterCore
import SwiftUI

/// A coloured "● Claude" / "● Codex" heading, shown only once Codex is present so a
/// Claude-only dropdown looks exactly as before.
struct ToolHeader<Trailing: View>: View {
    let tool: AgentTool
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.textScale) private var scale

    var body: some View {
        HStack(spacing: scale.pt(5)) {
            Circle().fill(Color(tool: tool)).frame(width: scale.pt(8), height: scale.pt(8))
            Text(ToolPalette.name(for: tool))
                .font(scale.font(12, weight: .bold))
                .foregroundColor(Color(tool: tool))
            Spacer()
            trailing()
        }
    }
}

extension ToolHeader where Trailing == EmptyView {
    init(tool: AgentTool) {
        self.init(tool: tool) { EmptyView() }
    }
}

/// Codex's limit windows and sessions in the dropdown, shown once signed in to ChatGPT
/// (signed out, the dropdown has only `CodexConnectSection`). A transcript reading can
/// still be the newer one, so the reading's age is shown (it hides while a live reading
/// is under 2 minutes old), and a window whose reset passed since says so instead of
/// counting down.
struct CodexSection: View {
    let now: Date
    /// "Remind me when it resets" for Codex's blocking window.
    var onRemind: (LimitWindow) -> Void = { _ in }

    @EnvironmentObject private var monitor: SessionMonitor
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var chatGPT: ChatGPTAuthModel
    @Environment(\.textScale) private var scale
    /// The window (id + reset moment) a reminder was scheduled for, so a second click
    /// neither schedules twice nor leaves the user guessing.
    @State private var remindedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: scale.pt(10)) {
            ToolHeader(tool: .codex) {
                if let asOf = monitor.codexAsOf, !isFreshLive {
                    Text("as of \(Formatting.clockTime(asOf, style: settings.clockStyle))")
                        .font(scale.font(10)).foregroundColor(.secondary)
                        .help(chatGPT.isSignedIn
                            ? "When this Codex limit reading was taken"
                            : "Codex limits refresh only when a Codex turn runs")
                }
            }
            if let limits = monitor.codexLimits {
                ForEach(limits.limitWindows) { window in
                    UsageRow(
                        title: window.label, bucket: window.bucket, now: now,
                        accent: Color(tool: .codex),
                        footnote: CodexDisplay.staleResetNote(window.bucket, now: now, style: settings.clockStyle),
                    )
                }
                let insights = monitor.codexInsights
                UsageInsightsView(
                    snapshot: limits, history: insights.history, burn: insights.burn,
                    paceRatio: insights.paceRatio, now: now, tint: Color(tool: .codex),
                )
                cooldownBox(limits)
            } else {
                Text("Fetching live Codex limits…")
                    .font(scale.font(11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(CodexDisplay.activityLine(
                sessions: monitor.sessions, armedIDs: Set(monitor.snapshot?.armedSessionIDs ?? []),
            ))
            .font(scale.font(11)).foregroundColor(.secondary)
        }
    }

    private var isFreshLive: Bool {
        CodexLimitSource.isFreshLive(monitor.codexLiveReading, shown: monitor.codexReading, now: now)
    }

    /// Mirrors Claude's cooling-down box, with the reminder namespaced to Codex.
    @ViewBuilder private func cooldownBox(_ limits: UsageSnapshot) -> some View {
        if let window = limits.blockingWindow, let reset = window.bucket.timeUntilReset(now: now) {
            VStack(alignment: .leading, spacing: scale.pt(6)) {
                Text("Codex is cooling down")
                    .font(scale.font(12, weight: .semibold))
                Text("Codex's \(window.phrase) is used up — resets in \(Formatting.countdown(reset)).")
                    .font(scale.font(11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let key = "\(window.id)|\(window.bucket.resetsAt?.timeIntervalSince1970 ?? 0)"
                if remindedKey == key {
                    Label("Reminder set", systemImage: "checkmark")
                        .font(scale.font(11)).foregroundColor(.secondary)
                } else {
                    Button("Remind me when it resets") {
                        onRemind(window)
                        remindedKey = key
                    }
                    .font(scale.font(11))
                }
            }
            .padding(scale.pt(8))
            .background(RoundedRectangle(cornerRadius: scale.pt(8)).fill(Color(tool: .codex).opacity(0.12)))
        }
    }
}
