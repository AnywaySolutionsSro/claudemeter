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
                figures(snapshot)
            } else {
                Spacer(minLength: 0)
                // The app is the only thing that writes this file, so an absent file most
                // often means the app hasn't run — not that the key is missing.
                Text("Open ClaudeMeter to load API spend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func figures(_ snapshot: ApiSpendSnapshot) -> some View {
        // A snapshot fetched in an earlier month would compute "this month" as a confident
        // $0.00 from data that simply doesn't cover this month.
        let outdated = snapshot.predatesMonth(of: entry.date)
        let stale = snapshot.isStale(now: entry.date)

        Text(outdated ? Formatting.noValue
            : Formatting.usd(snapshot.monthToDateUSD(now: entry.date)))
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(stale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        Text("this month").font(.caption2).foregroundStyle(.secondary)
        Spacer(minLength: 0)

        if let day = snapshot.latestDay {
            Text("\(Formatting.utcDayLabel(day.start, now: entry.date)) "
                + "\(Formatting.usd(day.amountUSD))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Text("Last month \(Formatting.usd(snapshot.previousMonthUSD(now: entry.date)))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        // Always say when — a widget renders long after the app stopped refreshing it.
        Text((stale || outdated ? "⚠︎ as of " : "as of ")
            + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption2)
            .foregroundStyle(stale || outdated ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
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
