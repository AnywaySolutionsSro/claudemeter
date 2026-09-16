@testable import ClaudeMeterCore
import Foundation
import Testing

struct ExtraUsageDecodingTests {
    private let decoder = UsageResponseDecoder()

    private func decode(_ json: String) throws -> ExtraUsage? {
        try decoder.decode(Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 1_789_000_000)).extraUsage
    }

    /// The verified live shape, both blocks, as returned on a Max subscription.
    private let realShape = """
    {"five_hour":{"utilization":29.0,"resets_at":"2026-09-16T09:50:00.744377+00:00"},
     "extra_usage":{"is_enabled":true,"monthly_limit":11000,"used_credits":7509.0,
       "utilization":68.26363636363637,"currency":"EUR","decimal_places":2,
       "disabled_reason":null,"user_disabled":false,"spend_limit_reached":false,
       "credits_ever_enabled":true,"daily":null,"weekly":null},
     "spend":{"used":{"amount_minor":7509,"currency":"EUR","exponent":2},
       "limit":{"amount_minor":11000,"currency":"EUR","exponent":2},
       "percent":68,"severity":"normal","enabled":true,"disabled_reason":null,
       "cap":{"money":{"amount_minor":11000,"currency":"EUR","exponent":2},"credits":null},
       "balance":null,"auto_reload":null,"can_purchase_credits":false,"can_toggle":false}}
    """

    @Test func readsTheLiveShape() throws {
        let extra = try #require(try decode(realShape))
        #expect(extra.isEnabled)
        #expect(extra.used.decimalValue == Decimal(string: "75.09"))
        #expect(extra.limit?.decimalValue == Decimal(string: "110.00"))
        #expect(extra.percentUsed.map { Int($0.rounded()) } == 68)
        #expect(!extra.capReached)
        #expect(!extra.canPurchase)
        #expect(extra.disabledReason == nil)
    }

    @Test func absentFromAResponseWithNeitherBlock() throws {
        #expect(try decode(#"{"five_hour":{"utilization":29.0}}"#) == nil)
    }

    // MARK: - Precedence: `spend` is the newer block and wins

    @Test func prefersSpendOverExtraUsageWhenTheyDisagree() throws {
        let json = """
        {"extra_usage":{"is_enabled":true,"monthly_limit":11000,"used_credits":1.0,
           "utilization":0.01,"currency":"EUR","decimal_places":2},
         "spend":{"used":{"amount_minor":7509,"currency":"EUR","exponent":2},
           "limit":{"amount_minor":11000,"currency":"EUR","exponent":2},"percent":68,"enabled":true}}
        """
        #expect(try decode(json)?.used.decimalValue == Decimal(string: "75.09"))
    }

    @Test func fallsBackToExtraUsageWhenSpendIsUnusable() throws {
        let json = """
        {"extra_usage":{"is_enabled":true,"monthly_limit":11000,"used_credits":7509.0,
           "utilization":68.26,"currency":"EUR","decimal_places":2},
         "spend":{"used":{"amount_minor":7509,"currency":"EUR"},"percent":68,"enabled":true}}
        """
        let extra = try #require(try decode(json))
        #expect(extra.used.decimalValue == Decimal(string: "75.09"))
        #expect(extra.limit?.decimalValue == Decimal(string: "110.00"))
    }

    @Test func readsTheLegacyBlockOnItsOwn() throws {
        let json = """
        {"extra_usage":{"is_enabled":true,"monthly_limit":11000,"used_credits":7509.0,
          "utilization":68.26,"currency":"EUR","decimal_places":2,"spend_limit_reached":false}}
        """
        let extra = try #require(try decode(json))
        #expect(extra.used.decimalValue == Decimal(string: "75.09"))
        #expect(extra.limit?.decimalValue == Decimal(string: "110.00"))
        #expect(extra.isEnabled)
    }

    /// The cap can arrive under `cap.money` instead of `limit`.
    @Test func fallsBackToTheCapObjectForTheLimit() throws {
        let json = """
        {"spend":{"used":{"amount_minor":7509,"currency":"EUR","exponent":2},"enabled":true,
          "cap":{"money":{"amount_minor":11000,"currency":"EUR","exponent":2},"credits":null}}}
        """
        #expect(try decode(json)?.limit?.decimalValue == Decimal(string: "110.00"))
    }

    // MARK: - A half-read figure is nothing, never zero

    @Test func aPartiallyReadableSpendBlockYieldsNoReadingRatherThanZero() throws {
        let json = #"{"spend":{"used":{"amount_minor":7509,"exponent":2},"percent":68,"enabled":true}}"#
        #expect(try decode(json) == nil)
    }

    @Test func aLegacyBlockWithoutACurrencyYieldsNoReading() throws {
        let json = #"{"extra_usage":{"is_enabled":true,"used_credits":7509.0,"decimal_places":2}}"#
        #expect(try decode(json) == nil)
    }

    @Test func garbageInPlaceOfTheBlocksYieldsNoReading() throws {
        #expect(try decode(#"{"spend":"lots","extra_usage":[1,2,3]}"#) == nil)
    }

    // MARK: - States

    @Test func anAccountWithNoCapHasNoLimitOrPercentage() throws {
        let json = """
        {"spend":{"used":{"amount_minor":7509,"currency":"EUR","exponent":2},
          "limit":null,"percent":null,"enabled":true}}
        """
        let extra = try #require(try decode(json))
        #expect(extra.limit == nil)
        #expect(extra.percentUsed == nil)
    }

    @Test func derivesThePercentageWhenTheServerOmitsIt() throws {
        let json = """
        {"spend":{"used":{"amount_minor":5500,"currency":"EUR","exponent":2},
          "limit":{"amount_minor":11000,"currency":"EUR","exponent":2},"enabled":true}}
        """
        #expect(try decode(json)?.percentUsed == 50)
    }

    @Test func anOffAccountIsReportedAsOff() throws {
        let json = """
        {"spend":{"used":{"amount_minor":0,"currency":"EUR","exponent":2},
          "limit":null,"enabled":false}}
        """
        let extra = try #require(try decode(json))
        #expect(!extra.isEnabled)
        #expect(!extra.isBlocked)
    }

    @Test func aCapReachedAccountIsBlocked() throws {
        let json = """
        {"extra_usage":{"is_enabled":true,"monthly_limit":11000,"used_credits":11000.0,
           "utilization":100.0,"currency":"EUR","decimal_places":2,"spend_limit_reached":true},
         "spend":{"used":{"amount_minor":11000,"currency":"EUR","exponent":2},
           "limit":{"amount_minor":11000,"currency":"EUR","exponent":2},
           "percent":100,"severity":"critical","enabled":true}}
        """
        let extra = try #require(try decode(json))
        #expect(extra.capReached)
        #expect(extra.isBlocked)
        #expect(extra.blockedMessage == "Monthly limit reached")
    }

    /// `spend_limit_reached` exists only in the legacy block. When a response carries
    /// `spend` alone — the documented direction of travel — a full cap must still read
    /// as blocked, or the UI tells the user they can spend when they cannot.
    @Test func aFullCapWithoutTheLegacyBlockStillReadsAsBlocked() throws {
        let json = """
        {"spend":{"used":{"amount_minor":11000,"currency":"EUR","exponent":2},
          "limit":{"amount_minor":11000,"currency":"EUR","exponent":2},
          "percent":100,"severity":"critical","enabled":true}}
        """
        let extra = try #require(try decode(json))
        #expect(extra.capReached)
        #expect(extra.blockedMessage == "Monthly limit reached")
    }

    @Test func anUncappedAccountIsNeverReportedAsCapReached() throws {
        let json = """
        {"spend":{"used":{"amount_minor":900000,"currency":"EUR","exponent":2},
          "limit":null,"percent":null,"enabled":true}}
        """
        let extra = try #require(try decode(json))
        #expect(!extra.capReached)
        #expect(!extra.isBlocked)
    }

    @Test func carriesThePurchaseCapabilityFlag() throws {
        let json = """
        {"spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},
          "enabled":true,"can_purchase_credits":true}}
        """
        let extra = try #require(try decode(json))
        #expect(extra.canPurchase)
    }

    // MARK: - Disabled reasons become human copy, never a raw server enum

    @Test(arguments: [
        ("out_of_credits", "Out of usage credits"),
        ("org_spend_cap_reached", "Your organisation's spend cap is reached"),
        ("org_level_disabled_until", "Turned off by your organisation"),
        ("overage_not_provisioned", "Extra usage isn't set up for this account"),
    ])
    func translatesTheKnownDisabledReasons(_ testCase: (reason: String, copy: String)) {
        let extra = ExtraUsage(
            isEnabled: true, used: Money(amountMinor: 0, currency: "EUR", exponent: 2),
            disabledReason: testCase.reason,
        )
        #expect(extra.blockedMessage == testCase.copy)
    }

    /// The vocabulary is undocumented and will grow; an unseen value must not reach the user raw.
    @Test func anUnknownDisabledReasonFallsBackToGenericCopy() {
        let extra = ExtraUsage(
            isEnabled: true, used: Money(amountMinor: 0, currency: "EUR", exponent: 2),
            disabledReason: "some_future_reason",
        )
        #expect(extra.blockedMessage == "Extra usage is paused")
    }

    @Test func aHealthyAccountHasNoBlockedMessage() {
        let extra = ExtraUsage(isEnabled: true, used: Money(amountMinor: 1, currency: "EUR", exponent: 2))
        #expect(extra.blockedMessage == nil)
    }

    // MARK: - Headline

    @Test func headlineShowsSpendAgainstTheCap() {
        let extra = ExtraUsage(
            isEnabled: true, used: Money(amountMinor: 7509, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 11_000, currency: "EUR", exponent: 2),
        )
        #expect(extra.headline == "€75.09 of €110.00")
    }

    @Test func headlineWithoutACapShowsSpendAlone() {
        let extra = ExtraUsage(isEnabled: true, used: Money(amountMinor: 7509, currency: "EUR", exponent: 2))
        #expect(extra.headline == "€75.09")
    }
}
