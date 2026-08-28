@testable import ClaudeMeterCore
import Foundation
import Testing

/// The usage endpoint's `limits[]` array carries per-model weekly windows with a
/// server-supplied label (`scope.model.display_name`, e.g. "Fable") and an
/// `is_active` flag marking the binding limit. Shape observed 2026-08-28.
struct ModelWeeklyLimitTests {
    private let decoder = UsageResponseDecoder()
    private let fetchedAt = Date(timeIntervalSince1970: 1_782_000_000)

    private let observed = Data("""
    {
      "five_hour": { "utilization": 17.0, "resets_at": "2026-08-29T01:19:59.738074+00:00" },
      "seven_day": { "utilization": 44.0, "resets_at": "2026-08-29T04:59:59.738101+00:00" },
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "limits": [
        { "kind": "session", "group": "session", "percent": 17, "severity": "normal",
          "resets_at": "2026-08-29T01:19:59.738074+00:00", "scope": null, "is_active": false },
        { "kind": "weekly_all", "group": "weekly", "percent": 44, "severity": "normal",
          "resets_at": "2026-08-29T04:59:59.738101+00:00", "scope": null, "is_active": false },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 68, "severity": "normal",
          "resets_at": "2026-08-29T04:59:59.738427+00:00",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
          "is_active": true }
      ]
    }
    """.utf8)

    @Test func decodesScopedWeeklyLimitFromLimitsArray() throws {
        let snap = try decoder.decode(observed, fetchedAt: fetchedAt)
        let fable = try #require(snap.modelWeekly.first)
        #expect(snap.modelWeekly.count == 1)
        #expect(fable.label == "Fable")
        #expect(fable.bucket.utilization == 68)
        #expect(fable.bucket.percentRemaining == 32)
        #expect(fable.bucket.resetsAt == ISODate.parse("2026-08-29T04:59:59.738427+00:00"))
        #expect(fable.isActive)
    }

    @Test func sessionAndWeeklyAllEntriesAreNotModelLimits() throws {
        let snap = try decoder.decode(observed, fetchedAt: fetchedAt)
        #expect(snap.modelWeekly.map(\.label) == ["Fable"])
        // The legacy top-level buckets are untouched by the limits array.
        #expect(snap.fiveHour?.utilization == 17)
        #expect(snap.sevenDay?.utilization == 44)
    }

    @Test func missingOrMalformedLimitsYieldNoModelLimits() throws {
        let noLimits = Data(#"{ "five_hour": { "utilization": 1 } }"#.utf8)
        #expect(try decoder.decode(noLimits, fetchedAt: fetchedAt).modelWeekly.isEmpty)

        let junk = Data("""
        { "limits": [ "nope", 42, { "kind": "weekly_scoped" },
                      { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "id": "x" } } },
                      { "kind": "weekly_scoped", "percent": "high",
                        "scope": { "model": { "display_name": "Haiku" } } } ] }
        """.utf8)
        #expect(try decoder.decode(junk, fetchedAt: fetchedAt).modelWeekly.isEmpty)
    }

    @Test func isActiveDefaultsToFalseAndPercentIsClamped() throws {
        let json = Data("""
        { "limits": [ { "kind": "weekly_scoped", "percent": 140,
                        "scope": { "model": { "display_name": "Opus" } } } ] }
        """.utf8)
        let limit = try #require(try decoder.decode(json, fetchedAt: fetchedAt).modelWeekly.first)
        #expect(limit.isActive == false)
        #expect(limit.bucket.utilization == 100)
        #expect(limit.bucket.resetsAt == nil)
    }

    @Test func dropdownRowsListModelWeeklyAfterWeeklyWithActiveFlag() throws {
        let snap = try decoder.decode(observed, fetchedAt: fetchedAt)
        #expect(snap.allBuckets.map(\.title) == ["Session (5h)", "Weekly", "Weekly · Fable"])
        #expect(snap.allBuckets.map(\.isActive) == [false, false, true])
    }

    @Test func legacyPerModelKeysAreSkippedWhenLimitsCarryTheSameModel() throws {
        let json = Data("""
        {
          "seven_day": { "utilization": 10 },
          "seven_day_opus": { "utilization": 30 },
          "seven_day_sonnet": { "utilization": 5 },
          "limits": [ { "kind": "weekly_scoped", "percent": 31,
                        "scope": { "model": { "display_name": "opus" } }, "is_active": true } ]
        }
        """.utf8)
        let snap = try decoder.decode(json, fetchedAt: fetchedAt)
        // "opus" from limits wins over the legacy seven_day_opus; sonnet stays.
        #expect(snap.allBuckets.map(\.title) == ["Weekly", "Weekly · opus", "Weekly · Sonnet"])
        #expect(snap.allBuckets[1].bucket.utilization == 31)
        #expect(snap.gauges.map(\.label) == ["Weekly", "opus", "Sonnet"])
    }

    @Test func widgetGaugesIncludeTheModelWeeklyRing() throws {
        let snap = try decoder.decode(observed, fetchedAt: fetchedAt)
        #expect(snap.gauges.map(\.label) == ["Session", "Weekly", "Fable"])
        #expect(snap.gauges.last?.percentLeft == 32)
    }

    @Test func mostConstrainedConsidersModelWeeklyLimits() throws {
        let snap = try decoder.decode(observed, fetchedAt: fetchedAt)
        #expect(snap.mostConstrained?.utilization == 68)
    }

    @Test func menuBarPrimaryStaysOnTheSession() throws {
        let snap = try decoder.decode(observed, fetchedAt: fetchedAt)
        #expect(snap.primary?.utilization == 17)
    }
}
