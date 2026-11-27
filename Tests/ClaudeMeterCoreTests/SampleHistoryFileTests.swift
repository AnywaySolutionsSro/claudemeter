@testable import ClaudeMeterCore
import Foundation
import Testing

struct SampleHistoryFileTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleHistoryFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sample = UsageSample(timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                                     sessionUtilization: 12, sessionResetsAt: nil, weeklyUtilization: 30)

    @Test func missingFileIsAnEmptyHistory() throws {
        let file = try SampleHistoryFile(name: "codex-history.json", directory: tempDirectory())
        #expect(file.load().isEmpty)
    }

    @Test func corruptFileIsAnEmptyHistory() throws {
        let directory = try tempDirectory()
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("codex-history.json"))
        #expect(SampleHistoryFile(name: "codex-history.json", directory: directory).load().isEmpty)
    }

    @Test func savedSamplesRoundTripAndRemoveClears() throws {
        let directory = try tempDirectory().appendingPathComponent("nested", isDirectory: true)
        let file = SampleHistoryFile(name: "codex-history.json", directory: directory)
        file.save([sample])
        #expect(file.load() == [sample])
        file.remove()
        #expect(file.load().isEmpty)
    }
}
