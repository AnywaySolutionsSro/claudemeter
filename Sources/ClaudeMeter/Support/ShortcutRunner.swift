import Foundation

/// Runs a user-named macOS Shortcut (Shortcuts.app) via the `shortcuts` CLI — e.g. to flip on
/// a Focus mode when the session budget runs low.
enum ShortcutRunner {
    static func run(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", trimmed]
        try? process.run()
    }
}
