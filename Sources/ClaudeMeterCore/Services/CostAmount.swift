import Foundation

/// Strict parsing for the Cost API's `amount` field.
///
/// `Decimal(string:)` alone is unsafe for money: it **truncates at the first invalid
/// character instead of failing**, so `Decimal(string: "1,234.5678")` is `1` — a silent
/// 1000x understatement if the API ever adds thousands separators. Every amount is
/// validated end-to-end before it is trusted.
///
/// A JSON **number** is accepted as well as a string, so a shape change from
/// `"amount": "103.1554"` to `"amount": 103.1554` degrades to a correct reading rather
/// than dropping every row and reporting a confident $0.00.
public enum CostAmount {
    public static func parse(_ raw: Any?) -> Decimal? {
        if let string = raw as? String { return fromExactString(string) }
        // NSNumber covers JSON numbers; `stringValue` avoids Double's binary rounding.
        if let number = raw as? NSNumber, !(raw is Bool) {
            return fromExactString(number.stringValue)
        }
        return nil
    }

    /// Parses only a complete `-?digits(.digits)?` string; anything else is rejected.
    private static func fromExactString(_ string: String) -> Decimal? {
        var digitsBefore = 0
        var digitsAfter = 0
        var sawSeparator = false
        var index = string.startIndex

        if index < string.endIndex, string[index] == "-" || string[index] == "+" {
            index = string.index(after: index)
        }
        while index < string.endIndex {
            let character = string[index]
            if character.isASCII, character.isNumber {
                if sawSeparator { digitsAfter += 1 } else { digitsBefore += 1 }
            } else if character == ".", !sawSeparator {
                sawSeparator = true
            } else {
                return nil
            }
            index = string.index(after: index)
        }
        guard digitsBefore > 0, !sawSeparator || digitsAfter > 0 else { return nil }
        return Decimal(string: string)
    }
}
