/// Whether a session is believed to still be live.
public enum RunningState: String, Sendable, Codable {
    case running
    case idle
}
