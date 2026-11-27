@testable import ClaudeMeterCore
import Testing

/// Refresh-token rotation decisions. The Keychain item is shared by every ClaudeMeter
/// process and OpenAI rotates the refresh token on each refresh, so a rotated token must
/// never be lost: not to another process, not to a failed Keychain write, not to a read error.
struct ChatGPTRotationTests {
    private func found(_ token: String, valid: Bool = false) -> ChatGPTRotation.Stored {
        .found(refreshToken: token, accessValid: valid)
    }

    // MARK: before a refresh

    @Test func aStoredTokenStillValidIsUsedWithoutRefreshing() {
        #expect(ChatGPTRotation.beforeRefresh(memory: "rt0", stored: found("rt0", valid: true),
                                              pendingWrite: false, force: false) == .useStored)
    }

    @Test func expiredStoredTokenIsRefreshed() {
        #expect(ChatGPTRotation.beforeRefresh(memory: "rt0", stored: found("rt0"),
                                              pendingWrite: false, force: false) == .refreshStored)
    }

    @Test func forcedRefreshUsesAValidTokenRotatedElsewhere() {
        // E: another process already refreshed; don't spend its token again.
        #expect(ChatGPTRotation.beforeRefresh(memory: "rt0", stored: found("rt1", valid: true),
                                              pendingWrite: false, force: true) == .useStored)
        #expect(ChatGPTRotation.beforeRefresh(memory: "rt0", stored: found("rt0", valid: true),
                                              pendingWrite: false, force: true) == .refreshStored)
    }

    @Test func pendingWriteKeepsMemoryAuthoritative() {
        // B: the item still holds the spent token A; memory holds B.
        #expect(ChatGPTRotation.beforeRefresh(memory: "rtB", stored: found("rtA", valid: true),
                                              pendingWrite: true, force: false) == .refreshMemory)
        #expect(!ChatGPTRotation.mayReplaceMemory(pendingWrite: true))
        #expect(ChatGPTRotation.mayReplaceMemory(pendingWrite: false))
    }

    @Test func unreadableItemFallsBackToMemory() {
        // C: a read error is not a sign-out.
        #expect(ChatGPTRotation.beforeRefresh(memory: "rt0", stored: .unreadable,
                                              pendingWrite: false, force: false) == .refreshMemory)
        #expect(ChatGPTRotation.beforeRefresh(memory: nil, stored: .unreadable,
                                              pendingWrite: false, force: false) == .backOff)
    }

    @Test func missingItemIsSignedOut() {
        #expect(ChatGPTRotation.beforeRefresh(memory: "rt0", stored: .missing,
                                              pendingWrite: false, force: false) == .signedOut)
    }

    // MARK: after a successful refresh

    @Test func refreshIsSavedOverTheGrantItRenewed() {
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: found("rt0"), pendingWrite: false) == .save)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: found("rtNew"), pendingWrite: false) == .superseded)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: .missing, pendingWrite: false) == .signedOut)
    }

    @Test func refreshIsSavedWhenTheItemCantBeRead() {
        // C: the old token is spent; dropping the new one would lose the login.
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: .unreadable, pendingWrite: false) == .save)
    }

    @Test func refreshIsSavedOverOurOwnUnwrittenToken() {
        // B: the item is stale only because our write failed.
        #expect(ChatGPTRotation.afterRefresh(used: "rtB", stored: found("rtA"), pendingWrite: true) == .save)
    }

    // MARK: after a dead grant

    @Test func deadGrantWithAValidRotatedTokenAdoptsIt() {
        // E
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: found("rt1", valid: true),
                                               pendingWrite: false, canRetry: true) == .adopt)
    }

    @Test func deadGrantWithAnExpiredRotatedTokenRetriesOnce() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: found("rt1"),
                                               pendingWrite: false, canRetry: true) == .retry)
    }

    @Test func deadGrantWithoutRetryBudgetNeverClearsARotatedToken() {
        // D
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: found("rt1"),
                                               pendingWrite: false, canRetry: false) == .superseded)
    }

    @Test func deadGrantOfTheStoredTokenSignsOut() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: found("rt0"),
                                               pendingWrite: false, canRetry: true) == .signOut)
    }

    @Test func deadGrantOfOurUnwrittenTokenSignsOut() {
        // The stale item holds a token we already spent; nothing newer exists.
        #expect(ChatGPTRotation.afterDeadGrant(used: "rtB", stored: found("rtA"),
                                               pendingWrite: true, canRetry: true) == .signOut)
    }

    @Test func deadGrantWithAnUnreadableItemBacksOff() {
        // C: never clear (or stop) on a read error.
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: .unreadable,
                                               pendingWrite: false, canRetry: true) == .backOff)
    }

    @Test func deadGrantAfterASignOutStaysSignedOut() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: .missing,
                                               pendingWrite: false, canRetry: true) == .signedOut)
    }
}
