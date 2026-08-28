import ClaudeMeterCore
import Foundation

/// Correlates a session (identified by its project cwd) to the single live
/// claude process in that directory. If two or more claude processes share a
/// cwd, the match is ambiguous and we return `nil` rather than risk typing into
/// the wrong tab.
struct SessionProcessIndex {
    private let byCwd: [String: [LiveProcess]]

    init(processes: [LiveProcess]) {
        self.byCwd = Dictionary(grouping: processes, by: { $0.cwd })
    }

    func process(forCwd cwd: String) -> LiveProcess? {
        guard let matches = byCwd[cwd], matches.count == 1 else { return nil }
        return matches[0]
    }

    /// How many live claude processes share this cwd (0 = none, 2+ = ambiguous).
    func matchCount(forCwd cwd: String) -> Int {
        byCwd[cwd]?.count ?? 0
    }

    func terminalKind(
        forCwd cwd: String,
        detector: TerminalDetector,
        paths: @escaping (Int32) -> String?,
        parents: @escaping (Int32) -> Int32,
    ) -> TerminalKind {
        guard let proc = process(forCwd: cwd) else { return .unknown }
        return detector.detect(startPID: proc.pid, executablePathForPID: paths, parentPIDForPID: parents)
    }
}
