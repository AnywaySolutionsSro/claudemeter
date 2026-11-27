import Foundation

/// What a signed-in menu-bar label shows before it has a usage reading: "…" while the
/// first reading loads, a red "⚠︎" once fetching failed. (Not connected at all is a
/// different state — the "Sign in" pill, or "—" in a battery cell.)
public enum NoReading: Equatable, Sendable {
    case loading
    case failed

    public init(errorMessage: String?) {
        self = errorMessage == nil ? .loading : .failed
    }

    public var glyph: String {
        switch self {
        case .loading: "…"
        case .failed: "⚠︎"
        }
    }

    /// Drawn in red.
    public var isError: Bool { self == .failed }
}
