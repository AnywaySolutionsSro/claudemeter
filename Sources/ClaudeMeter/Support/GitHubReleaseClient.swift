import ClaudeMeterCore
import Foundation

/// Talks to the public GitHub API for this repository — unauthenticated, one call
/// per daily check, far below the 60 requests/hour anonymous limit — and streams
/// release assets to disk with progress.
struct GitHubReleaseClient: Sendable {
    static let repository = "AnywaySolutionsSro/claudemeter"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    var session: URLSession = .shared
    var userAgent = "ClaudeMeter/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"
    private let decoder = ReleaseDecoder()

    /// The latest published (non-draft, non-prerelease) release, or `nil` when the
    /// response doesn't describe one this app can install.
    func fetchLatest() async throws -> ReleaseInfo? {
        try await fetchRelease(at: Self.latestReleaseURL)
    }

    /// The release published under `tag` (e.g. the running version's own notes);
    /// `nil` when there is none or it isn't a plain release.
    func fetchRelease(tag: String) async throws -> ReleaseInfo? {
        try await fetchRelease(at: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/tags/\(tag)")!)
    }

    private func fetchRelease(at url: URL) async throws -> ReleaseInfo? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.httpStatus(status) }
        return decoder.decode(data)
    }

    /// Small text asset (the `.sha256` manifest).
    func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.httpStatus(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Streams `url` into `destination`, reporting progress in 0...1 (or -1 when the
    /// size is unknown). `expectedSize` (from the release JSON) covers servers that
    /// omit `Content-Length` on redirects.
    func download(
        _ url: URL,
        to destination: URL,
        expectedSize: Int?,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.httpStatus(status) }

        let total: Int64 = response.expectedContentLength > 0
            ? response.expectedContentLength
            : Int64(expectedSize ?? 0)
        // Bound the write before the first byte lands: a hostile or broken release
        // must not be able to fill the disk or feed a zip bomb to `ditto`. The
        // ceiling is absolute — the release JSON's `size` can lag a re-uploaded
        // asset, and a mismatch there is the checksum's job to catch, not this.
        let limit = Self.maxArchiveBytes
        guard total <= limit else { throw UpdateError.archiveTooLarge }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        var received: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.chunkSize {
                    received += Int64(buffer.count)
                    guard received <= limit else { throw UpdateError.archiveTooLarge }
                    try Self.write(buffer, to: handle)
                    buffer.removeAll(keepingCapacity: true)
                    progress(total > 0 ? Double(received) / Double(total) : -1)
                }
            }
            received += Int64(buffer.count)
            guard received <= limit else { throw UpdateError.archiveTooLarge }
            if !buffer.isEmpty { try Self.write(buffer, to: handle) }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        if total > 0, received != total { throw UpdateError.downloadTruncated }
        progress(1)
    }

    /// A local write failure (disk full, permissions) is not a network error and must not
    /// read as one in the banner.
    private static func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw UpdateError.installFailed("couldn't save the download: \(error.localizedDescription)")
        }
    }

    private static let chunkSize = 256 * 1024
    /// Releases are ~10 MB; anything near this is not one of ours.
    private static let maxArchiveBytes: Int64 = 200 * 1024 * 1024
}
