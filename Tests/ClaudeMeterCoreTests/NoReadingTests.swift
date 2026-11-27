@testable import ClaudeMeterCore
import Testing

struct NoReadingTests {
    @Test func withoutAnErrorItIsStillLoading() {
        let state = NoReading(errorMessage: nil)
        #expect(state == .loading)
        #expect(state.glyph == "…")
        #expect(!state.isError)
    }

    @Test func anErrorShowsTheWarningGlyph() {
        let state = NoReading(errorMessage: "HTTP 500")
        #expect(state == .failed)
        #expect(state.glyph == "⚠︎")
        #expect(state.isError)
    }
}
