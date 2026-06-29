import Foundation

/// A command the widget asks the app to perform. The sandboxed widget cannot
/// write the app's armed store directly, so it appends a command to a file in
/// its own container that the (non-sandboxed) app drains and applies.
public struct WidgetCommand: Equatable, Sendable, Codable {
    public enum Action: String, Equatable, Sendable, Codable {
        case arm
        case disarm
    }

    public let action: Action
    public let sessionID: String

    public init(action: Action, sessionID: String) {
        self.action = action
        self.sessionID = sessionID
    }
}

/// A persisted list of pending widget commands.
public struct WidgetCommandBatch: Equatable, Sendable, Codable {
    public var commands: [WidgetCommand]
    public init(commands: [WidgetCommand]) { self.commands = commands }
}
