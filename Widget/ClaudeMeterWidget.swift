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
    /// Armed set the widget should DISPLAY: the app's authoritative armed set with
    /// any not-yet-applied widget taps folded in, so a tap reflects immediately.
    let effectiveArmed: Set<String>

    /// Representative content for the gallery preview / first paint.
    static var sample: SnapshotEntry {
        let now = Date()
        let demo = [("liberspiro", 12_000_000), ("movixtar", 2_700_000), ("mbx", 1_800_000)]
            .map { name, tok in
                SessionUsage(id: name, origin: .cli, projectPath: "/code/\(name)", models: ["claude-opus-4-8"],
                             tokens: TokenBreakdown(input: tok), messageCount: 1,
                             firstActivity: now, lastActivity: now, burnRate: 0, running: .running)
            }
        let base = SessionSnapshot.make(from: demo, now: now, runningOnly: true)
        let gauges = [
            UsageGauge(label: "Session", percentLeft: 78, resetsAt: now.addingTimeInterval(4 * 3600 + 9 * 60)),
            UsageGauge(label: "Weekly", percentLeft: 37, resetsAt: now.addingTimeInterval(106 * 3600)),
            UsageGauge(label: "Sonnet", percentLeft: 77, resetsAt: now.addingTimeInterval(106 * 3600)),
        ]
        let snap = SessionSnapshot(
            generatedAt: base.generatedAt, sessions: base.sessions, totalTokens: base.totalTokens,
            runningCount: base.runningCount, usageGauges: gauges)
        return SnapshotEntry(date: now, snapshot: snap, effectiveArmed: [])
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
        // Read from our own container Documents, where the app delivers the snapshot
        // and where our tap commands are queued.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let snapshot = store.read(from: documents.appendingPathComponent("snapshot.json"))

        // Optimistic display: fold pending (not-yet-applied) taps onto the
        // app's authoritative armed set so the toggle flips the instant it's tapped.
        var armed = Set(snapshot?.armedSessionIDs ?? [])
        let pending = ArmedSessionsStore().peekCommands(at: documents.appendingPathComponent("widget-commands.json"))
        for command in pending {
            switch command.action {
            case .arm: armed.insert(command.sessionID)
            case .disarm: armed.remove(command.sessionID)
            }
        }
        widgetLog.log("loaded \(snapshot?.sessions.count ?? -1) sessions, \(pending.count) pending taps")
        return SnapshotEntry(date: Date(), snapshot: snapshot, effectiveArmed: armed)
    }
}

private let activeGradient = LinearGradient(
    colors: [Color.green, Color(red: 0.2, green: 0.85, blue: 0.6)],
    startPoint: .leading, endPoint: .trailing
)

// MARK: - Reusable circular gauge

/// A circular "% left" ring for one account window, with the percentage in the
/// centre and (optionally) a short label + reset countdown beneath. Sized by the
/// caller so it works at small-widget scale and in the compact gauge row alike.
struct GaugeRingView: View {
    let gauge: UsageGauge
    var size: CGFloat
    var showLabel: Bool = true
    var showReset: Bool = true

