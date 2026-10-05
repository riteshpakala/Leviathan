//
//  TextChunker.swift
//  LeviathonCore
//
//  WHAT: RaoLM's chunker, mirrored: splits a document into the partitions a Thread stores.
//  PIN:  Mirrors RaoLM `Sources/RaoLMCore/Corpus/TextChunker.swift` exactly. Paragraph ==
//        partition; a paragraph over `maxChars` splits at sentence ends, then hard; one under
//        `minChars` merges into the next. Never returns an empty string.
//

import Foundation

public enum TextChunker {
    public static let maxChars = 600
    public static let minChars = 120

    public static func chunk(_ text: String, maxChars: Int = TextChunker.maxChars, minChars: Int = TextChunker.minChars) -> [String] {
        precondition(maxChars > 0 && minChars >= 0)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var paragraphs: [String] = []
        var current: [Substring] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }

        var pieces: [String] = []
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxChars {
                pieces.append(trimmed)
            } else {
                pieces.append(contentsOf: splitLong(trimmed, maxChars: maxChars))
            }
        }

        var merged: [String] = []
        var carry: String?
        for piece in pieces {
            let joined = carry.map { $0 + " " + piece } ?? piece
            if joined.count < minChars {
                carry = joined
            } else {
                merged.append(joined)
                carry = nil
            }
        }
        if let carry {
            if let last = merged.popLast() {
                merged.append(last + " " + carry)
            } else {
                merged.append(carry)
            }
        }
        return merged.filter { !$0.isEmpty }
    }

    static func splitLong(_ paragraph: String, maxChars: Int) -> [String] {
        var sentences: [String] = []
        var start = paragraph.startIndex
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
            let character = paragraph[index]
            let next = paragraph.index(after: index)
            if character == "." || character == "?" || character == "!" {
                if next == paragraph.endIndex || paragraph[next] == " " || paragraph[next] == "\n" {
                    sentences.append(String(paragraph[start..<next]).trimmingCharacters(in: .whitespaces))
                    start = next
                }
            }
            index = next
        }
        let tail = String(paragraph[start...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            for part in hardSplit(sentence, maxChars: maxChars) {
                if current.isEmpty {
                    current = part
                } else if current.count + 1 + part.count <= maxChars {
                    current += " " + part
                } else {
                    chunks.append(current)
                    current = part
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func hardSplit(_ sentence: String, maxChars: Int) -> [String] {
        var remaining = Substring(sentence)
        var parts: [String] = []
        while remaining.count > maxChars {
            let limit = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let cut = remaining[..<limit].lastIndex(of: " ") ?? limit
            let head = remaining[..<cut].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { parts.append(head) }
            remaining = remaining[cut...].drop(while: { $0 == " " })
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    /// Partitions whose joined text chunks back to themselves: RaoLM's own documents hold that
    /// `chunk(text) == partitions`, so Leviathon re-chunks until it does (or gives up after a
    /// few rounds and keeps the last, which still joins to the document's text).
    public static func stablePartitions(_ text: String) -> [String] {
        var partitions = chunk(text)
        for _ in 0..<4 {
            let again = chunk(partitions.joined(separator: "\n\n"))
            if again == partitions { break }
            partitions = again
        }
        return partitions
    }
}
