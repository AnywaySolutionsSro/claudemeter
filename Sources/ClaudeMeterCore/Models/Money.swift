import Foundation

/// An amount of money exactly as the usage API reports it: an integer count of the
/// currency's **minor units**, plus the currency and its own decimal exponent.
///
/// The exponent is always the server's, never an assumption. `{7509, "EUR", 2}` is
/// €75.09, while `{7509, "JPY", 0}` is ¥7,509 — hardcoding two decimal places would
/// misreport the second by a factor of a hundred, the same class of mistake the Cost
/// API's cents-as-dollars trap once caused.
public struct Money: Equatable, Sendable, Codable {
    public let amountMinor: Int
    /// ISO 4217 code, e.g. `EUR`.
    public let currency: String
    /// Decimal places the currency uses: 2 for EUR/USD, 0 for JPY.
    public let exponent: Int

    public init(amountMinor: Int, currency: String, exponent: Int) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.exponent = exponent
    }

    /// The amount in major units — €75.09 for `{7509, "EUR", 2}`.
    public var decimalValue: Decimal {
        Decimal(amountMinor) / pow(Decimal(10), exponent)
    }

    public var isZero: Bool { amountMinor == 0 }

    /// No circulating currency uses more than 4 decimal places; the range allows a
    /// little headroom, and anything past it is a shape change we refuse to guess at
    /// rather than misreport by orders of magnitude.
    private static let exponentRange = 0 ... 6

    /// Parses the `{"amount_minor": …, "currency": …, "exponent": …}` object used
    /// throughout the `spend` block. Returns `nil` unless all three read cleanly —
    /// a partial amount is no reading at all, never zero.
    public static func parse(_ value: Any?) -> Money? {
        guard let object = value as? [String: Any] else { return nil }
        return Money(
            minorUnits: object["amount_minor"],
            currency: object["currency"],
            exponent: object["exponent"],
        )
    }

    /// Parses the same amount from the three separate fields the legacy
    /// `extra_usage` block spreads it across (`used_credits`, `currency`,
    /// `decimal_places`), where the amount arrives as a JSON float.
    public init?(minorUnits: Any?, currency: Any?, exponent: Any?) {
        guard
            let amount = (minorUnits as? NSNumber)?.doubleValue, amount.isFinite,
            let code = (currency as? String)?.trimmingCharacters(in: .whitespaces), !code.isEmpty,
            let places = (exponent as? NSNumber)?.intValue, Money.exponentRange.contains(places)
        else {
            return nil
        }
        self.init(amountMinor: Int(amount.rounded()), currency: code, exponent: places)
    }
}
