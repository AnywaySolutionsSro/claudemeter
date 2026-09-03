import ClaudeMeterCore
import SwiftUI

/// The update strip in the dropdown: a download in progress, a verified update
/// waiting for "restart now / later", a download-only offer, or a failure. Renders
/// nothing while the updater has nothing to say (or the prompt is snoozed or
/// deferred to the next restart), so callers can drop it in unconditionally.
struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateService
    @Environment(\.textScale) private var scale
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch updates.state {
        case let .available(release):
            box(tint: .blue) {
                title("ClaudeMeter \(release.version) is available")
                // Both sides of the decision: what the update brings, and what
                // the running version already has.
                ReleaseNotesDisclosure(
                    title: "What's new in \(release.version)", release: release, isExpanded: true,
                )
                if let current = updates.currentVersion {
                    ReleaseNotesDisclosure(
                        title: "You're on \(current)", release: updates.currentRelease, isExpanded: false,
                    )
                }
                HStack(spacing: scale.pt(8)) {
                    Button(installLabel) { updates.install() }
                        .font(scale.font(11)).keyboardShortcut(.defaultAction)
                    Button("Later") { updates.dismiss() }.font(scale.font(11))
                    Button("Skip this version") { updates.skipOffered() }.font(scale.font(11))
                    Spacer()
                    Button("Release notes") { openURL(release.pageURL) }
                        .buttonStyle(.link).font(scale.font(10))
                }
            }
        case let .downloading(release, progress):
            box(tint: .blue) { UpdateProgressView(release: release, progress: progress) }
        case let .ready(release):
            if updates.promptVisible {
                box(tint: .blue) {
                    title("ClaudeMeter \(release.version) is ready to install")
                    ReleaseNotesDisclosure(
                        title: "What's new in \(release.version)", release: release, isExpanded: true,
                    )
                    if let current = updates.currentVersion {
                        ReleaseNotesDisclosure(
                            title: "You're on \(current)", release: updates.currentRelease, isExpanded: false,
                        )
                    }
                    UpdateReadyActions(updates: updates)
                }
            }
        case let .installing(release):
            box(tint: .blue) {
                title("Installing ClaudeMeter \(release.version)…")
                Text("ClaudeMeter relaunches by itself in a moment.")
                    .font(scale.font(10)).foregroundColor(.secondary)
            }
        case let .failed(release?, message):
            box(tint: .red) {
                title("Update to \(release.version) failed")
                Text(message).font(scale.font(10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: scale.pt(8)) {
                    Button("Try again") { updates.install() }.font(scale.font(11))
                    Button("Download manually") { openURL(release.pageURL) }
                        .buttonStyle(.link).font(scale.font(10))
                    Spacer()
                    Button("Dismiss") { updates.dismiss() }.font(scale.font(11))
                }
            }
        case .idle, .checking, .upToDate, .failed(nil, _):
            if updates.justUpdated, let current = updates.currentVersion {
                box(tint: .green) {
                    Label("Updated to ClaudeMeter \(current.description)", systemImage: "checkmark.circle.fill")
                        .font(scale.font(12, weight: .semibold))
                    ReleaseNotesView(body: updates.currentRelease?.notes, emptyText: "Loading what's new…")
                    HStack {
                        Spacer()
                        Button("Got it") { updates.acknowledgeUpdate() }.font(scale.font(11))
                    }
                }
            }
        }
    }

    private var installLabel: String {
        if case .downloadOnly = updates.installMode { return "Download" }
        return "Download and restart"
    }

    private func title(_ text: String) -> some View {
        Label(text, systemImage: "arrow.down.circle.fill")
            .font(scale.font(12, weight: .semibold))
    }

    private func box(tint: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: scale.pt(6), content: content)
            .padding(scale.pt(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: scale.pt(8)).fill(tint.opacity(0.12)))
    }
}
