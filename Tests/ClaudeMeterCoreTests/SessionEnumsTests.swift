import Testing
@testable import ClaudeMeterCore

@Suite struct SessionEnumsTests {
    @Test func originRoundTripsRawValue() {
        #expect(SessionOrigin(rawValue: "cli") == .cli)
        #expect(SessionOrigin(rawValue: "desktop") == .desktop)
        #expect(SessionOrigin.allCases.count == 2)
    }

    @Test func runningStateRoundTripsRawValue() {
        #expect(RunningState(rawValue: "running") == .running)
        #expect(RunningState(rawValue: "idle") == .idle)
    }
}
