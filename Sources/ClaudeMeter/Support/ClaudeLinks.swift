import AppKit
import Foundation

/// The claude.ai pages ClaudeMeter hands users off to.
///
/// ClaudeMeter never writes to the billing API: enabling extra usage, raising the
/// monthly cap and buying credits all happen on the web. Claude Code itself does the
/// same — every write in its binary only ever turns extra usage *on*, and its own
/// "manage" option opens this page.
enum ClaudeLinks {
    /// Usage & billing: the extra-usage switch, the monthly cap, and credit purchases.
    static let usageSettings = URL(string: "https://claude.ai/settings/usage")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
