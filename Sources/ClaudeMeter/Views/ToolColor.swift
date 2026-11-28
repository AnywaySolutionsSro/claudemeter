import AppKit
import ClaudeMeterCore
import SwiftUI

/// SwiftUI / AppKit forms of the shared `ToolPalette` brand colours.
extension Color {
    init(tool: AgentTool) {
        let rgb = ToolPalette.rgb(for: tool)
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

extension NSColor {
    convenience init(tool: AgentTool) {
        let rgb = ToolPalette.rgb(for: tool)
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
