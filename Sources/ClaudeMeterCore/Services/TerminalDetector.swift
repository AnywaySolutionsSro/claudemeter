import Foundation

/// Walks a process's parent-PID chain to the owning terminal emulator, matching
/// each ancestor's executable path against known terminal bundles. Pure: the
/// PID→path and PID→parent lookups are injected so it can be unit-tested over a
/// synthetic process tree.
public struct TerminalDetector: Sendable {
    public init() {}

    private static let maxDepth = 12

    public func detect(
        startPID: Int32,
        executablePathForPID: (Int32) -> String?,
        parentPIDForPID: (Int32) -> Int32,
    ) -> TerminalKind {
        var pid = startPID
        var depth = 0
        while pid > 1, depth < Self.maxDepth {
            if let path = executablePathForPID(pid), let kind = Self.match(path) {
                return kind
            }
            pid = parentPIDForPID(pid)
            depth += 1
        }
        return .unknown
    }

    /// Match an executable path to a terminal kind, or `nil` if it isn't a terminal.
    static func match(_ path: String) -> TerminalKind? {
        if path.contains("/iTerm.app/") || path.hasSuffix("/iTerm2") { return .iTerm2 }
        if path.contains("/Terminal.app/") { return .appleTerminal }
        if path.contains("/Ghostty.app/") { return .ghostty }
        if path.contains("/WezTerm.app/") || path.contains("wezterm") { return .wezterm }
        if path.contains("/Warp.app/") { return .warp }
        if path.contains("/Code.app/") || path.contains("Visual Studio Code") { return .vscode }
        return nil
    }
}
