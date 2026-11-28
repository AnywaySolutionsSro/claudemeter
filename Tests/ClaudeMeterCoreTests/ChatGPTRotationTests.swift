@testable import ClaudeMeterCore
import Testing

/// Pure rotation decisions. `staleStored` is the spent refresh token the Keychain item
/// still holds while a write of newer tokens is pending (nil = nothing pending).
struct ChatGPTRotationTests {
    private func found(_ token: String, access: String = "at", valid: Bool = false) -> ChatGPTRotation.Stored {
        .found(refreshToken: token, accessToken: access, accessValid: valid)
    }

    // MARK: reconcile memory with the item

    @Test func withoutAPendingWriteTheItemIsAdopted() {
        #expect(ChatGPTRotation.reconcile(stored: found("rt"), staleStored: nil) == .adoptStored)
        #expect(ChatGPTRotation.reconcile(stored: .missing, staleStored: nil) == .signedOut)
        #expect(ChatGPTRotation.reconcile(stored: .unreadable, staleStored: nil) == .unreadable)
    }

    @Test func withAPendingWriteOnlyOurStaleItemIsOverwritten() {
        #expect(ChatGPTRotation.reconcile(stored: found("rtA"), staleStored: "rtA") == .keepMemoryWritable)
        #expect(ChatGPTRotation.reconcile(stored: .unreadable, staleStored: "rtA") == .keepMemoryUnreadable)
        // M-1: replaced elsewhere → adopt it; deleted by a sign-out elsewhere → don't recreate.
        #expect(ChatGPTRotation.reconcile(stored: found("rtX"), staleStored: "rtA") == .adoptStored)
        #expect(ChatGPTRotation.reconcile(stored: .missing, staleStored: "rtA") == .signedOut)
    }

    // MARK: before a refresh

    @Test func aValidStoredTokenIsUsedUnlessItIsTheRefusedOne() {
        // I-1: compare with the access token the server refused, never with memory.
        let stored = found("rt1", access: "atNew", valid: true)
        #expect(ChatGPTRotation.beforeRefresh(stored: stored, staleStored: nil, hasMemory: true,
                                              refusedAccess: nil) == .useStored)
        #expect(ChatGPTRotation.beforeRefresh(stored: stored, staleStored: nil, hasMemory: true,
                                              refusedAccess: "atOld") == .useStored)
        #expect(ChatGPTRotation.beforeRefresh(stored: stored, staleStored: nil, hasMemory: true,
                                              refusedAccess: "atNew") == .refreshStored)
        #expect(ChatGPTRotation.beforeRefresh(stored: found("rt1"), staleStored: nil, hasMemory: true,
                                              refusedAccess: nil) == .refreshStored)
    }

    @Test func pendingWriteOrUnreadableItemRefreshesMemory() {
        #expect(ChatGPTRotation.beforeRefresh(stored: found("rtA", valid: true), staleStored: "rtA",
                                              hasMemory: true, refusedAccess: nil) == .refreshMemory)
        #expect(ChatGPTRotation.beforeRefresh(stored: .unreadable, staleStored: nil,
                                              hasMemory: true, refusedAccess: nil) == .refreshMemory)
        #expect(ChatGPTRotation.beforeRefresh(stored: .unreadable, staleStored: nil,
                                              hasMemory: false, refusedAccess: nil) == .backOff)
        #expect(ChatGPTRotation.beforeRefresh(stored: .missing, staleStored: "rtA",
                                              hasMemory: true, refusedAccess: nil) == .signedOut)
    }

    // MARK: after a successful refresh

    @Test func refreshIsSavedOnlyOverTheGrantItRenewedOrOurStaleItem() {
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: found("rt0"), staleStored: nil) == .save)
        #expect(ChatGPTRotation.afterRefresh(used: "rtB", stored: found("rtA"), staleStored: "rtA") == .save)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: .unreadable, staleStored: nil) == .save)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: found("rtX"), staleStored: nil) == .superseded)
        #expect(ChatGPTRotation.afterRefresh(used: "rtB", stored: found("rtX"), staleStored: "rtA") == .superseded)
        #expect(ChatGPTRotation.afterRefresh(used: "rt0", stored: .missing, staleStored: "rtA") == .signedOut)
    }

    // MARK: after a dead grant

    @Test func deadGrantSignsOutOnlyForOurOwnTokens() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: found("rt0"), staleStored: nil,
                                               canRetry: true) == .signOut)
        #expect(ChatGPTRotation.afterDeadGrant(used: "rtB", stored: found("rtA"), staleStored: "rtA",
                                               canRetry: true) == .signOut)
    }

    @Test func deadGrantKeepsANewerTokenEvenWithAPendingWrite() {
        // I-2: another process wrote X while our write of B was pending.
        #expect(ChatGPTRotation.afterDeadGrant(used: "rtB", stored: found("rtX", valid: true), staleStored: "rtA",
                                               canRetry: true) == .adopt)
        #expect(ChatGPTRotation.afterDeadGrant(used: "rtB", stored: found("rtX"), staleStored: "rtA",
                                               canRetry: true) == .retry)
        #expect(ChatGPTRotation.afterDeadGrant(used: "rtB", stored: found("rtX"), staleStored: "rtA",
                                               canRetry: false) == .superseded)
    }

    @Test func deadGrantWithAnUnreadableOrMissingItem() {
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: .unreadable, staleStored: nil,
                                               canRetry: true) == .backOff)
        #expect(ChatGPTRotation.afterDeadGrant(used: "rt0", stored: .missing, staleStored: nil,
                                               canRetry: true) == .signedOut)
    }
}
