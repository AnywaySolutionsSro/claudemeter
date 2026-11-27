import Foundation

/// Chooses between the live ChatGPT usage reading and the newest transcript reading.
/// Both are the same `CodexLimitReading`, so everything downstream is unaware of the source.
public enum CodexLimitSource {
    /// A live reading younger than this needs no "as of".
    public static let liveFreshness: TimeInterval = 2 * 60

    /// The newer reading by `observedAt`; a tie goes to the live one.
    public static func pick(live: CodexLimitReading?, transcript: CodexLimitReading?) -> CodexLimitReading? {
        guard let live else { return transcript }
        guard let transcript else { return live }
        return transcript.observedAt > live.observedAt ? transcript : live
    }

    /// Whether the reading on screen is the live one and still fresh, so its age is noise.
    public static func isFreshLive(_ live: CodexLimitReading?, shown: CodexLimitReading?, now: Date) -> Bool {
        guard let live, let shown, live == shown else { return false }
        return now.timeIntervalSince(live.observedAt) < liveFreshness
    }
}
