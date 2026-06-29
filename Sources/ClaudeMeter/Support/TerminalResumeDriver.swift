import Foundation

/// What the driver needs to type `continue` into the right tab.
struct ResumeTarget: Equatable {
    let sessionID: String
    /// Controlling tty device path, e.g. "/dev/ttys003".
    let tty: String
    /// Text to send (default "continue"); the driver appends a newline.
    let continueText: String
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
