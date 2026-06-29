import Foundation

/// One live Claude Code CLI process as seen by the process probe.
///
/// `tty` is the controlling terminal device path (e.g. `/dev/ttys003`) used to
/// match the session to its iTerm2 tab; `ppid` is the parent PID used to walk up
/// to the owning terminal application.
public struct LiveProcess: Equatable, Sendable {
    public let pid: Int32
    public let cwd: String
    public let tty: String?
    public let ppid: Int32

    public init(pid: Int32, cwd: String, tty: String?, ppid: Int32) {
        self.pid = pid
        self.cwd = cwd
        self.tty = tty
        self.ppid = ppid
    }
}
