import Foundation
import AppKit
import SwiftUI

/// Drives the sign-in flow and exposes auth state to the UI. Owns no tokens itself — those
/// live in `AccountStore` (the app's own Keychain item).
///
/// Primary flow is fully automatic: a localhost server captures the OAuth redirect, so the
/// user only approves in the browser. A manual copy/paste flow remains as a fallback.
@MainActor
final class AuthModel: ObservableObject {
    enum State: Equatable {
        case signedOut
        case waitingForBrowser   // automatic loopback flow
        case awaitingCode        // manual paste fallback
        case connecting
        case signedIn
    }

    @Published private(set) var state: State
    @Published var pastedCode: String = ""
    @Published private(set) var errorMessage: String?

    var onSignedIn: (() -> Void)?
    var onSignedOut: (() -> Void)?

    private let account: AccountStore
    private let login = OAuthLoginService()
    private var pending: OAuthLoginService.Request?
    private var server: LoopbackCallbackServer?

    init(account: AccountStore) {
        self.account = account
        self.state = account.isAuthenticated ? .signedIn : .signedOut
    }

    var isSignedIn: Bool { state == .signedIn }

    // MARK: - Automatic flow

    func beginLogin() {
        errorMessage = nil
        state = .waitingForBrowser
        Task { await runAutomaticLogin() }
    }

    private func runAutomaticLogin() async {
        let server = LoopbackCallbackServer()
        self.server = server
        defer { server.stop(); self.server = nil }

        do {
            let port = try await server.start()
            let request = login.makeRequest(redirectURI: "http://localhost:\(port)/callback")
            pending = request
            NSWorkspace.shared.open(request.url)

            let query = try await server.waitForCallback()
            guard let code = query["code"] else { throw AuthError.invalidResponse }
            if let returnedState = query["state"], returnedState != request.state {
                throw AuthError.invalidResponse
            }
            try await completeLogin(code: code, request: request)
        } catch is CancellationError {
            // User cancelled; state already reset by cancel().
        } catch {
            present(error)
            state = .signedOut
        }
    }

    // MARK: - Manual fallback

    func beginManualLogin() {
        errorMessage = nil
        let request = login.makeRequest(redirectURI: AuthEndpoints.redirectURI)
        pending = request
        NSWorkspace.shared.open(request.url)
        state = .awaitingCode
    }

    func submitCode() {
        guard let pending, !pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let code = pastedCode
        state = .connecting
        errorMessage = nil
        Task {
            do {
                try await completeLogin(code: code, request: pending)
            } catch {
                present(error)
                state = .awaitingCode
            }
        }
    }

    // MARK: - Shared

    private func completeLogin(code: String, request: OAuthLoginService.Request) async throws {
        let tokens = try await login.exchange(code: code, request: request)
        try account.save(tokens)
        pending = nil
        pastedCode = ""
        errorMessage = nil
        state = .signedIn
        onSignedIn?()
    }

    func cancel() {
        server?.stop()
        server = nil
        pending = nil
        pastedCode = ""
        errorMessage = nil
        state = account.isAuthenticated ? .signedIn : .signedOut
    }

    func signOut() {
        account.clear()
        pastedCode = ""
        errorMessage = nil
        state = .signedOut
        onSignedOut?()
    }

    /// The stored grant was rejected server-side and can never refresh again. Drop the dead
    /// tokens and land on the signed-out UI with an explanation, so the user sees "sign in
    /// again" instead of a permanently stale reading.
    func sessionExpired() {
        guard state == .signedIn else { return }
        account.clear()
        pastedCode = ""
        errorMessage = "Your login session expired. Please sign in again."
        state = .signedOut
        onSignedOut?()
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sign-in failed. Please try again."
    }
}