    var body: some View {
        let fraction = max(0.0001, min(1, gauge.percentLeft / 100))
        VStack(spacing: size * 0.06) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: size * 0.11)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Self.style(gauge.percentLeft),
                            style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -1) {
                    Text("\(Int(gauge.percentLeft.rounded()))")
                        .font(.system(size: size * 0.30, weight: .bold)).monospacedDigit()
                    Text("% left").font(.system(size: max(7, size * 0.12), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            if showLabel {
                Text(gauge.label)
                    .font(.system(size: min(15, max(10, size * 0.15)), weight: .semibold)).lineLimit(1)
            }
            if showReset, let reset = gauge.resetsAt {
                Text(Self.resetShort(reset))
                    .font(.system(size: min(12, max(8.5, size * 0.12))))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Green when plenty left, amber as it tightens, red when nearly spent.
    static func style(_ left: Double) -> LinearGradient {
        let colors: [Color]
        switch left {
        case ..<15: colors = [Color.red, Color.orange]
        case ..<40: colors = [Color.orange, Color(red: 1.0, green: 0.82, blue: 0.3)]
        default:    colors = [Color.green, Color(red: 0.2, green: 0.85, blue: 0.6)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// Compact "4h9m" / "12m" countdown until a window resets.
    static func resetShort(_ date: Date) -> String {
        let secs = Int(max(0, date.timeIntervalSinceNow))
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }
}

private var noGaugeData: some View {
    VStack(spacing: 6) {
        Image(systemName: "gauge.with.dots.needle.67percent")
            .font(.system(size: 22)).foregroundStyle(.secondary)
        Text("No usage data").font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

// MARK: - Main widget (medium = gauges only; large / XL = gauges + sessions)

struct ClaudeMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var sessions: [SessionUsage] { entry.snapshot?.sessions ?? [] }
    private var maxTokens: Int { max(1, sessions.map(\.totalTokens).max() ?? 1) }
    private var armedIDs: Set<String> { entry.effectiveArmed }
    private var armableIDs: Set<String> { Set(entry.snapshot?.armableSessionIDs ?? []) }
    private var gauges: [UsageGauge] { entry.snapshot?.usageGauges ?? [] }

    var body: some View {
        Group {
            switch family {
            case .systemLarge: sessionsListView        // active sessions only
            case .systemExtraLarge: sessionsGridView   // two columns of sessions
            default: gaugesOnlyView                    // systemMedium: gauges only
            }
        }
        .padding(12)
        .containerBackground(.background, for: .widget)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activeGradient)
            Text("Claude Sessions").font(.system(size: 12, weight: .bold))
            Spacer()
            if !armedIDs.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                    Text("\(armedIDs.count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
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

    // MARK: Session bar

    /// Dimensions of the interactive arm/disarm toggle pill.
    private let toggleWidth: CGFloat = 46
    private let toggleHeight: CGFloat = 26

    /// "Charged" amber knob fill shown when a session is armed.
    private let armedAccent = LinearGradient(
        colors: [Color.orange, Color(red: 1.0, green: 0.78, blue: 0.25)],
        startPoint: .top, endPoint: .bottom
    )

    @ViewBuilder private func sessionBar(_ s: SessionUsage, compact: Bool = false) -> some View {
        let isArmed = armedIDs.contains(s.id)
        let canArm = armableIDs.contains(s.id)
        HStack(spacing: 10) {
            // Left column: name + current model + token count + progress bar.
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 5) {
                    // Name and token count outrank the model label, so the model
                    // truncates first on narrow rows. NB: a negative priority on
                    // the model does NOT work — the Spacer (priority 0) claims all
                    // leftover width before a -1 view is sized, collapsing it to
                    // zero. Priorities must be raised on the keepers instead.
                    Text(s.projectName)
                        .font(.system(size: compact ? 11 : 12, weight: .medium)).lineLimit(1)
                        .layoutPriority(1)
                    if let model = s.lastModel ?? s.models.last {
                        HStack(spacing: 3) {
                            // Grayscaled emoji: SF Symbols has no robot glyph, and
                            // the filter keeps it neutral in every rendering mode.
                            Text("🤖")
                                .font(.system(size: compact ? 9 : 10))
                                .grayscale(1)
                            Text(shortModel(model))
                                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Formatting.tokenCount(s.totalTokens))
                        .font(.system(size: compact ? 11 : 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(activeGradient)
                            .frame(width: max(8, geo.size.width * CGFloat(s.totalTokens) / CGFloat(maxTokens)))
                    }
                }
                .frame(height: compact ? 5 : 7)
            }
            // Right: an on/off toggle. ON (armed) = lit amber track + knob right;
            // OFF (armable) = muted track + knob left; not armable = the same
            // toggle dimmed (matches the Sessions window instead of a hole).
            if isArmed {
                armToggle(DisarmSessionIntent(sessionID: s.id), armed: true)
                    .help("Armed — tap to disarm")
            } else if canArm {
                armToggle(ArmSessionIntent(sessionID: s.id), armed: false)
                    .help("Tap to arm overnight auto-resume")
            } else {
                togglePill(armed: false)
                    .opacity(0.28)
            }
        }
    }

    /// Trim the common `claude-` prefix for compact display, e.g. `opus-4-8`.
    private func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    /// A toggle-style pill that runs `intent` on tap. The track stays a consistent
    /// dark capsule (low luminance) so the light knob is visible in every widget
    /// rendering mode — including the desktop's monochrome tint over windows.
    @ViewBuilder private func armToggle<I: AppIntent>(_ intent: I, armed: Bool) -> some View {
        Button(intent: intent) {
            togglePill(armed: armed)
        }
        .buttonStyle(.plain)
    }

    /// The pill itself (shared by the interactive toggle and its dimmed,
    /// non-interactive "can't arm" placeholder).
    @ViewBuilder private func togglePill(armed: Bool) -> some View {
        ZStack(alignment: armed ? .trailing : .leading) {
            Capsule()
                .fill(Color.black.opacity(0.32))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            Circle()
                .fill(armed ? AnyShapeStyle(armedAccent) : AnyShapeStyle(Color.white))
                .frame(width: toggleHeight - 6, height: toggleHeight - 6)
                .overlay {
                    if armed {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .padding(.horizontal, 3)
        }
        .frame(width: toggleWidth, height: toggleHeight)
    }

    // MARK: Layouts

    /// Medium widget: just the gauges, evenly spread and vertically centred.
    @ViewBuilder private var gaugesOnlyView: some View {
        if gauges.isEmpty {
            HStack { Spacer(); noGaugeData; Spacer() }.frame(maxHeight: .infinity)
        } else {
            HStack(alignment: .center, spacing: 0) {
                ForEach(gauges) { gauge in
                    GaugeRingView(gauge: gauge, size: 58).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Large widget: just the active-session list (arm/disarm toggles), no gauges.
    /// Widgets can't scroll, so when more sessions are live than the roomy layout
    /// fits, rows tighten up to squeeze in ten instead of seven.
    @ViewBuilder private var sessionsListView: some View {
        let compact = sessions.count > 7
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            header
            if sessions.isEmpty {
                Spacer(minLength: 0)
                HStack { Spacer(); emptyLabel; Spacer() }
                Spacer(minLength: 0)
            } else {
                ForEach(sessions.prefix(compact ? 10 : 7)) { sessionBar($0, compact: compact) }
                Spacer(minLength: 0)
            }
        }
    }

    /// Extra-large widget: two columns, up to 20 sessions.
    @ViewBuilder private var sessionsGridView: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if sessions.isEmpty {
                Spacer(minLength: 0)
                HStack { Spacer(); emptyLabel; Spacer() }
                Spacer(minLength: 0)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())],
                    alignment: .leading, spacing: 9
                ) {
                    ForEach(sessions.prefix(20)) { sessionBar($0) }
                }
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

// MARK: - Single-gauge small widget (one per account window)

/// Small widget showing exactly one gauge, picked by its position in the
/// snapshot's gauge list (0 = Session, 1 = Weekly, 2 = the weekly model window).
struct SingleGaugeView: View {
    let entry: SnapshotEntry
    let slot: Int

    private var gauges: [UsageGauge] { entry.snapshot?.usageGauges ?? [] }

    var body: some View {
        Group {
            if slot < gauges.count {
                VStack {
                    Spacer(minLength: 0)
                    GaugeRingView(gauge: gauges[slot], size: 96)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noGaugeData
            }
        }
        .padding(12)
        .containerBackground(.background, for: .widget)
    }
}

/// Each `Widget` conformer needs its own `init()`, so the three single-gauge
/// widgets are distinct types (sharing `SingleGaugeView`) rather than one
/// parameterized struct — that also gives each a stable `kind` and gallery name.
struct SessionGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeGaugeSession", provider: Provider()) { entry in
            SingleGaugeView(entry: entry, slot: 0)
        }
        .configurationDisplayName("Claude · Session (5h)")
        .description("The 5-hour session window as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

struct WeeklyGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeGaugeWeekly", provider: Provider()) { entry in
            SingleGaugeView(entry: entry, slot: 1)
        }
        .configurationDisplayName("Claude · Weekly")
        .description("The weekly usage window as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

struct ModelGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeGaugeModel", provider: Provider()) { entry in
            SingleGaugeView(entry: entry, slot: 2)
        }
        .configurationDisplayName("Claude · Weekly model")
        .description("The weekly per-model window (Opus / Sonnet) as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Bundle

struct ClaudeMeterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeMeterWidget", provider: Provider()) { entry in
            ClaudeMeterWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Sessions")
        .description("Medium shows account usage gauges; Large and Extra Large show live Claude Code sessions.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct ClaudeMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeMeterWidget()
        SessionGaugeWidget()
        WeeklyGaugeWidget()
        ModelGaugeWidget()
    }
}
