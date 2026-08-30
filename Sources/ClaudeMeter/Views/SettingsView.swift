import ClaudeMeterCore
import SwiftUI

/// The dedicated Settings window content. Split into native macOS preference
/// tabs so each pane fits without scrolling.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var auth: AuthModel
    @ObservedObject var updates: UpdateService
    @ObservedObject var apiSpend: ApiSpendStore

    /// Read from `settings` directly rather than the environment: this view sets
    /// the environment value for its own children, and a value set in `body`
    /// does not apply to the view that sets it.
    private var scale: TextScale { settings.textScale }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            autoResumeTab
                .tabItem { Label("Auto-Resume", systemImage: "bolt.fill") }
        }
        .frame(width: scale.pt(460), height: scale.pt(470))
        .environment(\.textScale, scale)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(header: sectionHeader("Appearance", "paintbrush.fill", .pink)) {
                Picker("Menu-bar style", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Text size", selection: $settings.textScale) {
                    ForEach(TextScale.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: launchAtLoginBinding) {
                    Label("Start at login", systemImage: "power")
                }
            }

            Section(header: sectionHeader("Account", "person.crop.circle.fill", .blue)) {
                if auth.isSignedIn {
                    HStack {
                        Label("Connected", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    }
                } else {
                    Button {
                        auth.beginLogin()
                    } label: {
                        Label("Connect Claude account", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section(header: sectionHeader("Updates", "arrow.down.circle.fill", .teal)) {
                UpdateSettingsSection(settings: settings, updates: updates)
            }

            Section(header: sectionHeader("Claude API spend", "dollarsign.circle.fill", .green)) {
                ApiSettingsSection(spend: apiSpend)
            }

            Section {
                Label("Toggle the usage window anytime with ⌥⌘U.", systemImage: "command")
                    .font(scale.font(10)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Alerts

    private var notificationsTab: some View {
        Form {
            Section(header: sectionHeader("Notifications", "bell.badge.fill", .orange)) {
                Toggle(isOn: $settings.notificationsEnabled) {
                    Label("Usage notifications", systemImage: "bell")
                }
                .onChange(of: settings.notificationsEnabled) { _, enabled in
                    if enabled { NotificationManager().requestAuthorization() }
                }
            }

            Section(header: sectionHeader("Low-usage Shortcut", "bolt.badge.clock", .yellow)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run a Shortcut when usage drops to ≤10%.")
                        .font(scale.font(10)).foregroundStyle(.secondary)
                    TextField("Shortcut name", text: $settings.lowUsageShortcut)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Auto-Resume

    private var autoResumeTab: some View {
        Form {
            Section(header: sectionHeader("Overnight Auto-Resume", "bolt.fill", .orange)) {
                Toggle(isOn: $settings.autoResumeEnabled) {
                    Label("Master switch", systemImage: "power")
                }
                // Enabling the feature is the natural moment to surface the macOS
                // Automation consent — not app launch, not 4am.
                .onChange(of: settings.autoResumeEnabled) { _, enabled in
                    if enabled { authorizeITerm() }
                }
                LabeledContent("Continue text") {
                    TextField("continue", text: $settings.autoResumeContinueText)
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                }
                Text(
                    "Enable this first — it sets up the iTerm2 permission. Then arm individual sessions in the "
                        + "Sessions window; only iTerm2 tabs cut off by the usage limit are nudged on quota refresh.",
                )
                .font(scale.font(10)).foregroundStyle(.secondary)
                Text(
                    "Sleep is handled for you: while any session is armed, ClaudeMeter holds a power assertion that "
                        + "keeps the Mac awake — no Energy settings to change. Just leave the lid open (or run closed "
                        + "with an external display and power connected).",
                )
                .font(scale.font(10)).foregroundStyle(.secondary)
            }

            Section(header: sectionHeader("iTerm2 Permission", "lock.shield.fill", .green)) {
                HStack {
                    Button {
                        authorizeITerm()
                    } label: {
                        Label("Authorize iTerm2 control…", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    if let status = authStatus {
                        Text(status.text).font(scale.font(10, weight: .semibold))
                            .foregroundStyle(status.color)
                    }
                }
                if case let .some(status) = authStatus, status.showsSettingsLink {
                    // A recorded denial can only be undone in System Settings —
                    // deep-link straight to the Automation pane.
                    Button {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!,
                        )
                    } label: {
                        Label("Open Automation settings…", systemImage: "gearshape")
                    }
                }
                Text(
                    "Grants macOS Automation permission now (iTerm2 must be running) "
                        + "so the first resume can fire unattended.",
                )
                .font(scale.font(10)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(scale.font(12, weight: .semibold))
        .textCase(nil)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })
    }

    // MARK: - iTerm2 authorization

    @State private var authStatus: AuthStatus?

    private struct AuthStatus {
        let text: String
        let color: Color
        var showsSettingsLink = false
    }

    private func authorizeITerm() {
        switch ITermDriver().authorize() {
        case .granted:
            authStatus = AuthStatus(text: "Authorized ✓", color: .green)
        case .notRunning:
            authStatus = AuthStatus(text: "Start iTerm2 first", color: .orange)
        case let .denied(message):
            authStatus = AuthStatus(text: "Denied — \(message)", color: .red, showsSettingsLink: true)
        }
    }
}
