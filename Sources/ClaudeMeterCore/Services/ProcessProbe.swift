import Darwin
import Foundation

/// Probes the live process table to flag which `claude` CLI sessions are still
/// running. It enumerates every PID via libproc, keeps the ones whose executable
/// is a Claude Code CLI binary, reads each one's current working directory, and
/// collects the pid, cwd, controlling tty, and parent pid into `LiveProcess`
/// values. The resulting array lets callers tally cwds and match sessions to
/// their iTerm2 tabs without shelling out to `lsof`/`ps`.
public protocol ProcessProbing: Sendable {
    /// Every live Claude Code CLI process with its pid, cwd, controlling tty, and parent pid.
    func liveClaudeProcesses() -> [LiveProcess]
}

public extension ProcessProbing {
    /// Working-directory path -> count of live `claude` processes whose cwd is that path.
    func liveClaudeCwdCounts() -> [String: Int] {
        LibprocProcessProbe.tally(processes: liveClaudeProcesses())
    }
}

/// `ProcessProbing` backed by libproc (`proc_listpids`, `proc_pidpath`,
/// `proc_pidinfo`). Never crashes on lookup failures — a pid whose path or cwd
/// cannot be read is simply skipped.
///
/// Matching is by **executable path**, not process name: the Claude Code CLI runs
/// versioned binaries installed at `~/.local/share/claude/versions/<version>`, so
/// the process "name" is the version string (e.g. `2.1.195`), not `claude`.
public struct LibprocProcessProbe: ProcessProbing {
    public init() {}

    public func liveClaudeProcesses() -> [LiveProcess] {
        var result: [LiveProcess] = []
        for pid in Self.allPids() {
            guard let path = Self.executablePath(pid), Self.isClaudeCodeExecutable(path),
                  let cwd = Self.currentWorkingDirectory(pid) else { continue }
            result.append(LiveProcess(
                pid: pid, cwd: cwd,
                tty: Self.controllingTTY(pid),
                ppid: Self.parentPID(pid)
            ))
        }
        return result
    }

    /// Pure, separately-testable tally helper. Returns `[cwd: count]`.
    public static func tally(processes: [LiveProcess]) -> [String: Int] {
        processes.reduce(into: [String: Int]()) { counts, p in
            counts[p.cwd, default: 0] += 1
        }
    }

    /// Whether an executable path belongs to a Claude Code CLI process.
    ///
    /// Matches the standard installer layout (`…/claude/versions/…`) and the
    /// npm/desktop-bundled layout (`…/claude-code/…`), while explicitly excluding
    /// this very app (`ClaudeMeter`), whose name also contains "claude".
    public static func isClaudeCodeExecutable(_ path: String) -> Bool {
        guard !path.contains("ClaudeMeter") else { return false }
        return path.contains("/claude/versions/") || path.contains("/claude-code/")
    }

    // MARK: - Public static wrappers for later tasks

    /// The full executable path for `pid`, or `nil` if it cannot be read.
    public static func executablePathForPID(_ pid: Int32) -> String? {
        executablePath(pid)
    }

    /// Parent PID for `pid`; returns 0 if unreadable.
    public static func parentPIDForPID(_ pid: Int32) -> Int32 {
        parentPID(pid)
    }

    // MARK: - Private helpers

    /// Enumerates all PIDs in the system, sizing the buffer up front.
    private static func allPids() -> [pid_t] {
        let sizeBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizeBytes > 0 else { return [] }

        let capacity = Int(sizeBytes) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let writtenBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard writtenBytes > 0 else { return [] }

        let count = Int(writtenBytes) / MemoryLayout<pid_t>.stride
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// The full executable path for `pid`, or `nil` if it cannot be read.
    private static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let code = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard code > 0 else { return nil }
        return String(cString: buf)
    }

    /// The current working directory for `pid`, or `nil` if it cannot be read.
    private static func currentWorkingDirectory(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let code = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &vpi,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard code > 0 else { return nil }

        let cwd = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return cwd.isEmpty ? nil : cwd
    }

    /// Parent PID via `PROC_PIDTBSDINFO` -> `pbi_ppid`; 0 if unreadable.
    private static func parentPID(_ pid: pid_t) -> Int32 {
        var info = proc_bsdinfo()
        let code = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        guard code > 0 else { return 0 }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// Controlling tty device path (e.g. `/dev/ttys003`) via `PROC_PIDTBSDINFO`
    /// `e_tdev` -> `devname`, or `nil` if the process has no controlling tty.
    private static func controllingTTY(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let code = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        guard code > 0 else { return nil }
        let dev = info.e_tdev
        guard dev != UInt32.max, dev != 0 else { return nil }
        guard let cName = devname(dev_t(dev), S_IFCHR) else { return nil }
        let name = String(cString: cName)
        return name.isEmpty ? nil : "/dev/\(name)"
    }
}
