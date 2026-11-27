import Foundation

/// Key-by-key readers for undocumented JSON: a value of the wrong type is `nil`,
/// never a default.
enum LenientJSON {
    /// A JSON number (or a numeric string), refusing JSON booleans. `value is Bool` cannot
    /// tell them apart: an `NSNumber` holding 0 or 1 bridges to `Bool`.
    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String, let double = Double(string.trimmingCharacters(in: .whitespaces)) {
            return double.isFinite ? double : nil
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A non-empty string.
    static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
