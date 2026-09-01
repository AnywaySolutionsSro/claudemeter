import AppKit
import ClaudeMeterCore
import SwiftUI

/// The dropdown shown when the menu-bar item is clicked.
struct MenuContentView: View {
    /// Invoked when the user opens the Live Sessions window.
    var onOpenSessions: () -> Void = {}
    /// Invoked when the user opens the Settings window.
    var onOpenSettings: () -> Void = {}

    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var updates: UpdateService
    @Environment(\.textScale) private var scale
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: scale.pt(12)) {
            header
            Divider()
            UpdateBanner()
            if auth.isSignedIn {
                usageContent
                Divider()
                signedInFooter
            } else {
                loginContent
            }
            // Outside the sign-in branch on purpose: API spend uses the admin key, which
            // has nothing to do with the OAuth subscription login.
            ApiSpendSection(now: now)
        }
        .padding(scale.pt(14))
        .frame(width: scale.pt(300))
        .onReceive(ticker) { now = $0 }
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
        VStack(alignment: .leading, spacing: scale.pt(6)) {
            HStack(spacing: scale.pt(4)) {
                if let burn = store.burnEstimate, burn.isBurning {
                    Text("🔥 Spending ~\(Int(burn.percentPerHour.rounded()))%/hr")
                        .font(scale.font(11, weight: .medium))
                    Text(burnDetail(burn))
                        .font(scale.font(11)).foregroundColor(.secondary)
                } else {
                    Text("💤 Idle — not spending right now")
                        .font(scale.font(11)).foregroundColor(.secondary)
                }
            }
            if let ratio = store.paceRatio, ratio >= 1.2 || ratio <= 0.8 {
                Text(String(format: "%.1f× your usual pace", ratio))
                    .font(scale.font(10)).foregroundColor(.secondary)
            }

            if sparklineValues.count >= 2 {
                Sparkline(values: sparklineValues)
                    .frame(height: scale.pt(28))
                    .padding(.top, scale.pt(2))
            }

            if maxedThisWeek > 0 {
                Text("Maxed \(maxedThisWeek) session window\(maxedThisWeek == 1 ? "" : "s") this week")
                    .font(scale.font(10)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var cooldownBox: some View {
        if let bucket = store.snapshot?.primary, bucket.percentRemaining <= 0.5,
           let reset = bucket.timeUntilReset(now: now) {
            VStack(alignment: .leading, spacing: scale.pt(6)) {
                Text("Cooling down")
                    .font(scale.font(12, weight: .semibold))
                Text("Session is empty — resets in \(Formatting.countdown(reset)). Good time for a break.")
                    .font(scale.font(11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remind me when it resets") {
                    if let resetAt = bucket.resetsAt { NotificationManager().scheduleResetReminder(at: resetAt) }
                }
                .font(scale.font(11))
            }
            .padding(scale.pt(8))
            .background(RoundedRectangle(cornerRadius: scale.pt(8)).fill(Color.orange.opacity(0.12)))
        }
    }

    private var signedInFooter: some View {
        VStack(alignment: .leading, spacing: scale.pt(8)) {
            if let note = store.statusNote {
                Text(note).font(scale.font(10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let updated = store.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(scale.font(10)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh(force: true) } }
                    .font(scale.font(11))
            }

            HStack {
                quickLinksMenu
                Spacer()
                Button("Sign out") { auth.signOut() }.font(scale.font(11))
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(scale.font(11))
            }
        }
    }

    private var quickLinksMenu: some View {
        Menu("⋯") {
            Link("Buy more usage", destination: URL(string: "https://claude.ai/settings/usage")!)
            Link("Upgrade plan", destination: URL(string: "https://claude.ai/settings/billing")!)
            Link("Usage help", destination: URL(string: "https://support.claude.com")!)
        }
        .menuStyle(.borderlessButton)
        .frame(width: scale.pt(28))
        .font(scale.font(11))
    }

    // MARK: - Derived

    private func burnDetail(_ burn: BurnEstimate) -> String {
        guard let eta = burn.etaToLimit else { return "" }
        let reset = store.snapshot?.primary?.timeUntilReset(now: now)
        if let reset, eta < reset {
            return "· hits limit in ~\(Formatting.countdown(eta))"
        }
        return "· won't max out before reset"
    }

    private var sparklineValues: [Double] {
        guard let resetsAt = store.snapshot?.fiveHour?.resetsAt else { return [] }
        return store.history
            .filter { $0.sessionResetsAt == resetsAt }
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.sessionUtilization)
    }

    private var maxedThisWeek: Int {
        UsageStats.maxedWindows(samples: store.history, since: now.addingTimeInterval(-7 * 24 * 3600))
    }

    // MARK: - Signed out / login

    @ViewBuilder private var loginContent: some View {
        switch auth.state {
        case .signedOut:
            VStack(alignment: .leading, spacing: scale.pt(10)) {
                Text("Connect your Claude account to see your usage and reset times.")
                    .font(scale.font(12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = auth.errorMessage {
                    Text(error).font(scale.font(10)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Connect Claude account") { auth.beginLogin() }
                    .keyboardShortcut(.defaultAction)
                Button("Paste code manually") { auth.beginManualLogin() }
                    .buttonStyle(.link).font(scale.font(10))
                quitRow
            }

        case .waitingForBrowser:
            VStack(alignment: .leading, spacing: scale.pt(10)) {
                HStack(spacing: scale.pt(8)) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval in your browser…")
                        .font(scale.font(12)).foregroundColor(.secondary)
                }
                Text("Approve access in the browser tab that opened. This window updates on its own.")
                    .font(scale.font(10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Button("Cancel") { auth.cancel() }.font(scale.font(11)); Spacer() }
            }

        case .awaitingCode, .connecting:
            VStack(alignment: .leading, spacing: scale.pt(8)) {
                Text("Approve access in the browser, copy the code shown, and paste it here:")
                    .font(scale.font(11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Paste authorization code", text: $auth.pastedCode)
                    .textFieldStyle(.roundedBorder).font(scale.font(11))
                    .disabled(auth.state == .connecting)
                    .onSubmit { auth.submitCode() }
                if let error = auth.errorMessage {
                    Text(error).font(scale.font(10)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { auth.cancel() }.font(scale.font(11))
                    Spacer()
                    if auth.state == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign in") { auth.submitCode() }
                            .font(scale.font(11)).keyboardShortcut(.defaultAction)
                    }
                }
            }

        case .signedIn:
            EmptyView()
        }
    }

    private var quitRow: some View {
        HStack { Spacer(); Button("Quit") { NSApplication.shared.terminate(nil) }.font(scale.font(11)) }
    }
}
