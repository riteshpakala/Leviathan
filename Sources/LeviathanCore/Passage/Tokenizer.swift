//
//  Tokenizer.swift
//  LeviathanCore
//
//  WHAT: Splits a response into words, punctuation marks and newlines, each with the inline
//        whitespace before it and its role.
//  PIN:  Lossless: every token's leading whitespace and text, then the trailing whitespace,
//        rebuild the input byte for byte. Words come from Foundation's word boundaries, so
//        text without spaces (Chinese, Japanese) still splits into words. A clitic a tokenizer
//        would split off ("'s", "'t", "'re" …) is split off here too, so roles match RaoLM's.
//        Offsets are UTF-8 bytes, the unit RaoLM's facts use.
//

import Foundation

public enum TokenKind: String, Codable, Sendable {
    case word, punctuation, newline
}

public struct Token: Codable, Sendable, Hashable {
    public var text: String
    /// Spaces and tabs before the token; never a newline.
    public var leading: String
    public var kind: TokenKind
    public var role: TokenRole
    /// UTF-8 offset of `text` (after `leading`) in the source.
    public var start: Int
    public var end: Int

    /// What alignment compares: the text, whatever whitespace came before it.
    public var key: String { kind == .newline ? "\n" : text }
    public var isWord: Bool { kind == .word }
}

public struct Tokenized: Codable, Sendable, Hashable {
    public var tokens: [Token]
    /// Spaces and tabs after the last token.
    public var trailing: String

    public var text: String { tokens.map { $0.leading + $0.text }.joined() + trailing }
    public var byteCount: Int { (tokens.last?.end ?? 0) + trailing.utf8.count }
    public var count: Int { tokens.count }
}

public enum Tokenizer {

    public static func tokenize(_ text: String) -> Tokenized {
        var words: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            words.append(range)
        }
        var tokens: [Token] = []
        tokens.reserveCapacity(words.count * 2)
        var pending = ""
        var offset = 0
        var index = text.startIndex
        var next = 0

        func emit(_ piece: String, _ kind: TokenKind) {
            let start = offset
            offset += piece.utf8.count
            let role: TokenRole = kind == .word ? TokenRoles.role(of: piece) : .form
            tokens.append(Token(text: piece, leading: pending, kind: kind, role: role, start: start, end: offset))
            pending = ""
        }

        while index < text.endIndex {
            while next < words.count, words[next].lowerBound < index { next += 1 }
            if next < words.count, words[next].lowerBound == index {
                let range = words[next]
                next += 1
                for (piece, kind) in splitPacked(String(text[range])) {
                    if kind == .word, let (stem, clitic) = splitClitic(piece) {
                        emit(stem, .word)
                        emit(clitic, .word)
                    } else {
                        emit(piece, kind)
                    }
                }
                index = range.upperBound
                continue
            }
            let character = text[index]
            if character.isNewline {
                emit(String(character), .newline)
            } else if character.isWhitespace {
                pending.append(character)
                offset += character.utf8.count
            } else {
                emit(String(character), .punctuation)
            }
            index = text.index(after: index)
        }
        return Tokenized(tokens: tokens, trailing: pending)
    }

    /// "sheet.Its" → "sheet", ".", "Its": a full stop packed between a lowercase letter and a
    /// capital ends a sentence, as RaoLM's AnswerStop reads it, though word boundaries join it.
    static func splitPacked(_ word: String) -> [(String, TokenKind)] {
        let characters = Array(word)
        var pieces: [(String, TokenKind)] = []
        var start = 0
        var i = 1
        while i < characters.count - 1 {
            if characters[i] == ".", characters[i - 1].isLowercase, characters[i + 1].isUppercase {
                pieces.append((String(characters[start..<i]), .word))
                pieces.append((".", .punctuation))
                start = i + 1
            }
            i += 1
        }
        pieces.append((String(characters[start...]), .word))
        return pieces
    }

    /// "Nashett's" → ("Nashett", "'s"); nil when the word ends in no clitic.
    static func splitClitic(_ word: String) -> (String, String)? {
        let lower = word.lowercased()
        for clitic in TokenRoles.clitics where lower.hasSuffix(clitic) && word.count > clitic.count {
            let cut = word.index(word.endIndex, offsetBy: -clitic.count)
            let stem = String(word[..<cut])
            guard stem.last.map({ $0.isLetter || $0.isNumber }) == true else { continue }
            return (stem, String(word[cut...]))
        }
        return nil
    }

    /// The text between two UTF-8 offsets of `text`.
    public static func slice(_ text: String, _ start: Int, _ end: Int) -> String {
        let utf8 = text.utf8
        let clampedStart = max(0, min(start, utf8.count))
        let clampedEnd = max(clampedStart, min(end, utf8.count))
        let lower = utf8.index(utf8.startIndex, offsetBy: clampedStart)
        let upper = utf8.index(lower, offsetBy: clampedEnd - clampedStart)
        return String(decoding: utf8[lower..<upper], as: UTF8.self)
    }

    // MARK: Sentences

    static let terminals: Set<String> = [".", "?", "!", "…", "。", "？", "！"]
    static let closers: Set<String> = [")", "]", "\"", "'", "”", "’", "»", "」", "』"]

    /// Sentences as token ranges. A sentence ends at a newline, or after a full stop, question
    /// mark or exclamation mark (and any closing quote or bracket right after it) when the next
    /// token follows whitespace, starts with a capital letter, or there is none: RaoLM's
    /// AnswerStop rule. Newline tokens belong to no sentence.
    public static func sentences(_ tokens: [Token]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .newline {
                if let s = start { result.append(s..<i) }
                start = nil
                i += 1
                continue
            }
            if start == nil { start = i }
            if token.kind == .punctuation, terminals.contains(token.text) {
                var end = i + 1
                while end < tokens.count, tokens[end].kind == .punctuation, tokens[end].leading.isEmpty, closers.contains(tokens[end].text) { end += 1 }
                let follows = end < tokens.count ? tokens[end] : nil
                let ends = follows == nil || follows!.kind == .newline || !follows!.leading.isEmpty
                    || (follows!.text.first?.isUppercase ?? false)
                if ends, let s = start {
                    result.append(s..<end)
                    start = nil
                    i = end
                    continue
                }
            }
            i += 1
        }
        if let s = start, s < tokens.count { result.append(s..<tokens.count) }
        return result
    }
}
