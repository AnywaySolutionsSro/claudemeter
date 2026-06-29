import Foundation
import os

/// Drives iTerm2 via AppleScript: locate the session whose `tty` matches the
/// target and `write text` the continue string into exactly that session. Never
/// activates iTerm2 or steals focus. Throws if iTerm2 isn't running or no
/// session has the tty (the coordinator turns that into a skip + notification).
struct ITermDriver: TerminalResumeDriver {
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "iterm")

    func resume(_ target: ResumeTarget) throws {
        guard !target.tty.isEmpty else { throw ResumeError.missingTTY }

        // AppleScript: only proceed if iTerm2 is already running; find the
        // session with the matching tty and write the text. Set a boolean we can
        // read back to distinguish "session not found" from success.
        let escapedText = target.continueText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "System Events"
            if not (exists process "iTerm2") then return "NOT_RUNNING"
        end tell
        set foundSession to false
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is "\(target.tty)" then
                            tell s to write text "\(escapedText)"
                            set foundSession to true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        if foundSession then
            return "OK"
        else
            return "NOT_FOUND"
        end if
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ResumeError.scriptFailed("could not compile AppleScript")
        }
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            log.error("iTerm AppleScript error: \(message, privacy: .public)")
            throw ResumeError.scriptFailed(message)
        }
        switch output.stringValue {
        case "OK": return
        case "NOT_RUNNING": throw ResumeError.terminalNotRunning
        default: throw ResumeError.sessionNotFound
        }
    }

    /// Outcome of a one-time Automation (TCC) authorization attempt.
    enum AuthorizationResult: Equatable {
        case granted
        case denied(String)
        case notRunning
    }

    /// Sends a harmless Apple Event to iTerm2 (`get version`) purely to surface the
    /// macOS "ClaudeMeter wants to control iTerm2" prompt on demand. macOS will not
    /// list ClaudeMeter under System Settings → Automation until it has attempted an
    /// Apple Event at least once, so this is the only way to pre-authorize control
    /// before a real quota reset. No text is typed and no focus is stolen.
    func authorize() -> AuthorizationResult {
        let source = """
        tell application "System Events"
            if not (exists process "iTerm2") then return "NOT_RUNNING"
        end tell
        tell application "iTerm2"
            get version
        end tell
        return "OK"
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .denied("could not compile AppleScript")
        }
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            log.error("iTerm authorization error: \(message, privacy: .public)")
            return .denied(message)
        }
        if output.stringValue == "NOT_RUNNING" { return .notRunning }
        log.log("iTerm2 control authorized")
        return .granted
    }
}
