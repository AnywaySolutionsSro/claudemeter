import ClaudeMeterCore
import SwiftUI

/// The "a new version is available" strip in the dropdown. Renders nothing while
/// the updater has nothing to offer, so callers can drop it in unconditionally.
struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateService
    @Environment(\.textScale) private var scale
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch updates.state {
        case let .available(release):
            box(tint: .blue) {
                title("ClaudeMeter \(release.version) is available")
                HStack(spacing: scale.pt(8)) {
                    Button(installLabel) { updates.install() }
                        .font(scale.font(11)).keyboardShortcut(.defaultAction)
                    Button("Later") { updates.dismiss() }.font(scale.font(11))
                    Spacer()
                    Button("Release notes") { openURL(release.pageURL) }
                        .buttonStyle(.link).font(scale.font(10))
                }
            }
        case let .downloading(release, progress):
            box(tint: .blue) {
                title("Downloading ClaudeMeter \(release.version)…")
                if progress >= 0 {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
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
                    Button("Dismiss") { updates.skipOffered() }.font(scale.font(11))
                }
            }
        case .idle, .checking, .upToDate, .failed(nil, _):
            EmptyView()
        }
    }

    private var installLabel: String {
        if case .downloadOnly = updates.installMode { return "Download" }
        return "Install and relaunch"
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
