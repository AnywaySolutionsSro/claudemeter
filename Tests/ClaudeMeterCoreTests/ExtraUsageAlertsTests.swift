@testable import ClaudeMeterCore
import Foundation
import Testing

struct ExtraUsageAlertsTests {
    private func reading(
        used: Int, limit: Int? = 11_000, enabled: Bool = true, capReached: Bool = false,
    ) -> ExtraUsage {
        ExtraUsage(
            isEnabled: enabled,
            used: Money(amountMinor: used, currency: "EUR", exponent: 2),
            limit: limit.map { Money(amountMinor: $0, currency: "EUR", exponent: 2) },
            capReached: capReached,
        )
    }

    // MARK: - Seeding: the first reading of a run must never notify

    /// Without a prior reading we cannot know a threshold was *crossed* — only that it
    /// holds. Firing here would nag on every launch at 68%.
    @Test func theFirstReadingFiresNothingAndSeedsWhatIsAlreadyTrue() {
        let outcome = ExtraUsageAlerts.decide(previous: nil, current: reading(used: 7509), notified: [])
        #expect(outcome.fire.isEmpty)
        #expect(outcome.notified == [.spendingStarted])
    }

    @Test func theFirstReadingSeedsEveryThresholdAlreadyPassed() {
        let outcome = ExtraUsageAlerts.decide(previous: nil, current: reading(used: 11_000), notified: [])
        #expect(outcome.fire.isEmpty)
        #expect(outcome.notified == [.spendingStarted, .nearingCap, .capReached])
    }

    @Test func theFirstReadingOfAnUnspentMonthSeedsNothing() {
        let outcome = ExtraUsageAlerts.decide(previous: nil, current: reading(used: 0), notified: [])
        #expect(outcome.notified.isEmpty)
    }

    // MARK: - Crossings

    @Test func firesWhenSpendingStarts() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 0), current: reading(used: 120), notified: [],
        )
        #expect(outcome.fire == [.spendingStarted])
    }

    @Test func firesAtEightyPercentOfTheCap() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 7509), current: reading(used: 8_800), notified: [.spendingStarted],
        )
        #expect(outcome.fire == [.nearingCap])
    }

    @Test func firesWhenTheCapIsReached() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 8_800),
            current: reading(used: 11_000, capReached: true),
            notified: [.spendingStarted, .nearingCap],
        )
        #expect(outcome.fire == [.capReached])
    }

    @Test func severalThresholdsCrossedAtOnceFireInOrder() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 0), current: reading(used: 11_000), notified: [],
        )
        #expect(outcome.fire == [.spendingStarted, .nearingCap, .capReached])
    }

    @Test func eachThresholdFiresOnlyOnce() {
        let first = ExtraUsageAlerts.decide(
            previous: reading(used: 7509), current: reading(used: 8_800), notified: [.spendingStarted],
        )
        let second = ExtraUsageAlerts.decide(
            previous: reading(used: 8_800), current: reading(used: 9_900), notified: first.notified,
        )
        #expect(second.fire.isEmpty)
    }

    // MARK: - The only reset signal we get is the amount dropping

    /// The API supplies no reset date for the monthly window, so a drop in spend is
    /// the sole evidence that a new billing period began.
    @Test func aDropInSpendStartsANewPeriod() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 11_000),
            current: reading(used: 0),
            notified: [.spendingStarted, .nearingCap, .capReached],
        )
        #expect(outcome.fire.isEmpty)
        #expect(outcome.notified.isEmpty)
    }

    @Test func theNewPeriodNotifiesAgainOnItsFirstSpend() {
        let rollover = ExtraUsageAlerts.decide(
            previous: reading(used: 11_000), current: reading(used: 0),
            notified: [.spendingStarted, .nearingCap, .capReached],
        )
        let next = ExtraUsageAlerts.decide(
            previous: reading(used: 0), current: reading(used: 250), notified: rollover.notified,
        )
        #expect(next.fire == [.spendingStarted])
    }

    /// A drop straight into fresh spending is one reading, not two.
    @Test func aDropToANonZeroAmountResetsAndFiresForTheNewPeriod() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 11_000), current: reading(used: 300),
            notified: [.spendingStarted, .nearingCap, .capReached],
        )
        #expect(outcome.fire == [.spendingStarted])
        #expect(outcome.notified == [.spendingStarted])
    }

    // MARK: - Quiet cases

    @Test func saysNothingWhenExtraUsageIsOff() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 0, enabled: false),
            current: reading(used: 500, enabled: false), notified: [],
        )
        #expect(outcome.fire.isEmpty)
    }

    @Test func theEightyPercentAlertNeedsACap() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 0, limit: nil),
            current: reading(used: 900_000, limit: nil), notified: [],
        )
        #expect(outcome.fire == [.spendingStarted])
    }

    @Test func aLostReadingChangesNothing() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 7509), current: nil, notified: [.spendingStarted],
        )
        #expect(outcome.fire.isEmpty)
        #expect(outcome.notified == [.spendingStarted])
    }

    @Test func anUnchangedReadingFiresNothing() {
        let outcome = ExtraUsageAlerts.decide(
            previous: reading(used: 7509), current: reading(used: 7509), notified: [.spendingStarted],
        )
        #expect(outcome.fire.isEmpty)
    }

    // MARK: - Copy

    @Test(arguments: ExtraUsageAlert.allCases)
    func everyAlertHasATitleAndBody(_ alert: ExtraUsageAlert) {
        let message = alert.message(for: reading(used: 8_800))
        #expect(!message.title.isEmpty)
        #expect(!message.body.isEmpty)
    }

    @Test func theCapReachedBodyNamesTheAmount() {
        let message = ExtraUsageAlert.capReached.message(for: reading(used: 11_000, capReached: true))
        #expect(message.body.contains("€110.00"))
    }
}
