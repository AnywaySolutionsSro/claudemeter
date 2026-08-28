@testable import ClaudeMeterCore
import Foundation
import Testing

struct RunningResolverTests {
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
        let out = RunningResolver().resolve(
            sessions: sessions,
            liveCwdCounts: ["/p": 1],
            desktopAppRunning: false,
            now: now,
        )
        #expect(out.first { $0.id == "new" }?.running == .running)
        #expect(out.first { $0.id == "old" }?.running == .idle)
    }

    @Test func cliTwoLiveProcessesMarkTwoNewest() {
        let sessions = [
            session("a", .cli, path: "/p", last: 100),
            session("b", .cli, path: "/p", last: 800),
            session("c", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(
            sessions: sessions,
            liveCwdCounts: ["/p": 2],
            desktopAppRunning: false,
            now: now,
        )
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
        let stale = session("e", .desktop, path: "/p", last: now.timeIntervalSince1970 - 600)
        let out = RunningResolver(desktopRecency: 300).resolve(
            sessions: [recent, stale], liveCwdCounts: [:], desktopAppRunning: true, now: now,
        )
        #expect(out.first { $0.id == "d" }?.running == .running)
        #expect(out.first { $0.id == "e" }?.running == .idle)
    }

    @Test func desktopIdleWhenAppNotRunning() {
        let recent = session("d", .desktop, path: "/p", last: now.timeIntervalSince1970 - 60)
        let out = RunningResolver().resolve(sessions: [recent], liveCwdCounts: [:], desktopAppRunning: false, now: now)
        #expect(out[0].running == .idle)
    }

    // File mtime is a better liveness signal than the last *assistant* record:
    // it also moves on user messages/attachments, so a live-but-quiet session
    // (user reading or typing for 20 min) outranks one that finished recently.
    @Test func cliRanksByFileMtimeOverAssistantActivity() {
        let quietButLive = session("quiet", .cli, path: "/p", last: 100) // old assistant activity
        let recentlyDead = session("dead", .cli, path: "/p", last: 900)
        let out = RunningResolver().resolve(
            sessions: [quietButLive, recentlyDead],
            liveCwdCounts: ["/p": 1],
            desktopAppRunning: false,
            activityAt: ["quiet": Date(timeIntervalSince1970: 9_999),
                         "dead": Date(timeIntervalSince1970: 5_000)],
            now: now,
        )
        #expect(out.first { $0.id == "quiet" }?.running == .running)
        #expect(out.first { $0.id == "dead" }?.running == .idle)
    }

    @Test func desktopRecencyUsesFileMtimeWhenAvailable() {
        let quiet = session("d", .desktop, path: "/p", last: now.timeIntervalSince1970 - 600)
        let out = RunningResolver(desktopRecency: 300).resolve(
            sessions: [quiet], liveCwdCounts: [:], desktopAppRunning: true,
            activityAt: ["d": now.addingTimeInterval(-60)], now: now,
        )
        #expect(out[0].running == .running)
    }

    @Test func preservesInputOrder() {
        let sessions = [
            session("a", .cli, path: "/p", last: 100),
            session("b", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(
            sessions: sessions,
            liveCwdCounts: ["/p": 1],
            desktopAppRunning: false,
            now: now,
        )
        #expect(out.map(\.id) == ["a", "b"])
    }
}
