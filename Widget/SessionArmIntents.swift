import AppIntents
import ClaudeMeterCore
import Foundation
import WidgetKit

/// Widget command inbox: the widget's own container Documents, the same path
/// `Provider.loadEntry()` reads `snapshot.json` from. Matches the app's
/// `ArmedSessions.commandInboxURL()`.
private func widgetCommandURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("widget-commands.json")
}

private func queue(_ command: WidgetCommand) throws {
    try ArmedSessionsStore().appendCommand(command, to: widgetCommandURL())
    WidgetCenter.shared.reloadAllTimelines()
}

/// Tapped from the widget to ARM a session. The sandboxed widget can't write the
/// app's armed store, so it appends a request the app drains, re-validates
/// (iTerm2 + running), and applies on its next scan.
struct ArmSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm Session"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Session ID") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        try queue(WidgetCommand(action: .arm, sessionID: sessionID))
        return .result()
    }
}

/// Tapped from the widget to DISARM a session.
struct DisarmSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Disarm Session"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Session ID") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        try queue(WidgetCommand(action: .disarm, sessionID: sessionID))
        return .result()
    }
}
