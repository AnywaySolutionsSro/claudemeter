@testable import ClaudeMeterCore
import Foundation
import Testing

struct WhamUsageDecoderTests {
    private let now = Date(timeIntervalSince1970: 1_796_000_000)

    private func decode(_ json: String) -> CodexLimitReading? {
        WhamUsageDecoder.decode(Data(json.utf8), observedAt: now)
    }

    /// The shape the Codex binary's serde names describe (`RateLimitStatusPayload`).
    @Test func liveShapeWithBothWindows() throws {
        let reading = try #require(decode("""
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":12,"limit_window_seconds":18000,
            "reset_after_seconds":600,"reset_at":1796000700},
          "secondary_window":{"used_percent":40.5,"limit_window_seconds":604800,"reset_after_seconds":86400}},
         "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
        """))
        #expect(reading.limitID == "codex")
        #expect(reading.observedAt == now)
        #expect(reading.planType == "pro")
        #expect(reading.reachedType == nil)
        #expect(reading.windows == [
            // reset_at (absolute) wins over reset_after_seconds.
            CodexWindowReading(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_796_000_700),
            ),
            CodexWindowReading(usedPercent: 40.5, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
        ])
    }

    @Test func weeklyOnlyAccountHasNullPrimary() throws {
        let reading = try #require(decode("""
        {"rate_limit":{"primary_window":null,
          "secondary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_at":1796100000}}}
        """))
        #expect(reading.windows.map(\.windowMinutes) == [10080])
        #expect(reading.planType == nil)
    }

    @Test func limitReachedMarksTheReading() throws {
        let reached = try #require(decode("""
        {"rate_limit":{"allowed":false,"limit_reached":true,
          "primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_after_seconds":60}}}
        """))
        #expect(reached.reachedType == "limit_reached")
        let typed = try #require(decode("""
        {"rate_limit_reached_type":"workspace_member_usage_limit_reached","rate_limit":{"limit_reached":true,
          "primary_window":{"used_percent":100,"limit_window_seconds":18000}}}
        """))
        #expect(typed.reachedType == "workspace_member_usage_limit_reached")
        let notAllowed = try #require(decode("""
        {"rate_limit":{"allowed":false,"primary_window":{"used_percent":100,"limit_window_seconds":18000}}}
        """))
        #expect(notAllowed.reachedType == "limit_reached")
    }

    /// The transcript's `rate_limits` shape, top-level or nested, decodes the same way.
    @Test func transcriptShapeTopLevelAndNested() throws {
        let window = #"{"used_percent":7,"window_minutes":300,"resets_at":1796001000}"#
        let top = try #require(decode(#"{"limit_id":"codex","primary":\#(window)}"#))
        #expect(top.windows == [
            CodexWindowReading(
                usedPercent: 7,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_796_001_000),
            ),
        ])
        let nested = try #require(decode(#"{"rate_limits":{"primary":\#(window),"secondary":null}}"#))
        #expect(nested.windows == top.windows)
    }

    @Test func isoResetAndStringNumbersAreRead() throws {
        let reading = try #require(decode("""
        {"rate_limit":{"primary_window":{"used_percent":"25","window_minutes":"300",
          "resets_at":"2026-11-30T10:00:00.123456+00:00"}}}
        """))
        let window = try #require(reading.windows.first)
        #expect(window.usedPercent == 25)
        #expect(window.windowMinutes == 300)
        #expect(window.resetsAt == ISODate.parse("2026-11-30T10:00:00+00:00"))
    }

    @Test func unparsableWindowIsDroppedNotZeroed() throws {
        let reading = try #require(decode("""
        {"rate_limit":{"primary_window":{"used_percent":"lots","limit_window_seconds":18000},
          "secondary_window":{"used_percent":5,"limit_window_seconds":604800}}}
        """))
        #expect(reading.windows.map(\.windowMinutes) == [10080])
        let noLength = decode(#"{"rate_limit":{"primary_window":{"used_percent":5}}}"#)
        #expect(noLength == nil)
        let boolPercent = decode(#"{"rate_limit":{"primary_window":{"used_percent":true,"limit_window_seconds":60}}}"#)
        #expect(boolPercent == nil)
        let zeroLength = decode(#"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":0}}}"#)
        #expect(zeroLength == nil)
    }

    @Test func usedPercentZeroIsAReading() throws {
        let reading = try #require(decode(
            #"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}"#,
        ))
        #expect(reading.windows.first?.usedPercent == 0)
    }

    @Test func unknownShapesAreNil() {
        #expect(decode("") == nil)
        #expect(decode("[]") == nil)
        #expect(decode("<html>") == nil)
        #expect(decode(#"{"detail":"Unauthorized"}"#) == nil)
        #expect(decode(#"{"plan_type":"plus"}"#) == nil)
        #expect(decode(#"{"rate_limit":null}"#) == nil)
        #expect(decode(#"{"rate_limit":{"allowed":true}}"#) == nil)
    }

    @Test func secondsRoundToMinutes() throws {
        let reading = try #require(decode(
            #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18029}}}"#,
        ))
        #expect(reading.windows.first?.windowMinutes == 300)
    }
}
