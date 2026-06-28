import SwiftUI
import ClaudeMeterCore

/// The Live Sessions window content: a header summarising running count and total
/// tokens, then a scrollable list of sessions ranked by total tokens.
struct SessionsView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 380, minHeight: 360)
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
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if monitor.sessions.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "moon.zzz").font(.system(size: 24)).foregroundColor(.secondary)
                Text("No sessions found").font(.system(size: 12)).foregroundColor(.secondary)
                Text("Start a Claude Code session and it will appear here.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(monitor.sessions) { session in
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
        let total = monitor.snapshot?.totalTokens ?? monitor.sessions.reduce(0) { $0 + $1.totalTokens }
        let updated = monitor.lastUpdated.map { " · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "\(running) running · \(Formatting.tokenCount(total)) tokens\(updated)"
    }
}
