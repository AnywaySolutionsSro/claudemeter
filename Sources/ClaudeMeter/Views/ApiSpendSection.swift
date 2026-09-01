import ClaudeMeterCore
import SwiftUI

/// "API" block in the dropdown: today's spend, month to date, and the top models.
/// Renders nothing at all when no admin key is configured.
struct ApiSpendSection: View {
    @EnvironmentObject var store: ApiSpendStore
    @Environment(\.textScale) private var scale
    let now: Date

    var body: some View {
        if store.hasKey {
            VStack(alignment: .leading, spacing: scale.pt(6)) {
                Divider()
                Text("API")
                    .font(scale.font(11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let snapshot = store.snapshot {
                    // The Cost API reports completed UTC days only — today's spend does
                    // not exist yet, so the freshest real figure is the last full day.
                    row("Yesterday", Formatting.usd(snapshot.latestDayUSD))
                    row("Month to date", Formatting.usd(snapshot.monthToDateUSD(now: now)))
                    row("Last month", Formatting.usd(snapshot.previousMonthUSD(now: now)))
                    ForEach(Array(snapshot.byModel(now: now).prefix(3)), id: \.model) { entry in
                        row(shortModel(entry.model), Formatting.usd(entry.amountUSD), indented: true)
                    }
                } else if store.isLoading {
                    Text("Loading…")
                        .font(scale.font(11))
                        .foregroundStyle(.secondary)
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(scale.font(10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, indented: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(scale.font(indented ? 10 : 11))
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.leading, indented ? scale.pt(10) : 0)
            Spacer()
            Text(value)
                .font(scale.font(indented ? 10 : 11))
                .monospacedDigit()
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    /// `claude-sonnet-5` reads better as `sonnet-5` in a narrow dropdown.
    private func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}
