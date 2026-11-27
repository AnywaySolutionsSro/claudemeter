import ClaudeMeterCore
import Foundation

/// Drives the ChatGPT sign-in for live Codex limits and caches what the UI shows, so no
/// view ever touches the Keychain: `state` comes from a metadata-only check, and the
/// email (display only, not a secret) is kept in UserDefaults.
@MainActor
final class ChatGPTAuthModel: ObservableObject {
    enum State: Equatable {
        case signedOut
        case waitingForBrowser
        case signedIn
    }

    @Published private(set) var state: State
    @Published private(set) var email: String?
    @Published private(set) var errorMessage: String?

    var onSignedIn: (() -> Void)?
    var onSignedOut: (() -> Void)?

    static let emailKey = "chatGPTAccountEmail"

    private let account: ChatGPTAccountStore
    private let login: ChatGPTLoginService
    private let defaults: UserDefaults

    init(account: ChatGPTAccountStore, login: ChatGPTLoginService? = nil, defaults: UserDefaults = .standard) {
        self.account = account
        self.login = login ?? ChatGPTLoginService()
        self.defaults = defaults
        let signedIn = account.exists
        self.state = signedIn ? .signedIn : .signedOut
        self.email = signedIn ? defaults.string(forKey: Self.emailKey) : nil
        account.onSignedOut = { [weak self] in
            Task { @MainActor in self?.sessionExpired() }
        }
    }

    var isSignedIn: Bool { state == .signedIn }

    func beginLogin() {
        guard state != .waitingForBrowser else { return }
        errorMessage = nil
        state = .waitingForBrowser
        Task { await runLogin() }
    }

    private func runLogin() async {
        do {
            let tokens = try await login.signIn()
            try account.save(tokens)
            defaults.set(tokens.email, forKey: Self.emailKey)
            email = tokens.email
            errorMessage = nil
            state = .signedIn
            ChatGPTAccountStore.log.notice("chatgpt: signed in")
            onSignedIn?()
        } catch is CancellationError {
            // cancel() already reset the state.
        } catch {
            ChatGPTAccountStore.log.notice("chatgpt: sign-in failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "ChatGPT sign-in failed. Please try again."
            state = account.exists ? .signedIn : .signedOut
        }
    }

    func cancel() {
        login.cancel()
        errorMessage = nil
        state = account.exists ? .signedIn : .signedOut
    }

    func signOut() {
        account.clear()
        forget(message: nil)
        ChatGPTAccountStore.log.notice("chatgpt: signed out")
    }

    /// The grant is dead server-side: drop it and say so, so the user sees "sign in
    /// again" rather than limits that silently stopped being live.
    func sessionExpired() {
        guard state == .signedIn else { return }
        account.clear()
        forget(message: ChatGPTError.sessionExpired.errorDescription)
        ChatGPTAccountStore.log.notice("chatgpt: session expired — signed out")
    }

    private func forget(message: String?) {
        defaults.removeObject(forKey: Self.emailKey)
        email = nil
        errorMessage = message
        state = .signedOut
        onSignedOut?()
    }
}
