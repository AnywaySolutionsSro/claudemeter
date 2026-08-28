@testable import ClaudeMeterCore
import Testing

struct TokenBreakdownTests {
    @Test func totalExcludesCacheRead() {
        let t = TokenBreakdown(input: 100, output: 20, cacheCreation: 5, cacheRead: 9_000)
        #expect(t.total == 125)
    }

    @Test func additionSumsEveryField() {
        let a = TokenBreakdown(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        let b = TokenBreakdown(input: 10, output: 20, cacheCreation: 30, cacheRead: 40)
        #expect(a + b == TokenBreakdown(input: 11, output: 22, cacheCreation: 33, cacheRead: 44))
    }

    @Test func zeroIsAdditiveIdentity() {
        let a = TokenBreakdown(input: 7, output: 8, cacheCreation: 9, cacheRead: 10)
        #expect(a + .zero == a)
    }

    @Test func defaultsAreZero() {
        #expect(TokenBreakdown() == .zero)
    }
}
