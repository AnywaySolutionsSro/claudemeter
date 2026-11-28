@testable import ClaudeMeterCore
import Testing

struct ToolPaletteTests {
    @Test func brandColours() {
        #expect(ToolPalette.hex(for: .claude) == 0xD97757)
        #expect(ToolPalette.hex(for: .codex) == 0x10A37F)
    }

    @Test func componentsAreUnitRGB() {
        let codex = ToolPalette.rgb(for: .codex)
        #expect(abs(codex.red - Double(0x10) / 255) < 1e-9)
        #expect(abs(codex.green - Double(0xA3) / 255) < 1e-9)
        #expect(abs(codex.blue - Double(0x7F) / 255) < 1e-9)
    }

    @Test func displayNames() {
        #expect(ToolPalette.name(for: .claude) == "Claude")
        #expect(ToolPalette.name(for: .codex) == "Codex")
    }
}
