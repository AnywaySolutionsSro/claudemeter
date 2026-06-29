import Foundation

/// What the driver needs to type `continue` into the right tab.
struct ResumeTarget: Equatable {
    let sessionID: String
    /// Controlling tty device path, e.g. "/dev/ttys003".
    let tty: String
    /// Text to send (default "continue"); the driver appends a newline.
    let continueText: String
    /// PID of the claude process that owned this tty at decision time (tty-reuse defense).
    let expectedPID: Int32
    /// Working directory of the claude process at decision time (tty-reuse defense).
    let expectedCwd: String
}

enum ResumeError: Error, Equatable {
    case missingTTY
    case terminalNotRunning
    case sessionNotFound
    case scriptFailed(String)
}

/// Types the continue text into a session's live terminal tab. Mockable.
protocol TerminalResumeDriver {
    func resume(_ target: ResumeTarget) throws
}
