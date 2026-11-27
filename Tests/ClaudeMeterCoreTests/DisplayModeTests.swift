@testable import ClaudeMeterCore
import Testing

struct DisplayModeTests {
    @Test func noStoredModeGetsTheBattery() {
        #expect(DisplayMode.fromStored(nil) == .battery)
    }

    @Test func anExplicitlyPickedModeIsKept() {
        #expect(DisplayMode.fromStored("classic") == .classic)
        #expect(DisplayMode.fromStored("pet") == .pet)
        #expect(DisplayMode.fromStored("battery") == .battery)
    }

    @Test func theLegacyPercentageKeyIsClassic() {
        #expect(DisplayMode.fromStored("percentage") == .classic)
    }

    @Test func anUnknownValueFallsBackToTheBattery() {
        #expect(DisplayMode.fromStored("sparkles") == .battery)
        #expect(DisplayMode.fromStored("") == .battery)
    }
}
