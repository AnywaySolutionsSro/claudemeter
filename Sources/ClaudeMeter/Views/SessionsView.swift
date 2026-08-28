import ClaudeMeterCore
import SwiftUI

/// The Live Sessions window content: a header summarising running count and total
/// tokens, then a scrollable list of sessions ranked by total tokens.
struct SessionsView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var armed: ArmedSessions
    @ObservedObject var settings: Settings
    /// Fires the real resume pipeline for one session right now (debug/test).
    var onTestResume: (SessionUsage) -> Void = { _ in }
    @State private var now = Date()
    @AppStorage("sessionsActiveOnly") private var activeOnly = false

    /// Read from `settings` rather than the environment, since this view sets the
    /// environment value for its children. Observing `settings` is what makes an
    /// already-open window react to a scale change: the hosting controller is
    /// created once and cached, so a value captured at construction would go stale.
    private var scale: TextScale { settings.textScale }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Sessions to display, optionally filtered to currently-running ones.
    private var visibleSessions: [SessionUsage] {
        activeOnly ? monitor.sessions.filter { $0.running == .running } : monitor.sessions
    }

    private var terminalKinds: [String: TerminalKind] {
        let detector = TerminalDetector()
        let index = SessionProcessIndex(processes: monitor.latestProcesses)
        var map: [String: TerminalKind] = [:]
        for session in monitor.sessions {
            map[session.id] = index.terminalKind(
                forCwd: session.projectPath, detector: detector,
                paths: { LibprocProcessProbe.executablePathForPID($0) },
                parents: { LibprocProcessProbe.parentPIDForPID($0) },
            )
        }
        return map
    }

    /// Why a session can't be armed (nil = armable). Matches the scanner's
    /// armable gating exactly; the text is what the disabled toggle's tooltip shows.
    private func armDisabledReason(_ session: SessionUsage, kind: TerminalKind) -> String? {
        guard session.running == .running else { return "Only live sessions can be armed" }
        let index = SessionProcessIndex(processes: monitor.latestProcesses)
        switch index.matchCount(forCwd: session.projectPath) {
        case 0: return "No live Claude Code process found for this folder"
        case 1: break
        case let n: return "\(n) Claude tabs share this folder — can't safely target one"
        }
        guard kind.isDrivable else { return "Supports iTerm2 only for now (\(kind.displayName))" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: scale.pt(380), minHeight: scale.pt(420))
        .environment(\.textScale, scale)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: scale.pt(8)) {
            Image(systemName: "list.bullet.rectangle").font(scale.font(13))
            VStack(alignment: .leading, spacing: scale.pt(1)) {
                Text("Claude Sessions").font(scale.font(13, weight: .bold))
                Text(summary).font(scale.font(10)).foregroundColor(.secondary)
            }
            Spacer()
            if !armed.isEmpty {
                HStack(spacing: scale.pt(3)) {
                    Image(systemName: "bolt.fill").font(scale.font(10))
                    Text("\(armed.count) armed").font(scale.font(11, weight: .semibold))
                }
                .padding(.horizontal, scale.pt(7)).padding(.vertical, scale.pt(3))
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
            }
            Toggle("Active only", isOn: $activeOnly)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(scale.font(10))
                .help("Show only sessions that are currently running")
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(scale.font(13))
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(scale.pt(12))
    }

    @ViewBuilder private var content: some View {
        if visibleSessions.isEmpty {
            VStack(spacing: scale.pt(6)) {
                Spacer()
                Image(systemName: "moon.zzz").font(scale.font(24)).foregroundColor(.secondary)
                Text(activeOnly ? "No active sessions" : "No sessions found")
                    .font(scale.font(12)).foregroundColor(.secondary)
                Text(activeOnly
                    ? "Running Claude Code sessions show up here live."
                    : "Start a Claude Code session and it will appear here.")
                    .font(scale.font(10)).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleSessions) { session in
                        let kind = terminalKinds[session.id] ?? .unknown
                        SessionRow(
                            session: session, now: now,
                            terminalKind: kind,
                            armDisabledReason: armDisabledReason(session, kind: kind),
                            isArmed: armed.isArmed(session.id),
                            onArmChange: { armed.setArmed(session.id, $0) },
                        )
                        .padding(.horizontal, scale.pt(12))
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Send “continue” now (test resume)") {
                                onTestResume(session)
                            }
                            .disabled(session.running != .running)
                        }
                        Divider().padding(.leading, scale.pt(30))
                    }
                }
                .padding(.vertical, scale.pt(4))
            }
        }
    }

    private var summary: String {
        let running = monitor.sessions.filter { $0.running == .running }.count
        let shownTotal = visibleSessions.reduce(0) { $0 + $1.totalTokens }
        let updated = monitor.lastUpdated.map { " · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "\(running) running · \(Formatting.tokenCount(shownTotal)) tokens\(updated)"
    }
}
