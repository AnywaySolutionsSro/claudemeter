import ClaudeMeterCore
import SwiftUI
import WidgetKit

// MARK: - Single-gauge small widget (one per account window)

/// Which account window a single-gauge widget shows. Picked by the gauge's label,
/// not its position: the list only holds the buckets the API returned, so an
/// absent 5-hour bucket would otherwise shift the Weekly ring into the Session widget.
enum GaugeSlot {
    case session, weekly, model

    func pick(from gauges: [UsageGauge]) -> UsageGauge? {
        switch self {
        case .session: gauges.first { $0.label == "Session" }
        case .weekly: gauges.first { $0.label == "Weekly" }
        case .model: gauges.first { $0.label != "Session" && $0.label != "Weekly" }
        }
    }
}

/// Small widget showing exactly one gauge, from Claude's gauges or Codex's — never a
/// mix, since both have a "Weekly".
struct SingleGaugeView: View {
    let entry: SnapshotEntry
    let slot: GaugeSlot
    var tool: AgentTool = .claude

    private var gauges: [UsageGauge] {
        switch tool {
        case .claude: entry.snapshot?.usageGauges ?? []
        case .codex: entry.snapshot?.codexGauges ?? []
        }
    }

    /// Codex's widget is always green; Claude's takes its colour only once Codex is around.
    private var tint: AgentTool? {
        tool == .codex || entry.snapshot?.includesCodex == true ? tool : nil
    }

    var body: some View {
        Group {
            if let gauge = slot.pick(from: gauges) {
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    GaugeRingView(gauge: gauge, size: 96, tint: tint)
                    if tool == .codex, let age = entry.codexReadingAge {
                        Text(age).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tool == .codex {
                noCodexData
            } else if slot == .session, !gauges.isEmpty {
                // Not missing data: verified Ultra accounts have no session window.
                noSessionWindow
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
            SingleGaugeView(entry: entry, slot: .session)
        }
        .configurationDisplayName("Claude · Session (5h)")
        .description("The 5-hour session window as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

struct WeeklyGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeGaugeWeekly", provider: Provider()) { entry in
            SingleGaugeView(entry: entry, slot: .weekly)
        }
        .configurationDisplayName("Claude · Weekly")
        .description("The weekly usage window as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

struct ModelGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeGaugeModel", provider: Provider()) { entry in
            SingleGaugeView(entry: entry, slot: .model)
        }
        .configurationDisplayName("Claude · Weekly model")
        .description("The weekly per-model window (Opus / Sonnet) as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

struct CodexWeeklyGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CodexGaugeWeekly", provider: Provider()) { entry in
            SingleGaugeView(entry: entry, slot: .weekly, tool: .codex)
        }
        .configurationDisplayName("Codex · Weekly")
        .description("Codex's weekly usage window as a circular gauge.")
        .supportedFamilies([.systemSmall])
    }
}

/// The Codex widget before any Codex limit reading has reached the app.
private var noCodexData: some View {
    VStack(spacing: 6) {
        Circle().fill(Color(tool: .codex)).frame(width: 10, height: 10)
        Text("No Codex limits").font(.system(size: 11, weight: .semibold))
        Text("Connect your Codex account in ClaudeMeter")
            .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        CodexWeeklyGaugeWidget()
        ApiSpendWidget()
    }
}
