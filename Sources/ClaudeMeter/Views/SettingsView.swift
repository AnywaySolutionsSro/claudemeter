import SwiftUI
import ClaudeMeterCore

/// The dedicated Settings window content. Split into native macOS preference
/// tabs so each pane fits without scrolling.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var auth: AuthModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            autoResumeTab
                .tabItem { Label("Auto-Resume", systemImage: "bolt.fill") }
        }
        .frame(width: 460, height: 400)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(header: sectionHeader("Appearance", "paintbrush.fill", .pink)) {
                Picker("Menu-bar style", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
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

            Section {
                Label("Toggle the usage window anytime with ⌥⌘U.", systemImage: "command")
                    .font(.caption).foregroundStyle(.secondary)
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
                .onChange(of: settings.notificationsEnabled) { enabled in
                    if enabled { NotificationManager().requestAuthorization() }
                }
            }

            Section(header: sectionHeader("Low-usage Shortcut", "bolt.badge.clock", .yellow)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run a Shortcut when usage drops to ≤10%.")
                        .font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Continue text") {
                    TextField("continue", text: $settings.autoResumeContinueText)
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                }
                Text("On by default — a global pause, not the arming control. Arm individual sessions in the Sessions window; only iTerm2 tabs cut off by the usage limit are nudged on quota refresh.")
                    .font(.caption).foregroundStyle(.secondary)
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
                        Text(status.text).font(.caption.weight(.semibold))
                            .foregroundStyle(status.color)
                    }
                }
                Text("Grants macOS Automation permission now (iTerm2 must be running) so the first resume can fire unattended.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .font(.system(size: 12, weight: .semibold))
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
    }

    private func authorizeITerm() {
        switch ITermDriver().authorize() {
        case .granted:
            authStatus = AuthStatus(text: "Authorized ✓", color: .green)
        case .notRunning:
            authStatus = AuthStatus(text: "Start iTerm2 first", color: .orange)
        case .denied(let message):
            authStatus = AuthStatus(text: "Denied — \(message)", color: .red)
        }
    }
}
