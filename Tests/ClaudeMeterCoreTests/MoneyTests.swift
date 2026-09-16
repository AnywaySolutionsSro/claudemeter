@testable import ClaudeMeterCore
import Foundation
import Testing

struct MoneyTests {
    // MARK: - Parsing the `spend` money shape

    @Test func parsesTheObservedSpendShape() throws {
        let money = try #require(Money.parse(["amount_minor": 7509, "currency": "EUR", "exponent": 2]))
        #expect(money.amountMinor == 7509)
        #expect(money.currency == "EUR")
        #expect(money.exponent == 2)
    }

    // THE bug this type exists to prevent: 7509 minor units is €75.09, not €7509.
    @Test func minorUnitsAreDividedByTheServerSuppliedExponent() throws {
        let money = try #require(Money.parse(["amount_minor": 7509, "currency": "EUR", "exponent": 2]))
        #expect(money.decimalValue == Decimal(string: "75.09"))
    }

    /// JPY has no minor unit. Hardcoding 2 would render ¥7509 as ¥75.09.
    @Test func honoursAZeroExponentCurrency() throws {
        let money = try #require(Money.parse(["amount_minor": 7509, "currency": "JPY", "exponent": 0]))
        #expect(money.decimalValue == Decimal(7509))
    }

    @Test func rejectsAMissingExponentRatherThanAssumingTwo() {
        #expect(Money.parse(["amount_minor": 7509, "currency": "EUR"]) == nil)
    }

    @Test func rejectsAMissingCurrency() {
        #expect(Money.parse(["amount_minor": 7509, "exponent": 2]) == nil)
    }

    @Test func rejectsAnEmptyCurrency() {
        #expect(Money.parse(["amount_minor": 7509, "currency": "", "exponent": 2]) == nil)
    }

    @Test func rejectsANonNumericAmount() {
        #expect(Money.parse(["amount_minor": "7509", "currency": "EUR", "exponent": 2]) == nil)
    }

    @Test(arguments: [-1, 99]) func rejectsANonsensicalExponent(_ exponent: Int) {
        #expect(Money.parse(["amount_minor": 7509, "currency": "EUR", "exponent": exponent]) == nil)
    }

    @Test func rejectsAnythingThatIsNotAnObject() {
        #expect(Money.parse(nil) == nil)
        #expect(Money.parse(7509) == nil)
        #expect(Money.parse("€75.09") == nil)
    }

    @Test func acceptsZero() throws {
        let money = try #require(Money.parse(["amount_minor": 0, "currency": "EUR", "exponent": 2]))
        #expect(money.decimalValue == 0)
        #expect(money.isZero)
    }

    // MARK: - The legacy `extra_usage` field trio

    @Test func parsesTheLegacyFieldTrio() throws {
        let money = try #require(Money(minorUnits: 7509.0, currency: "EUR", exponent: 2))
        #expect(money.decimalValue == Decimal(string: "75.09"))
    }

    /// `used_credits` arrives as a JSON float (`7509.0`), not an integer.
    @Test func roundsAFractionalMinorUnitAmount() throws {
        let money = try #require(Money(minorUnits: 7509.6, currency: "EUR", exponent: 2))
        #expect(money.amountMinor == 7510)
    }

    @Test func rejectsANonFiniteAmount() {
        #expect(Money(minorUnits: Double.nan, currency: "EUR", exponent: 2) == nil)
        #expect(Money(minorUnits: Double.infinity, currency: "EUR", exponent: 2) == nil)
    }

    // MARK: - Formatting

    @Test func formatsEurosToTheCent() {
        #expect(Formatting.money(Money(amountMinor: 7509, currency: "EUR", exponent: 2)) == "€75.09")
    }

    @Test func formatsAZeroExponentCurrencyWithoutDecimals() {
        #expect(Formatting.money(Money(amountMinor: 7509, currency: "JPY", exponent: 0)) == "¥7,509")
    }

    @Test func formatsDollars() {
        #expect(Formatting.money(Money(amountMinor: 11_000, currency: "USD", exponent: 2)) == "$110.00")
    }

    /// No reading is not zero spend — the distinction the whole feature turns on.
    @Test func formatsNoReadingAsAPlaceholder() {
        #expect(Formatting.money(nil) == Formatting.noValue)
    }

    @Test func roundTripsThroughCodable() throws {
        let money = Money(amountMinor: 7509, currency: "EUR", exponent: 2)
        let data = try JSONEncoder().encode(money)
        let decoded = try JSONDecoder().decode(Money.self, from: data)
        #expect(decoded == money)
    }
}
