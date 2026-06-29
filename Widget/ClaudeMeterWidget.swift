import WidgetKit
import SwiftUI
import AppIntents
import OSLog
import ClaudeMeterCore

private let widgetLog = Logger(subsystem: "com.jakubzak.claudemeter.widget", category: "snapshot")

/// Timeline entry carrying the latest published session snapshot (or `nil` when
/// the app hasn't written one yet / the shared container isn't reachable).
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SessionSnapshot?

    /// Representative content for the gallery preview / first paint.
    static var sample: SnapshotEntry {
        let now = Date()
        let demo = [("liberspiro", 12_000_000), ("movixtar", 2_700_000), ("mbx", 1_800_000)]
            .map { name, tok in
                SessionUsage(id: name, origin: .cli, projectPath: "/code/\(name)", models: ["claude-opus-4-8"],
                             tokens: TokenBreakdown(input: tok), messageCount: 1,
                             firstActivity: now, lastActivity: now, burnRate: 0, running: .running)
            }
        return SnapshotEntry(date: now, snapshot: SessionSnapshot.make(from: demo, now: now, runningOnly: true))
    }
}

/// Reads the snapshot the main app publishes to the shared App Group container.
struct Provider: TimelineProvider {
    private let store = SnapshotStore()

    func placeholder(in context: Context) -> SnapshotEntry {
        .sample
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
        // Read from our own container Documents, where the app delivers the snapshot.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("snapshot.json")
        let snapshot = store.read(from: url)
        widgetLog.log("loaded \(snapshot?.sessions.count ?? -1) sessions from \(url.path, privacy: .public)")
        return SnapshotEntry(date: Date(), snapshot: snapshot)
    }
}

private let activeGradient = LinearGradient(
    colors: [Color.green, Color(red: 0.2, green: 0.85, blue: 0.6)],
    startPoint: .leading, endPoint: .trailing
)

struct ClaudeMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var sessions: [SessionUsage] { entry.snapshot?.sessions ?? [] }
    private var maxTokens: Int { max(1, sessions.map(\.totalTokens).max() ?? 1) }
    private var armedIDs: Set<String> { Set(entry.snapshot?.armedSessionIDs ?? []) }
    private var armableIDs: Set<String> { Set(entry.snapshot?.armableSessionIDs ?? []) }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: smallView
            case .systemLarge: listView(limit: 8)
            default: listView(limit: 3)
            }
        }
        .padding(12)
        .containerBackground(.background, for: .widget)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activeGradient)
            Text("Claude Sessions").font(.system(size: 12, weight: .bold))
            Spacer()
            if let armed = entry.snapshot?.armedSessionIDs, !armed.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                    Text("\(armed.count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
            }
            livePill
        }
    }

    private var livePill: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("\(entry.snapshot?.runningCount ?? 0)")
                .font(.system(size: 11, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.15)))
    }

    // MARK: - Session bar

    /// Side length of the interactive arm/disarm control — a finger-sized tap target.
    private let controlSize: CGFloat = 34

    @ViewBuilder private func sessionBar(_ s: SessionUsage) -> some View {
        let isArmed = armedIDs.contains(s.id)
        let canArm = armableIDs.contains(s.id)
        HStack(spacing: 10) {
            // Left column: name + token count + (now shorter) progress bar.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(s.projectName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Formatting.tokenCount(s.totalTokens))
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(activeGradient)
                            .frame(width: max(8, geo.size.width * CGFloat(s.totalTokens) / CGFloat(maxTokens)))
                    }
                }
                .frame(height: 7)
            }
            // Right: proper-sized arm/disarm control (or a same-size spacer to keep bars aligned).
            if isArmed {
                armControl(DisarmSessionIntent(sessionID: s.id), systemImage: "bolt.slash.fill", armed: true)
                    .help("Disarm auto-resume")
            } else if canArm {
                armControl(ArmSessionIntent(sessionID: s.id), systemImage: "bolt.fill", armed: false)
                    .help("Arm overnight auto-resume")
            } else {
                Color.clear.frame(width: controlSize, height: controlSize)
            }
        }
    }

    /// A finger-sized rounded button that runs `intent` on tap. Orange/filled when
    /// armed (disarm), subtle when armable (arm).
    @ViewBuilder private func armControl<I: AppIntent>(_ intent: I, systemImage: String, armed: Bool) -> some View {
        Button(intent: intent) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: controlSize, height: controlSize)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(armed ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(armed ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layouts

    @ViewBuilder private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(activeGradient)
                Text("\(entry.snapshot?.runningCount ?? 0) active")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
            }
            Spacer(minLength: 0)
            if let top = sessions.first {
                Text(Formatting.tokenCount(top.totalTokens))
                    .font(.system(size: 26, weight: .bold)).monospacedDigit()
                    .foregroundStyle(activeGradient)
                Text(top.projectName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                GeometryReader { geo in
                    Capsule().fill(activeGradient).frame(width: geo.size.width, height: 5)
                }.frame(height: 5)
            } else {
                emptyLabel
            }
        }
    }

    @ViewBuilder private func listView(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if sessions.isEmpty {
                Spacer(minLength: 0)
                HStack { Spacer(); emptyLabel; Spacer() }
                Spacer(minLength: 0)
            } else {
                ForEach(sessions.prefix(limit)) { sessionBar($0) }
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyLabel: some View {
        VStack(spacing: 4) {
            Image(systemName: "moon.zzz").font(.system(size: 18)).foregroundStyle(.secondary)
            Text("No active sessions").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

struct ClaudeMeterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeMeterWidget", provider: Provider()) { entry in
            ClaudeMeterWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Sessions")
        .description("Live token usage across your Claude Code sessions.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ClaudeMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeMeterWidget()
    }
}
