import ClaudeMeterCore
import SwiftUI

/// The "Updates" group in Settings → General: current version, the daily-check
/// switch, a manual check, and the state of the last check.
struct UpdateSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var updates: UpdateService
    @Environment(\.textScale) private var scale
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent("Version", value: updates.currentVersion?.description ?? "development build")
        Toggle(isOn: $settings.autoUpdateCheckEnabled) {
            Label("Check for updates daily", systemImage: "arrow.triangle.2.circlepath")
        }
        HStack(spacing: scale.pt(10)) {
            Button("Check now") { updates.checkNow() }
                .disabled(updates.state.isBusy)
            statusText
            Spacer()
            actions
        }
        if case let .downloadOnly(reason) = updates.installMode {
            Text("Updates open the download page instead of installing in place: \(reason)")
                .font(scale.font(10)).foregroundStyle(.secondary)
        }
        if let current = updates.currentVersion {
            ReleaseNotesDisclosure(
                title: "What's in \(current)", release: updates.currentRelease, isExpanded: false,
            )
        }
        if let offered = updates.state.offeredRelease {
            ReleaseNotesDisclosure(
                title: "What's new in \(offered.version)", release: offered, isExpanded: true,
            )
        }
    }

    @ViewBuilder private var statusText: some View {
        switch updates.state {
        case .idle:
            if let last = settings.lastUpdateCheck {
                secondary("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
            } else {
                secondary("Not checked yet")
            }
        case .checking:
            HStack(spacing: scale.pt(6)) { ProgressView().controlSize(.small); secondary("Checking…") }
        case let .upToDate(checkedAt):
            secondary("Up to date · \(checkedAt.formatted(date: .omitted, time: .shortened))")
        case let .available(release):
            Text("\(release.version.description) available").font(scale.font(11, weight: .semibold))
                .foregroundStyle(.blue)
        case let .downloading(release, _):
            secondary("Downloading \(release.version)…")
        case let .installing(release):
            secondary("Installing \(release.version)…")
        case let .failed(_, message):
            Text(message).font(scale.font(10)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        if let release = updates.state.offeredRelease, !updates.state.isBusy {
            Button("Skip this version") { updates.skipOffered() }.font(scale.font(11))
            Button(installLabel) { updates.install() }
                .buttonStyle(.borderedProminent).font(scale.font(11))
                .help(release.pageURL.absoluteString)
        }
    }

    private var installLabel: String {
        if case .downloadOnly = updates.installMode { return "Download…" }
        return "Install"
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(scale.font(10)).foregroundStyle(.secondary)
    }
}
