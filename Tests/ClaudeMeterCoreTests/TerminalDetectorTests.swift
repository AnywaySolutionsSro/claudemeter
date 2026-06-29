import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct TerminalDetectorTests {
    private let detector = TerminalDetector()

    /// Build closures over a synthetic process tree: pid -> (path, ppid).
    private func tree(_ nodes: [Int32: (String, Int32)])
        -> (paths: (Int32) -> String?, parents: (Int32) -> Int32) {
        ({ nodes[$0]?.0 }, { nodes[$0]?.1 ?? 0 })
    }

    @Test func findsITermThroughChain() {
        let t = tree([
            100: ("/Users/x/.local/share/claude/versions/2.1/claude", 90),
            90: ("/bin/zsh", 50),
            50: ("/Applications/iTerm.app/Contents/MacOS/iTerm2", 1),
        ])
        #expect(detector.detect(startPID: 100, executablePathForPID: t.paths, parentPIDForPID: t.parents) == .iTerm2)
    }

    @Test func findsAppleTerminal() {
        let t = tree([
            10: ("/claude/versions/x/claude", 9),
            9: ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", 1),
        ])
        #expect(detector.detect(startPID: 10, executablePathForPID: t.paths, parentPIDForPID: t.parents) == .appleTerminal)
    }

    @Test func unknownWhenChainEndsAtLaunchd() {
        let t = tree([5: ("/claude/versions/x/claude", 1)])
        #expect(detector.detect(startPID: 5, executablePathForPID: t.paths, parentPIDForPID: t.parents) == .unknown)
    }

    @Test func iTermIsDrivableOthersAreNot() {
        #expect(TerminalKind.iTerm2.isDrivable)
        #expect(!TerminalKind.appleTerminal.isDrivable)
        #expect(!TerminalKind.unknown.isDrivable)
    }
}
