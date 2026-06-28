import WidgetKit
import SwiftUI
import ClaudeMeterCore

/// Timeline entry carrying the latest published session snapshot (or `nil` when
/// the app hasn't written one yet / the shared container isn't reachable).
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SessionSnapshot?
}

/// Reads the snapshot the main app publishes to the shared App Group container.
struct Provider: TimelineProvider {
    private let store = SnapshotStore()

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = loadEntry()
        // WidgetKit throttles refreshes; ask for one roughly every 5 minutes.
        let next = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> SnapshotEntry {
        guard
            let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: SnapshotStore.appGroupID),
            let snapshot = store.read(from: container.appendingPathComponent("snapshot.json"))
        else {
            return SnapshotEntry(date: Date(), snapshot: nil)
        }
        return SnapshotEntry(date: Date(), snapshot: snapshot)
    }
}

struct ClaudeMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: smallView
            default: mediumView
            }
        }
        .padding(10)
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.medium")
            Text("Claude").font(.system(size: 11, weight: .bold))
            Spacer()
            if let snapshot = entry.snapshot {
                Text("\(snapshot.runningCount) live")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            if let top = entry.snapshot?.sessions.first {
                Text(top.projectName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(Formatting.tokenCount(top.totalTokens))
                    .font(.system(size: 20, weight: .bold)).monospacedDigit()
                Text("top session").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                emptyLabel
            }
        }
    }

    @ViewBuilder private var mediumView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                header
                Spacer()
                if let snapshot = entry.snapshot {
                    Text("\(Formatting.tokenCount(snapshot.totalTokens)) total")
                        .font(.system(size: 10)).foregroundColor(.secondary).monospacedDigit()
                }
            }
            Divider()
            if let sessions = entry.snapshot?.sessions, !sessions.isEmpty {
                ForEach(sessions.prefix(3)) { s in
                    HStack(spacing: 6) {
                        Circle().fill(s.running == .running ? Color.green : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                        Text(s.projectName).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(Formatting.tokenCount(s.totalTokens))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            } else {
                emptyLabel
            }
        }
    }

    private var emptyLabel: some View {
        Text("No sessions yet").font(.system(size: 11)).foregroundColor(.secondary)
    }
}

struct ClaudeMeterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeMeterWidget", provider: Provider()) { entry in
            ClaudeMeterWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Sessions")
        .description("Live token usage across your Claude Code sessions.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClaudeMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeMeterWidget()
    }
}
