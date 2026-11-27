import Foundation

/// How clock times are written: follow the Mac's region setting, or force 24-hour / 12-hour.
public enum ClockStyle: String, Codable, Sendable, CaseIterable {
    case system
    case twentyFour
    case twelve

    /// Whether times render with AM/PM under this style in `locale`.
    public func uses12Hour(locale: Locale = .current) -> Bool {
        switch self {
        case .twelve: true
        case .twentyFour: false
        case .system:
            (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
        }
    }

    public var label: String {
        switch self {
        case .system: "System"
        case .twentyFour: "24-hour"
        case .twelve: "12-hour"
        }
    }
}
