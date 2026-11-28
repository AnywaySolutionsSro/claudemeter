import Foundation

/// Reads JSONL transcript files: whole, from a byte offset (incremental scans),
/// or just the first line. Shared by the Claude and Codex transcript sources.
enum TranscriptFileReader {
    /// Raw lines of a transcript; `[]` on any read failure.
    static func lines(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return splitLines(data)
    }

    /// Complete lines appended at/after `offset` (a partial trailing line is left
    /// unconsumed). `nil` on read failure or when the offset is past the end of
    /// the file (truncation/rewrite — the caller restarts from 0).
    static func chunk(of url: URL, fromByteOffset offset: Int64) -> TranscriptChunk? {
        guard offset >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), offset <= size else { return nil }
        guard offset < size else { return TranscriptChunk(lines: [], endOffset: offset) }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        // Consume only up to the final newline; a partial trailing line (a write
        // in flight) stays unread until it is completed by a later append.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return TranscriptChunk(lines: [], endOffset: offset)
        }
        let complete = data[data.startIndex ... lastNewline]
        return TranscriptChunk(
            lines: splitLines(Data(complete)),
            endOffset: offset + Int64(complete.count),
        )
    }

    /// The first line of a file, read in blocks so a multi-MB transcript is not
    /// loaded whole. `nil` when unreadable or when no newline appears within
    /// `maxBytes` (a first line that long is not one we want to parse anyway).
    static func firstLine(of url: URL, maxBytes: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < maxBytes {
            guard let block = try? handle.read(upToCount: 64 * 1024), !block.isEmpty else { break }
            buffer.append(block)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return splitLines(Data(buffer[buffer.startIndex ..< newline])).first ?? ""
            }
        }
        guard !buffer.isEmpty, buffer.count < maxBytes else { return nil }
        return splitLines(buffer).first
    }

    /// Split JSONL bytes on `\n` (tolerating `\r\n`), decoding each line as UTF-8.
    /// Byte splitting avoids the CharacterSet scan and the 2-3x transient String
    /// peak of `components(separatedBy: .newlines)` on multi-MB transcripts.
    static func splitLines(_ data: Data) -> [String] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { slice -> String in
                var slice = slice
                if slice.last == UInt8(ascii: "\r") { slice = slice.dropLast() }
                // Lossy on purpose: a transcript line with a bad byte still parses.
                return String(decoding: slice, as: UTF8.self)
            }
        // Drop a single trailing empty line (the common case of a file ending
        // in a newline), but keep genuinely empty intermediate lines.
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
