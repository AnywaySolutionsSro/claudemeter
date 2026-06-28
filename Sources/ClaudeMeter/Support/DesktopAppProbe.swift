import AppKit
import ClaudeMeterCore

/// `DesktopAppDetecting` backed by `NSWorkspace`: reports whether the Claude
/// desktop app is currently running, used to decide if desktop agent sessions
/// can still be live.
struct DesktopAppProbe: DesktopAppDetecting {
    /// Bundle identifier of the Claude desktop app (verified via its Info.plist).
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    func isClaudeDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.claudeDesktopBundleID
        }
    }
}
