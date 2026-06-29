import SwiftUI
import ClaudeMeterCore

/// The dedicated Settings window content. Hosts every preference that used to
/// live inline in the popover, grouped into sections.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var auth: AuthModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Menu-bar style", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("General") {
                Toggle("Start at login", isOn: launchAtLoginBinding)
            }

            Section("Notifications") {
                Toggle("Usage notifications", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { enabled in
                        if enabled { NotificationManager().requestAuthorization() }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run Shortcut when low (≤10%)")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("Shortcut name", text: $settings.lowUsageShortcut)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Overnight Auto-Resume") {
                Toggle("Auto-resume armed sessions on quota refresh", isOn: $settings.autoResumeEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue text").font(.caption).foregroundStyle(.secondary)
                    TextField("continue", text: $settings.autoResumeContinueText)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Arms are chosen per session in the Sessions window. Only iTerm2 sessions that were cut off by the usage limit are nudged. Controlling iTerm2 requires Automation permission (System Settings → Privacy & Security → Automation).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Account") {
                if auth.isSignedIn {
                    HStack {
                        Label("Connected", systemImage: "checkmark.seal")
                        Spacer()
                        Button("Sign out") { auth.signOut() }
                    }
                } else {
                    Button("Connect Claude account") { auth.beginLogin() }
                }
            }

            Section {
                Text("Toggle the usage window anytime with ⌥⌘U.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 560)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })
    }
}
