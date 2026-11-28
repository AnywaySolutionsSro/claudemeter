@testable import ClaudeMeterCore
import Foundation
import Testing

struct JSONShapeTests {
    @Test func describesKeyPathsAndTypesWithoutValues() {
        let json = """
        {"plan_type":"secret-plan","rate_limit":{"allowed":true,"primary_window":{"used_percent":12.5},
         "secondary_window":null},"items":[{"a":1},{"b":"x"}],"empty":[],"n":3}
        """
        let lines = JSONShape.describe(Data(json.utf8))
        #expect(lines == [
            "empty: array(0)",
            "items: array(2)",
            "items[]: object",
            "items[].a: number",
            "items[].b: string",
            "n: number",
            "plan_type: string",
            "rate_limit: object",
            "rate_limit.allowed: bool",
            "rate_limit.primary_window: object",
            "rate_limit.primary_window.used_percent: number",
            "rate_limit.secondary_window: null",
        ])
        #expect(!lines.joined().contains("secret-plan"))
    }

    @Test func topLevelArraysAndJunk() {
        #expect(JSONShape.describe(Data("[1,2]".utf8)) == ["$: array(2)", "[]: number"])
        #expect(JSONShape.describe(Data("nope".utf8)) == ["(not JSON)"])
    }
}
