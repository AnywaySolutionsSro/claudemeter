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
        style: ClockStyle = .system,
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date),
        ).day ?? 0

        let time = clockTime(date, style: style, timeZone: timeZone, locale: locale)
        switch days {
        case ...0: return "today \(time)"
        case 1: return "tomorrow \(time)"
        default: return "\(format(date, "EEE d MMM", timeZone)) \(time)"
        }
    }

    /// A wall-clock time: `14:05` or `2:05 PM`.
    static func clockTime(
        _ date: Date,
        style: ClockStyle,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
    ) -> String {
        format(date, style.uses12Hour(locale: locale) ? "h:mm a" : "HH:mm", timeZone)
    }

    /// A short date plus clock time: `27 Nov 14:05`. Month words are English, like `resetMoment`.
    static func dateTime(
        _ date: Date,
        style: ClockStyle,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
    ) -> String {
        "\(format(date, "d MMM", timeZone)) \(clockTime(date, style: style, timeZone: timeZone, locale: locale))"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
