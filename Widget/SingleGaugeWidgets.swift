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

/// Small widget showing exactly one gauge.
struct SingleGaugeView: View {
    let entry: SnapshotEntry
    let slot: GaugeSlot

    private var gauges: [UsageGauge] { entry.snapshot?.usageGauges ?? [] }

    var body: some View {
        Group {
            if let gauge = slot.pick(from: gauges) {
                VStack {
                    Spacer(minLength: 0)
                    GaugeRingView(gauge: gauge, size: 96)
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
        ApiSpendWidget()
    }
}
