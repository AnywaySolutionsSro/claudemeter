import Foundation
import Network

/// A throwaway localhost HTTP server that captures the OAuth redirect automatically, so the
/// user never has to copy/paste a code. Anthropic's OAuth client permits a loopback
/// `http://localhost:<port>/callback` redirect (the same flow Claude Code's browser login uses).
///
/// Bound to the IPv4 loopback address only (RFC 8252 §8.3) — never to every interface —
/// and a redirect is accepted only when its `state` matches the one this login sent. Any
/// other request gets an error page and the listener keeps waiting for the real redirect.
final class LoopbackCallbackServer: @unchecked Sendable {
    /// How long the browser gets before the login is abandoned and the socket closed.
    static let defaultTimeout: TimeInterval = 10 * 60

    private let queue = DispatchQueue(label: "com.jakubzak.claudemeter.loopback")
    private var listener: NWListener?
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var bufferedResult: [String: String]?
    private var didResumePort = false
    private var didDeliver = false
    private var timeout: DispatchWorkItem?

    /// The `state` this login sent to the authorization server; set before the browser
    /// opens. A redirect carrying anything else is ignored.
    var expectedState: String? {
        get { queue.sync { _expectedState } }
        set { queue.sync { _expectedState = newValue } }
    }

    private var _expectedState: String?

    /// The redirect's path (e.g. `/auth/callback`); `nil` accepts any path, as the
    /// Claude login always has. Set before `start`.
    var expectedPath: String? {
        get { queue.sync { _expectedPath } }
        set { queue.sync { _expectedPath = newValue } }
    }

    private var _expectedPath: String?
    private var isFixedPort = false

    /// Starts listening and returns the bound port: an OS-assigned ephemeral one by
    /// default, or exactly `port` (no address reuse, so a port another login already
    /// holds fails with `EADDRINUSE` instead of being shared).
    func start(port: UInt16? = nil) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    self.isFixedPort = port != nil
                    parameters.allowLocalEndpointReuse = port == nil
                    let fixed = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: fixed)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.portContinuation = continuation
                    listener.newConnectionHandler = { [weak self] in self?.handle($0) }
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state, listener: listener)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Resolves when the browser redirects back with the authorization code; throws
    /// `CancellationError` on `stop()` and `AuthError.timedOut` after `timeout`.
    func waitForCallback(timeout: TimeInterval = LoopbackCallbackServer.defaultTimeout) async throws
        -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let buffered = self.bufferedResult {
                    self.bufferedResult = nil
                    continuation.resume(returning: buffered)
                    return
                }
                self.callbackContinuation = continuation
                let expiry = DispatchWorkItem { [weak self] in self?.finish(throwing: AuthError.timedOut) }
                self.timeout = expiry
                self.queue.asyncAfter(deadline: .now() + timeout, execute: expiry)
            }
        }
    }

    func stop() {
        queue.async { self.finish(throwing: CancellationError()) }
    }

    /// Close the socket and fail a pending wait. Queue-confined.
    private func finish(throwing error: Error) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Private

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            guard !didResumePort, let port = listener.port?.rawValue else { return }
            didResumePort = true
            portContinuation?.resume(returning: port)
            portContinuation = nil
        case let .waiting(error) where isFixedPort:
            // A busy fixed port can surface as `.waiting` rather than `.failed`.
            failBeforeReady(error, listener: listener)
        case let .failed(error):
            failBeforeReady(error, listener: listener)
        default:
            break
        }
    }

    private func failBeforeReady(_ error: Error, listener: NWListener) {
        guard !didResumePort else { return }
        didResumePort = true
        listener.cancel()
        portContinuation?.resume(throwing: error)
        portContinuation = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }

            let requestText = data.flatMap { String(data: $0, encoding: .utf8) }
            let query = requestText.flatMap(Self.parseQuery)
            let pathMatches = self._expectedPath.map { requestText.flatMap(Self.parsePath) == $0 } ?? true
            let accepted = !self.didDeliver
                && pathMatches
                && query?["code"] != nil
                && query?["state"] != nil
                && query?["state"] == self._expectedState

            let html = accepted
                ? """
                <!doctype html><meta charset="utf-8">
                <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:64px;color:#333">
                <h2 style="color:#D4673F">ClaudeMeter connected</h2>
                <p>You can close this tab and return to the menu bar.</p></body>
                """
                : """
                <!doctype html><meta charset="utf-8">
                <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:64px;color:#333">
                <h2>Not a valid ClaudeMeter sign-in</h2>
                <p>Start the sign-in again from the ClaudeMeter menu bar.</p></body>
                """
            let response = """
            HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if accepted, let query {
                self.didDeliver = true
                self.deliver(query)
            }
        }
    }

    private func deliver(_ query: [String: String]) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(returning: query)
        } else {
            bufferedResult = query
        }
    }

    /// The request line's path, without its query.
    static func parsePath(_ request: String) -> String? {
        guard let requestLine = request.split(separator: "\r\n").first else { return nil }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        return URLComponents(string: "http://localhost\(tokens[1])")?.path
    }

    static func parseQuery(_ request: String) -> [String: String]? {
        guard let requestLine = request.split(separator: "\r\n").first else { return nil }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2,
              let components = URLComponents(string: "http://localhost\(tokens[1])"),
              let items = components.queryItems else { return nil }

        return Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first },
        )
    }
}
