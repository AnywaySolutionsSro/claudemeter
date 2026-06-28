import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct RunningResolverTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func session(_ id: String, _ origin: SessionOrigin, path: String, last: TimeInterval) -> SessionUsage {
        SessionUsage(id: id, origin: origin, projectPath: path, models: ["m"],
                     tokens: TokenBreakdown(input: 1), messageCount: 1,
                     firstActivity: .init(timeIntervalSince1970: 0),
                     lastActivity: .init(timeIntervalSince1970: last), burnRate: 0)
    }

    @Test func cliMarksMostRecentInCwdRunningUpToLiveCount() {
        let sessions = [
            session("old", .cli, path: "/p", last: 100),
            session("new", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: ["/p": 1], desktopAppRunning: false, now: now)
        #expect(out.first { $0.id == "new" }?.running == .running)
        #expect(out.first { $0.id == "old" }?.running == .idle)
    }

    @Test func cliTwoLiveProcessesMarkTwoNewest() {
        let sessions = [
            session("a", .cli, path: "/p", last: 100),
            session("b", .cli, path: "/p", last: 800),
            session("c", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: ["/p": 2], desktopAppRunning: false, now: now)
        #expect(out.first { $0.id == "a" }?.running == .idle)
        #expect(out.first { $0.id == "b" }?.running == .running)
        #expect(out.first { $0.id == "c" }?.running == .running)
    }

    @Test func cliNoLiveProcessAllIdle() {
        let sessions = [session("a", .cli, path: "/p", last: 900)]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: [:], desktopAppRunning: false, now: now)
        #expect(out[0].running == .idle)
    }

    @Test func desktopRunningWhenAppAliveAndRecent() {
        let recent = session("d", .desktop, path: "/p", last: now.timeIntervalSince1970 - 60)
        let stale  = session("e", .desktop, path: "/p", last: now.timeIntervalSince1970 - 600)
        let out = RunningResolver(desktopRecency: 300).resolve(
            sessions: [recent, stale], liveCwdCounts: [:], desktopAppRunning: true, now: now)
        #expect(out.first { $0.id == "d" }?.running == .running)
        #expect(out.first { $0.id == "e" }?.running == .idle)
    }

    @Test func desktopIdleWhenAppNotRunning() {
        let recent = session("d", .desktop, path: "/p", last: now.timeIntervalSince1970 - 60)
        let out = RunningResolver().resolve(sessions: [recent], liveCwdCounts: [:], desktopAppRunning: false, now: now)
        #expect(out[0].running == .idle)
    }

    @Test func preservesInputOrder() {
        let sessions = [
            session("a", .cli, path: "/p", last: 100),
            session("b", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: ["/p": 1], desktopAppRunning: false, now: now)
        #expect(out.map(\.id) == ["a", "b"])
    }
}
