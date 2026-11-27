import ClaudeMeterCore
import SwiftUI

/// The shared `ToolPalette` brand colours as SwiftUI colours (the widget can't see
/// the app target's `ToolColor.swift`).
extension Color {
    init(tool: AgentTool) {
        let rgb = ToolPalette.rgb(for: tool)
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
