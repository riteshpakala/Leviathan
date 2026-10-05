//
//  JSONCoding.swift
//  LeviathanCore
//
//  WHAT: The one JSON encoder and decoder Leviathan writes with, the same settings RaoLM's
//        JSONCoding uses, so a corpus Leviathan writes is byte for byte what RaoLM would write.
//  PIN:  Sorted keys, unescaped slashes, ISO-8601 dates. Pretty for files people read, compact
//        for JSONL rows.
//

import Foundation

public enum JSONCoding {

    public static func prettyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prettyEncoder().encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder().decode(type, from: Data(contentsOf: url))
    }

    /// Every non-empty line of a JSONL file, decoded.
    public static func readLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = decoder()
        return try text.split(separator: "\n").map { try decoder.decode(type, from: Data($0.utf8)) }
    }

    /// Writes rows as a whole JSONL file, replacing what was there.
    public static func writeLines<T: Encodable>(_ rows: [T], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = lineEncoder()
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    /// One value as a single compact line, for logs and `--json` rows.
    public static func line<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try lineEncoder().encode(value), as: UTF8.self)
    }

    public static func pretty<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try prettyEncoder().encode(value), as: UTF8.self)
    }
}

/// An append-only JSONL file. One encodable value per line, flushed as it is written.
public final class JSONLWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let encoder = JSONCoding.lineEncoder()
    private let lock = NSLock()

    public init(url: URL, truncate: Bool = false) throws {
        self.url = url
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if truncate || !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    public func append<T: Encodable>(_ value: T) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}
