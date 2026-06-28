/// Abstracts "is the Claude desktop app currently running?" so the scanner can
/// stay pure and testable; the concrete `NSWorkspace`-based implementation lives
/// in the app target.
public protocol DesktopAppDetecting: Sendable {
    func isClaudeDesktopRunning() -> Bool
}
