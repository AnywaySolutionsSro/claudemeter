import Foundation

/// Release notes as the app shows them: `##` headings become sections, `-`/`*`
/// lines become items. Understands both the body `release.yml` writes (emoji
/// sections + bullets from the PRs' "Release notes") and GitHub's auto-generated
/// "What's Changed" shape (older releases): the `by @user in <url>` suffix is
/// folded to `(#N)`, and the "New Contributors" / "Full Changelog" boilerplate is
/// dropped. Prose that isn't a bullet is ignored — the notes are a list, not an essay.
public struct ReleaseNotes: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let title: String?
        public let items: [String]

        public init(title: String?, items: [String]) {
            self.title = title
            self.items = items
        }
    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public var isEmpty: Bool { sections.isEmpty }
    public var allItems: [String] { sections.flatMap(\.items) }

    private static let droppedSections: Set<String> = ["new contributors"]

    public static func parse(_ body: String?) -> ReleaseNotes {
        guard let body else { return ReleaseNotes(sections: []) }
        var sections: [Section] = []
        var title: String?
        var items: [String] = []
        var skipping = false

        func flush() {
            if !items.isEmpty { sections.append(Section(title: title, items: items)) }
            items = []
        }

        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: true,
        ) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                flush()
                title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                skipping = droppedSections.contains(title?.lowercased() ?? "")
            } else if !skipping, line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = normalize(String(line.dropFirst(2)))
                if !item.isEmpty { items.append(item) }
            }
        }
        flush()
        return ReleaseNotes(sections: sections)
    }

    /// `text by @user in https://…/pull/13` → `text (#13)`; collapses inner whitespace.
    private static func normalize(_ item: String) -> String {
        var text = item.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: " by @", options: .backwards) {
            let suffix = text[range.upperBound...]
            let number = suffix.split(separator: "/").last.flatMap { Int($0) }
            text = String(text[..<range.lowerBound])
            if let number { text += " (#\(number))" }
        }
        return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
