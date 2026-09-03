@testable import ClaudeMeterCore
import Foundation
import Testing

/// `Retry-After` may be delay-seconds or an HTTP-date (RFC 9110 §10.2.3). Reading
/// only the integer form silently fell back to a default backoff and re-hit a
/// 429 that had asked for longer.
struct RetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_445_412_480) // 2015-10-21T07:28:00Z

    @Test func parsesDelaySeconds() {
        #expect(RetryAfter.seconds("120", now: now) == 120)
        #expect(RetryAfter.seconds(" 5 ", now: now) == 5)
    }

    @Test func parsesHTTPDate() {
        #expect(RetryAfter.seconds("Wed, 21 Oct 2015 07:30:00 GMT", now: now) == 120)
    }

    @Test func pastDateAndGarbageAreNil() {
        #expect(RetryAfter.seconds("Wed, 21 Oct 2015 07:00:00 GMT", now: now) == nil)
        #expect(RetryAfter.seconds("soon", now: now) == nil)
        #expect(RetryAfter.seconds("-3", now: now) == nil)
    }
}
