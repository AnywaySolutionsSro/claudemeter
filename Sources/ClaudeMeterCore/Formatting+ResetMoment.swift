import Foundation

public extension Formatting {
    /// When a limit window resets, as a wall-clock moment: `today 23:05`,
    /// `tomorrow 04:00`, or `Sat 28 Nov 06:00`.
    ///
    /// A countdown alone (`4d10h`) makes the reader do date arithmetic to learn the
    /// weekday and time of day; this states them. Words and order are English to match
    /// the rest of the UI, but "today"/"tomorrow" are judged in the viewer's time zone
    /// and the clock follows their locale's 12/24-hour preference.
    static func resetMoment(
        _ date: Date,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date),
        ).day ?? 0

        let time = format(date, uses12Hour(locale) ? "h:mm a" : "HH:mm", timeZone)
        switch days {
        case ...0: return "today \(time)"
        case 1: return "tomorrow \(time)"
        default: return "\(format(date, "EEE d MMM", timeZone)) \(time)"
        }
    }

    private static func uses12Hour(_ locale: Locale) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return pattern.contains("a")
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
