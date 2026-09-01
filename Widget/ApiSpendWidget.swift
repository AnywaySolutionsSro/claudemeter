import ClaudeMeterCore
import SwiftUI
import WidgetKit

struct ApiSpendEntry: TimelineEntry {
    let date: Date
    let snapshot: ApiSpendSnapshot?
}

/// Reads `api-spend.json` from the widget's own container Documents — the app cannot
/// deliver into the App Group container that a sandboxed widget can read.
struct ApiSpendProvider: TimelineProvider {
    func placeholder(in _: Context) -> ApiSpendEntry {
        ApiSpendEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (ApiSpendEntry) -> Void) {
        completion(ApiSpendEntry(date: Date(), snapshot: Self.read()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ApiSpendEntry>) -> Void) {
        let entry = ApiSpendEntry(date: Date(), snapshot: Self.read())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func read() -> ApiSpendSnapshot? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("api-spend.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ApiSpendSnapshot.self, from: data)
    }
}

struct ApiSpendWidgetView: View {
    let entry: ApiSpendEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API").font(.caption2).foregroundStyle(.secondary)
            if let snapshot = entry.snapshot {
                Text(Formatting.usd(snapshot.monthToDateUSD(now: entry.date)))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("this month").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Yesterday \(Formatting.usd(snapshot.latestDayUSD))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Text("Add an admin key in ClaudeMeter Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct ApiSpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeApiSpend", provider: ApiSpendProvider()) { entry in
            ApiSpendWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("API Spend")
        .description("Your Claude API spend this month.")
        .supportedFamilies([.systemSmall])
    }
}
