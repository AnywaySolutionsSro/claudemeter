import ClaudeMeterCore
import SwiftUI

/// "API" block in the dropdown: the last completed day, month to date, last month, and the
/// top models. Renders nothing at all when no admin key is configured.
///
/// Every figure is shown with when it was fetched. The Cost API trails real usage and a
/// cached reading can be days old, so a bare number here would read as current when it
/// isn't — the failure mode that matters most for something denominated in money.
struct ApiSpendSection: View {
    @EnvironmentObject var store: ApiSpendStore
    @Environment(\.textScale) private var scale
    let now: Date

    var body: some View {
        if store.hasKey {
            VStack(alignment: .leading, spacing: scale.pt(6)) {
                Divider()
                header

                if let snapshot = store.snapshot {
                    figures(snapshot)
                } else if store.isLoading {
                    Text("Loading…").font(scale.font(11)).foregroundStyle(.secondary)
                }

                if let error = store.errorMessage {
                    Text(error).font(scale.font(10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("API").font(scale.font(11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let updated = store.lastUpdated {
                Text(isStale ? "stale · \(Self.updatedLabel(updated))"
                    : Self.updatedLabel(updated))
                    .font(scale.font(10))
                    .foregroundStyle(isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    private var isStale: Bool { store.snapshot?.isStale(now: now) ?? false }

    @ViewBuilder
    private func figures(_ snapshot: ApiSpendSnapshot) -> some View {
        if let day = snapshot.latestDay {
            // Labelled from the bucket's own date: off a stale cache the newest completed
            // day can be far older than yesterday, and saying "Yesterday" would name the
            // wrong day as fact.
            row(Formatting.utcDayLabel(day.start, now: now), Formatting.usd(day.amountUSD))
        }
        row("Month to date", Formatting.usd(snapshot.monthToDateUSD(now: now)))
        row("Last month", Formatting.usd(snapshot.previousMonthUSD(now: now)))
        ForEach(Array(snapshot.byModel(now: now).prefix(3)), id: \.model) { entry in
            row(shortModel(entry.model), Formatting.usd(entry.amountUSD), indented: true)
        }
        if let note = store.statusNote {
            Text(note).font(scale.font(10)).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func row(_ title: String, _ value: String, indented: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(scale.font(indented ? 10 : 11))
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, indented ? scale.pt(10) : 0)
            Spacer()
            Text(value)
                .font(scale.font(indented ? 10 : 11))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    private static func updatedLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `claude-sonnet-5` reads better as `sonnet-5` in a narrow dropdown.
    private func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}
