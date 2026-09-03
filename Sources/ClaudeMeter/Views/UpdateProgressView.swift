import ClaudeMeterCore
import SwiftUI

/// The download bar for a release being staged — one view for the dropdown banner
/// and the Settings row, so both places show the same thing.
struct UpdateProgressView: View {
    let release: ReleaseInfo
    /// 0...1, or negative when the size is unknown.
    let progress: Double
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.pt(4)) {
            Text("Downloading ClaudeMeter \(release.version.description)…").font(scale.font(11, weight: .semibold))
            if progress >= 0 {
                ProgressView(value: progress).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(progress >= 1 ? "Verifying…" : "You'll be asked before ClaudeMeter restarts.")
                .font(scale.font(10)).foregroundStyle(.secondary)
        }
    }
}

/// The three ways to answer "the update is ready": now, in two hours, or at the
/// next restart. Shared by the banner and Settings.
struct UpdateReadyActions: View {
    @ObservedObject var updates: UpdateService
    @Environment(\.textScale) private var scale

    var body: some View {
        HStack(spacing: scale.pt(8)) {
            Button("Restart now") { updates.install() }
                .font(scale.font(11)).keyboardShortcut(.defaultAction)
            Button("Remind me in 2 hours") { updates.remindLater() }.font(scale.font(11))
            Button("Install on next restart") { updates.installOnNextRestart() }.font(scale.font(11))
        }
    }
}
