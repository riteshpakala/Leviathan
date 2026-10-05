//
//  TranscriptStore.swift
//  LeviathonCore
//
//  WHAT: The append-only transcripts.jsonl of one model.
//  PIN:  One line per success, written as it arrives, so a cancelled run loses nothing. Lines
//        that do not decode are reported by number, never dropped silently; a torn last line
//        (a crash mid-write) is the only one tolerated without a newline after it.
//

import Foundation

public actor TranscriptStore {
    public nonisolated let url: URL
    private var writer: JSONLWriter?

    public init(url: URL) {
        self.url = url
    }

    public func append(_ record: TranscriptRecord) throws {
        if writer == nil {
            try Self.repairTornTail(url)
            writer = try JSONLWriter(url: url)
        }
        try writer?.append(record)
    }

    public func close() {
        writer?.close()
        writer = nil
    }

    public struct Contents: Sendable {
        public var records: [TranscriptRecord]
        /// 1-based line numbers that did not decode.
        public var unreadable: [Int]
    }

    public nonisolated func read() throws -> Contents {
        try Self.read(url)
    }

    public static func read(_ url: URL) throws -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return Contents(records: [], unreadable: []) }
        let data = try Data(contentsOf: url)
        let decoder = JSONCoding.decoder()
        var records: [TranscriptRecord] = []
        var unreadable: [Int] = []
        for (index, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            if let record = try? decoder.decode(TranscriptRecord.self, from: Data(line)) {
                records.append(record)
            } else {
                unreadable.append(index + 1)
            }
        }
        return Contents(records: records, unreadable: unreadable)
    }

    /// A file whose last byte is not a newline ends in a torn line: give it one, so the next
    /// append starts a line of its own.
    static func repairTornTail(_ url: URL) throws {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        if handle.readData(ofLength: 1) != Data([0x0A]) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
        }
    }
}
