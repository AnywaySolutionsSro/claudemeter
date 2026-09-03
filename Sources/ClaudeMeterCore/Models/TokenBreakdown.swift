import Foundation

/// Token counts for a single message or an aggregate of messages.
///
/// `total` deliberately excludes `cacheRead`: cache-read tokens repeat the cached
/// prefix on every turn, so summing them across a session inflates the number into
/// the millions and misrepresents real consumption.
public struct TokenBreakdown: Equatable, Sendable, Codable {
    public let input: Int
    public let output: Int
    public let cacheCreation: Int
    public let cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheCreation }

    public static let zero = TokenBreakdown()

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
        )
    }

    public static func - (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input - rhs.input,
            output: lhs.output - rhs.output,
            cacheCreation: lhs.cacheCreation - rhs.cacheCreation,
            cacheRead: lhs.cacheRead - rhs.cacheRead,
        )
    }

    public static func += (lhs: inout TokenBreakdown, rhs: TokenBreakdown) {
        lhs = lhs + rhs
    }
}
