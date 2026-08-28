@testable import ClaudeMeterCore
import XCTest

final class PersonalityTests: XCTestCase {
    func testMoodDegradesAsBudgetDrains() {
        XCTAssertEqual(Personality.moodEmoji(remaining: 90), "😎")
        XCTAssertEqual(Personality.moodEmoji(remaining: 50), "🙂")
        XCTAssertEqual(Personality.moodEmoji(remaining: 20), "😬")
        XCTAssertEqual(Personality.moodEmoji(remaining: 10), "🥵")
        XCTAssertEqual(Personality.moodEmoji(remaining: 2), "💀")
    }

    func testPetSleepsWhenEmpty() {
        XCTAssertEqual(Personality.petState(remaining: 90), .happy)
        XCTAssertEqual(Personality.petState(remaining: 2), .asleep)
        XCTAssertEqual(Personality.petEmoji(.asleep), "😴")
        XCTAssertEqual(Personality.petEmoji(.happy), "😺")
    }
}
