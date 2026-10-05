//
//  ContentHash.swift
//  LeviathanCore
//
//  WHAT: RaoLM's content addressing, mirrored: the canonical text a document id is derived
//        from, document ids, partition urls, Thread handles and the corpus hash.
//  PIN:  Mirrors RaoLM `Sources/RaoLMCore/Hashing/ContentHash.swift`. Parity is held by tests
//        that reproduce the ids and hashes of documents RaoLM generated. Change neither side
//        without the other.
//

import Foundation

public enum ContentHash {

    public static func sha256Hex(_ text: String) -> String {
        Hashing.sha256Hex(text)
    }

    /// NFC, `\r\n` and `\r` → `\n`, trailing spaces and tabs stripped from every line, the whole
    /// trimmed.
    public static func canonical(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var end = line.endIndex
            while end > line.startIndex {
                let before = line.index(before: end)
                if line[before] == " " || line[before] == "\t" { end = before } else { break }
            }
            return line[line.startIndex..<end]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public struct CorpusEntry: Sendable, Equatable {
        public var documentID: String
        public var partitionIndex: Int
        public var textSHA256: String

        public init(documentID: String, partitionIndex: Int, textSHA256: String) {
            self.documentID = documentID
            self.partitionIndex = partitionIndex
            self.textSHA256 = textSHA256
        }
    }

    /// SHA-256 over `"<documentID>\t<partitionIndex>\t<textSHA256>\n"`, sorted by document id
    /// and partition index.
    public static func corpusHash(_ entries: [CorpusEntry]) -> String {
        let sorted = entries.sorted { ($0.documentID, $0.partitionIndex) < ($1.documentID, $1.partitionIndex) }
        var text = ""
        for entry in sorted {
            text += "\(entry.documentID)\t\(entry.partitionIndex)\t\(entry.textSHA256)\n"
        }
        return sha256Hex(text)
    }
}

public enum DocumentID {
    /// `raolm-<slug>-<first 24 hex of sha256(canonical text)>`.
    public static func make(slug: String, canonicalText: String) -> String {
        "raolm-\(slug)-" + String(ContentHash.sha256Hex(canonicalText).prefix(24))
    }

    public static let pattern = #"^raolm-[a-z0-9-]+-[0-9a-f]{24}$"#

    public static func isValid(_ id: String) -> Bool {
        id.range(of: pattern, options: .regularExpression) != nil
    }

    public static func partitionURL(slug: String, documentID: String, index: Int) -> String {
        "raolm://\(slug)/\(documentID)/p/\(index)"
    }

    public static func prefix(slug: String) -> String {
        "raolm-\(slug)-"
    }

    /// Owner, group and slug handles: lowercase `[a-z0-9._-]`, 2–64 characters.
    public static func isValidHandle(_ handle: String) -> Bool {
        handle.range(of: #"^[a-z0-9][a-z0-9._-]{1,63}$"#, options: .regularExpression) != nil
    }
}
