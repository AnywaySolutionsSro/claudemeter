import ClaudeMeterCore
import SwiftUI

/// A release's notes as a compact bullet list (emoji render natively; no web
/// view). `ReleaseNotes.parse` has already stripped GitHub's boilerplate.
/// Shows a gentle placeholder when a release has no notes at all.
struct ReleaseNotesView: View {
    let notes: ReleaseNotes
    var emptyText = "No notes for this version."
    @Environment(\.textScale) private var scale

    init(body: String?, emptyText: String = "No notes for this version.") {
        self.notes = ReleaseNotes.parse(body)
        self.emptyText = emptyText
    }

    var body: some View {
        if notes.isEmpty {
            Text(emptyText).font(scale.font(10)).foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: scale.pt(4)) {
                ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                    if let title = section.title, notes.sections.count > 1 {
                        Text(title).font(scale.font(10, weight: .semibold)).foregroundColor(.secondary)
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        Text(item).font(scale.font(11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// "What's new in 01.04.00" / "You're on 01.03.00" — a disclosure around one
/// release's notes, used in the update banner and in Settings.
struct ReleaseNotesDisclosure: View {
    let title: String
    let release: ReleaseInfo?
    @State var isExpanded: Bool
    @Environment(\.textScale) private var scale

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ReleaseNotesView(body: release?.notes)
                .padding(.top, scale.pt(4))
        } label: {
            Text(title).font(scale.font(11, weight: .medium))
        }
    }
}
