import SwiftUI
import AppKit
import ClaudeMeterCore

/// The dropdown shown when the menu-bar item is clicked.
struct MenuContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var settings: Settings
    @State private var now = Date()
    @State private var showSettings = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if auth.isSignedIn {
                usageContent
                Divider()
                signedInFooter
            } else {
                loginContent
            }
        }
        .padding(14)
        .frame(width: 300)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.medium")
            Text("ClaudeMeter").font(.system(size: 13, weight: .bold))
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Signed in

    @ViewBuilder private var usageContent: some View {
        if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.allBuckets, id: \.title) { row in
                    UsageRow(title: row.title, bucket: row.bucket, now: now)
                }
                insights
                cooldownBox
            }
        } else if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Loading usage…").font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var insights: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let burn = store.burnEstimate, burn.isBurning {
                    Text("🔥 Burning \(Int(burn.percentPerHour.rounded()))%/h")
                        .font(.system(size: 11, weight: .medium))
                    if let eta = burn.etaToLimit {
                        Text("· ~\(Formatting.countdown(eta)) to limit")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                } else {
                    Text("💤 Idle — not spending right now")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if let ratio = store.paceRatio, ratio >= 1.2 || ratio <= 0.8 {
                Text(String(format: "%.1f× your usual pace", ratio))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            if sparklineValues.count >= 2 {
                Sparkline(values: sparklineValues)
                    .frame(height: 28)
                    .padding(.top, 2)
            }

            if maxedThisWeek > 0 {
                Text("Maxed \(maxedThisWeek) session window\(maxedThisWeek == 1 ? "" : "s") this week")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var cooldownBox: some View {
        if let bucket = store.snapshot?.primary, bucket.percentRemaining <= 0.5,
           let reset = bucket.timeUntilReset(now: now) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cooling down")
                    .font(.system(size: 12, weight: .semibold))
                Text("Session is empty — resets in \(Formatting.countdown(reset)). Good time for a break.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remind me when it resets") {
                    if let resetAt = bucket.resetsAt { NotificationManager().scheduleResetReminder(at: resetAt) }
                }
                .font(.system(size: 11))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }

    private var signedInFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = store.statusNote {
                Text(note).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Picker("Display", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 11))
                Spacer()
                Button(showSettings ? "Hide settings" : "Settings") { showSettings.toggle() }
                    .font(.system(size: 11))
            }

            if showSettings { settingsSection }

            HStack {
                if let updated = store.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh(force: true) } }
                    .font(.system(size: 11))
            }

            HStack {
                quickLinksMenu
                Spacer()
                Button("Sign out") { auth.signOut() }.font(.system(size: 11))
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(.system(size: 11))
            }
        }
    }

    @ViewBuilder private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Start at login", isOn: launchAtLoginBinding)
                .font(.system(size: 12)).toggleStyle(.checkbox)
            Toggle("Usage notifications", isOn: $settings.notificationsEnabled)
                .font(.system(size: 12)).toggleStyle(.checkbox)
                .onChange(of: settings.notificationsEnabled) { enabled in
                    if enabled { NotificationManager().requestAuthorization() }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Shortcut when low (≤10%)").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Shortcut name", text: $settings.lowUsageShortcut)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            Text("Toggle window: ⌥⌘U").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var quickLinksMenu: some View {
        Menu("⋯") {
            Link("Buy more usage", destination: URL(string: "https://claude.ai/settings/usage")!)
            Link("Upgrade plan", destination: URL(string: "https://claude.ai/settings/billing")!)
            Link("Usage help", destination: URL(string: "https://support.claude.com")!)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .font(.system(size: 11))
    }

    // MARK: - Derived

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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })
    }

    // MARK: - Signed out / login

    @ViewBuilder private var loginContent: some View {
        switch auth.state {
        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect your Claude account to see your usage and reset times.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = auth.errorMessage {
                    Text(error).font(.system(size: 10)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Connect Claude account") { auth.beginLogin() }
                    .keyboardShortcut(.defaultAction)
                Button("Paste code manually") { auth.beginManualLogin() }
                    .buttonStyle(.link).font(.system(size: 10))
                quitRow
            }

        case .waitingForBrowser:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval in your browser…")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Text("Approve access in the browser tab that opened. This window updates on its own.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Button("Cancel") { auth.cancel() }.font(.system(size: 11)); Spacer() }
            }

        case .awaitingCode, .connecting:
            VStack(alignment: .leading, spacing: 8) {
                Text("Approve access in the browser, copy the code shown, and paste it here:")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Paste authorization code", text: $auth.pastedCode)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .disabled(auth.state == .connecting)
                    .onSubmit { auth.submitCode() }
                if let error = auth.errorMessage {
                    Text(error).font(.system(size: 10)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { auth.cancel() }.font(.system(size: 11))
                    Spacer()
                    if auth.state == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign in") { auth.submitCode() }
                            .font(.system(size: 11)).keyboardShortcut(.defaultAction)
                    }
                }
            }

        case .signedIn:
            EmptyView()
        }
    }

    private var quitRow: some View {
        HStack { Spacer(); Button("Quit") { NSApplication.shared.terminate(nil) }.font(.system(size: 11)) }
    }
}
