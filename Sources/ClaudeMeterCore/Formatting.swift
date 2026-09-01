import Foundation

/// Display helpers shared by the menu-bar label and the dropdown view.
public enum Formatting {
    /// Render a 0...100 value as a whole-percent string, e.g. `37%`.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Compact countdown for a duration: `2h14m`, `47m`, `8s`, or `now`.
    public static func countdown(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        guard total > 0 else { return "now" }

        let hours = total / 3600
        let minutes = (total % 3600) / 60

        if hours > 0 { return "\(hours)h\(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// Compact human-readable token count: `999`, `1.5K`, `28K`, `1.3M`.
    public static func tokenCount(_ tokens: Int) -> String {
        let n = Double(tokens)
        switch tokens {
        case ..<1_000:
            return "\(tokens)"
        case ..<1_000_000:
            let k = n / 1_000
            return k < 10 ? String(format: "%.1fK", k) : String(format: "%.0fK", k)
        default:
            let m = n / 1_000_000
            return m < 10 ? String(format: "%.1fM", m) : String(format: "%.0fM", m)
        }
    }

    /// Placeholder for "we have no reading", so it can never be confused with "$0.00",
    /// which must mean "we fetched, and it was zero".
    public static let noValue = "—"

    public static func usd(_ amount: Decimal?) -> String {
        guard let amount else { return noValue }
        return usd(amount)
    }

    /// Formats USD for display, always to cents (`$2.59`).
    ///
    /// Pinned to `en_US` deliberately: the bill is in USD, and matching the Console
    /// invoice's separators matters more than matching the viewer's locale.
    ///
    /// Rounds **half-up** to agree with the invoice; `NumberFormatter` defaults to
    /// half-even, which renders $0.025 as $0.02 where the bill says $0.03. A non-zero
    /// amount that would round to zero renders as `<$0.01` rather than `$0.00`, so real
    /// sub-cent spend is never displayed as no spend at all.
    public static func usd(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        guard let text = formatter.string(from: amount as NSDecimalNumber) else {
            return noValue
        }
        guard amount != 0, roundsToZero(amount) else { return text }
        return amount < 0 ? "-<$0.01" : "<$0.01"
    }

    /// Labels a UTC cost bucket relative to `now`.
    ///
    /// The Cost API only reports completed days, so the newest bucket is normally
    /// yesterday — but off a stale cache it can be far older, and calling that
    /// "Yesterday" states the wrong day as fact.
    public static func utcDayLabel(_ day: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // NB: `isDateInYesterday` compares against the system clock, not `now`, so it
        // cannot be used here — the delta is computed explicitly to stay testable.
        let delta = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now),
        ).day
        if delta == 1 { return "Yesterday" }
        if delta == 0 { return "Today" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year)
            ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: day)
    }

    private static func roundsToZero(_ amount: Decimal) -> Bool {
        var magnitude = abs(amount)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &magnitude, 2, .plain)
        return rounded == 0
    }
}
