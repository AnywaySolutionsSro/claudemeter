import Darwin
import Foundation

/// Probes the live process table to flag which `claude` CLI sessions are still
/// running. It enumerates every PID via libproc, keeps the ones whose short
/// process name is `"claude"`, reads each one's current working directory, and
/// tallies how many live `claude` processes sit in each cwd. The resulting
/// `[cwd: count]` map lets callers mark the N most-recent sessions per project
/// path as live without shelling out to `lsof`/`ps`.
public protocol ProcessProbing: Sendable {
    /// Working-directory path -> count of live `claude` processes whose cwd is that path.
    func liveClaudeCwdCounts() -> [String: Int]
}

/// `ProcessProbing` backed by libproc (`proc_listpids`, `proc_name`,
/// `proc_pidinfo`). Never crashes on lookup failures — a pid that cannot be
/// named or whose cwd cannot be read is simply skipped.
public struct LibprocProcessProbe: ProcessProbing {
    private static let claudeName = "claude"

    public init() {}

    public func liveClaudeCwdCounts() -> [String: Int] {
        Self.tally(cwdsByPid())
    }

    /// Pure, separately-testable tally helper.
    /// Groups the cwd values and counts occurrences: returns `[cwd: count]`.
    public static func tally(_ cwdsByPid: [Int32: String]) -> [String: Int] {
        cwdsByPid.values.reduce(into: [String: Int]()) { counts, cwd in
            counts[cwd, default: 0] += 1
        }
    }

    /// Builds pid -> cwd for every live process named `claude`.
    private func cwdsByPid() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for pid in Self.allPids() where Self.processName(pid) == Self.claudeName {
            if let cwd = Self.currentWorkingDirectory(pid) {
                result[pid] = cwd
            }
        }
        return result
    }

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

    /// The short process name for `pid`, or `nil` if it cannot be read.
    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(2 * MAXPATHLEN))
        let code = proc_name(pid, &buf, UInt32(buf.count))
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
}
