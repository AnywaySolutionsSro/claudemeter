@testable import ClaudeMeterCore
import Testing

/// What to do around a refresh when another process (`--codex-usage-dump`, a second
/// app instance) may have rotated the refresh token in the shared Keychain item.
struct ChatGPTRotationTests {
    @Test func deadGrantWithARotatedStoredTokenRetriesWithIt() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: "rt1") == .retry)
    }

    @Test func deadGrantWithTheSameStoredTokenSignsOut() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: "rt0") == .signOut)
    }

    @Test func deadGrantAfterASignOutStaysSignedOut() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: nil) == .signedOut)
    }

    @Test func refreshIsSavedOnlyOverTheGrantItRenewed() {
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: "rt0") == .save)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: "rtNew") == .superseded)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: nil) == .signedOut)
    }
}
