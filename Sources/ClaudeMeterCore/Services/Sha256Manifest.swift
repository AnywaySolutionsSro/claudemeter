import CryptoKit
import Foundation

/// SHA-256 helpers for the `ClaudeMeter.zip.sha256` manifest that the release
/// pipeline publishes next to the archive (`shasum -a 256` output).
public enum Sha256Manifest {
    /// Lower-case hex digest of `data`.
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest listed for `fileName` in shasum-style text (`<hex>  <name>` or
    /// `<hex> *<name>`, one file per line), lower-cased; `nil` if absent or malformed.
    public static func digest(in text: String, for fileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            var name = fields[1]
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == fileName else { continue }
            let hex = fields[0].lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { continue }
            return hex
        }
        return nil
    }

    /// Whether `data` hashes to `expected` (case-insensitive hex).
    public static func matches(expected: String, data: Data) -> Bool {
        hexDigest(of: data) == expected.lowercased()
    }
}
