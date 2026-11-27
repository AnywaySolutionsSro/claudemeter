import AppKit
import ClaudeMeterCore
import SwiftUI

/// The dropdown shown when the menu-bar item is clicked.
struct MenuContentView: View {
    /// Invoked when the user opens the Live Sessions window.
    var onOpenSessions: () -> Void = {}
    /// Invoked when the user opens the Settings window.
    var onOpenSettings: () -> Void = {}
    /// "Remind me when it resets" for a Codex window (namespaced apart from Claude's).
    var onRemindCodex: (LimitWindow) -> Void = { _ in }

    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var updates: UpdateService
    @EnvironmentObject var monitor: SessionMonitor
    @EnvironmentObject var chatGPT: ChatGPTAuthModel
    @Environment(\.textScale) private var scale
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: scale.pt(12)) {
            header
            Divider()
            UpdateBanner()
            ForEach(Array(plan.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                view(for: section, plan: plan)
            }
            // Outside the sign-in sections on purpose: API spend uses the admin key, which
            // has nothing to do with the OAuth subscription login.
            ApiSpendSection(now: now)
            Divider()
            footer(plan)
        }
        .padding(scale.pt(14))
        .frame(width: scale.pt(300))
        .onReceive(ticker) { now = $0 }
    }

    /// Connected tools' data first, connect buttons last, hidden tools left out.
    private var visibility: ToolVisibility {
        ToolVisibility(showClaude: settings.showClaude, showCodex: settings.showCodex,
                       codexAvailable: monitor.codexPresent || chatGPT.isSignedIn)
    }

    private var plan: DropdownPlan {
        DropdownPlan.make(visibility: visibility, claudeSignedIn: auth.isSignedIn,
                          codexConnected: chatGPT.isSignedIn)
    }

    @ViewBuilder private func view(for section: DropdownSection, plan: DropdownPlan) -> some View {
        switch section {
        case .claudeUsage:
            VStack(alignment: .leading, spacing: scale.pt(12)) {
                // Headed only next to Codex: a Claude-only dropdown looks as it always did.
                if plan.showsToolHeaders { ToolHeader(tool: .claude) }
                usageContent
            }
        case .codexUsage:
            CodexSection(now: now, onRemind: onRemindCodex)
        case .connectClaude:
            ClaudeConnectSection()
        case .connectCodex:
            CodexConnectSection()
        }
    }

    private var header: some View {
        HStack(spacing: scale.pt(6)) {
            Image(systemName: "gauge.medium").font(scale.font(13))
            Text("ClaudeMeter").font(scale.font(13, weight: .bold))
            if let version = updates.currentVersion {
                // The running version — after a self-update this is the proof it landed.
                Text(version.description).font(scale.font(11)).foregroundColor(.secondary)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Button(action: onOpenSessions) {
                Image(systemName: "list.bullet.rectangle").font(scale.font(13))
            }
            .buttonStyle(.borderless)
            .help("Live token usage per session")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(scale.font(13))
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    // MARK: - Signed in

    @ViewBuilder private var usageContent: some View {
        if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: scale.pt(12)) {
                ForEach(snapshot.allBuckets) { row in
                    UsageRow(title: row.title, bucket: row.bucket, isActive: row.isActive, now: now)
                }
                ExtraUsageSection(usage: snapshot.extraUsage)
                insights
                cooldownBox
            }
        } else if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(scale.font(11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Loading usage…").font(scale.font(12)).foregroundColor(.secondary)
        }
    }

    private var insights: some View {
        UsageInsightsView(
            snapshot: store.snapshot, history: store.history, burn: store.burnEstimate,
            paceRatio: store.paceRatio, now: now,
        )
    }

    @ViewBuilder private var cooldownBox: some View {
        if let window = store.snapshot?.blockingWindow, let reset = window.bucket.timeUntilReset(now: now) {
            VStack(alignment: .leading, spacing: scale.pt(6)) {
                Text("Cooling down")
                    .font(scale.font(12, weight: .semibold))
                Text(
                    "Your \(window.phrase) is used up — resets in \(Formatting.countdown(reset)). Good time for a break.",
                )
                .font(scale.font(11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Remind me when it resets") {
                    if let resetAt = window.bucket.resetsAt {
                        NotificationManager().scheduleResetReminder(
                            at: resetAt, for: window, tool: .claude, codexPresent: monitor.codexPresent,
                        )
                    }
                }
                .font(scale.font(11))
            }
            .padding(scale.pt(8))
            .background(RoundedRectangle(cornerRadius: scale.pt(8)).fill(Color.orange.opacity(0.12)))
        }
    }

    /// The one footer, always last whatever is signed in: Claude's status and Refresh
    /// (while its usage shows), the extra-options menu, and Quit at the very bottom.
    private func footer(_ plan: DropdownPlan) -> some View {
        VStack(alignment: .leading, spacing: scale.pt(8)) {
            if plan.showsRefresh {
                if let note = store.statusNote {
                    Text(note).font(scale.font(10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let updated = store.lastUpdated {
                        Text("Updated \(Formatting.clockTime(updated, style: settings.clockStyle))")
                            .font(scale.font(10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { Task { await store.refresh(force: true) } }
                        .font(scale.font(11))
                }
            }
            HStack {
                quickLinksMenu
                Spacer()
                // Signing out lives in Settings, next to each account it belongs to.
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(scale.font(11))
            }
        }
    }

    @ViewBuilder private var claudeLinks: some View {
        Link("Buy more usage", destination: URL(string: "https://claude.ai/settings/usage")!)
        Link("Upgrade plan", destination: URL(string: "https://claude.ai/settings/billing")!)
        Link("Usage help", destination: URL(string: "https://support.claude.com")!)
    }

    /// The pages the Codex CLI itself points at for credits and upgrades.
    @ViewBuilder private var codexLinks: some View {
        Link("Buy more usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
        Link("Upgrade plan", destination: URL(string: "https://chatgpt.com/explore/plus")!)
        Link("Usage help", destination: URL(string: "https://help.openai.com")!)
    }

    private var quickLinksMenu: some View {
        Menu("⋯") {
            let visibility = visibility
            if visibility.showsClaude, visibility.showsCodex {
                // Both tools: one titled group each, so it is clear whose page opens.
                Section("Claude") { claudeLinks }
                Section("Codex") { codexLinks }
            } else if visibility.showsCodex {
                codexLinks
            } else {
                claudeLinks
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: scale.pt(28))
        .font(scale.font(11))
    }
}
