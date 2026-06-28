import SwiftUI
import ClaudeMeterCore

/// The Live Sessions window content: a header summarising running count and total
/// tokens, then a scrollable list of sessions ranked by total tokens.
struct SessionsView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var now = Date()
    @AppStorage("sessionsActiveOnly") private var activeOnly = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Sessions to display, optionally filtered to currently-running ones.
    private var visibleSessions: [SessionUsage] {
        activeOnly ? monitor.sessions.filter { $0.running == .running } : monitor.sessions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 380, minHeight: 420)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Sessions").font(.system(size: 13, weight: .bold))
                Text(summary).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("Active only", isOn: $activeOnly)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10))
                .help("Show only sessions that are currently running")
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if visibleSessions.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "moon.zzz").font(.system(size: 24)).foregroundColor(.secondary)
                Text(activeOnly ? "No active sessions" : "No sessions found")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Text(activeOnly
                     ? "Running Claude Code sessions show up here live."
                     : "Start a Claude Code session and it will appear here.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleSessions) { session in
                        SessionRow(session: session, now: now)
                            .padding(.horizontal, 12)
                        Divider().padding(.leading, 30)
                    }
                }
                .padding(.vertical, 4)
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
