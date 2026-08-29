import Foundation

/// Decodes GitHub's `GET /repos/{owner}/{repo}/releases/latest` JSON into a
/// `ReleaseInfo`. Lenient, key-by-key (like `UsageResponseDecoder`): unknown keys are
/// ignored, and anything that doesn't carry the essentials — a plain `vMM.mm.pp` tag,
/// a release page and a `ClaudeMeter.zip` asset — yields `nil` rather than an error.
/// Drafts and pre-releases are refused defensively even though the endpoint
/// shouldn't return them.
public struct ReleaseDecoder: Sendable {
    public static let archiveName = "ClaudeMeter.zip"
    public static let checksumName = "ClaudeMeter.zip.sha256"

    public init() {}

    public func decode(_ data: Data) -> ReleaseInfo? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (root["draft"] as? Bool) != true,
            (root["prerelease"] as? Bool) != true,
            let tag = root["tag_name"] as? String,
            let version = AppVersion(tag),
            let pageURL = (root["html_url"] as? String).flatMap(URL.init(string:)),
            let assets = root["assets"] as? [Any]
        else {
            return nil
        }

        let byName = assets.reduce(into: [String: (url: URL, size: Int?)]()) { table, entry in
            guard
                let asset = entry as? [String: Any],
                let name = asset["name"] as? String,
                let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            else {
                return
            }
            table[name] = (url, (asset["size"] as? NSNumber)?.intValue)
        }
        guard let archive = byName[Self.archiveName] else { return nil }

        return ReleaseInfo(
            version: version,
            tagName: tag,
            pageURL: pageURL,
            archiveURL: archive.url,
            checksumURL: byName[Self.checksumName]?.url,
            archiveSize: archive.size,
            notes: (root["body"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            publishedAt: (root["published_at"] as? String).flatMap(ISODate.parse),
        )
    }
}
