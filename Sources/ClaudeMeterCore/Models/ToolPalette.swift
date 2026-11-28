/// Brand colour and display name per agent tool, shared by the app and the widget
/// so Claude and Codex are told apart the same way everywhere they appear together.
public enum ToolPalette {
    /// `0xRRGGBB`: Claude `#D97757`, Codex `#10A37F`.
    public static func hex(for tool: AgentTool) -> UInt32 {
        switch tool {
        case .claude: 0xD97757
        case .codex: 0x10A37F
        }
    }

    /// The brand colour as unit RGB components, ready for `Color` / `NSColor`.
    public static func rgb(for tool: AgentTool) -> RGB {
        let hex = hex(for: tool)
        return RGB(red: Double((hex >> 16) & 0xFF) / 255,
                   green: Double((hex >> 8) & 0xFF) / 255,
                   blue: Double(hex & 0xFF) / 255)
    }

    /// Unit (0…1) sRGB components.
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    public static func name(for tool: AgentTool) -> String {
        switch tool {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
