//
//  Weights.swift
//  LeviathonCore
//
//  WHAT: A loss weight for every byte of every partition, as contiguous spans.
//  PIN:  Form (whitespace, punctuation, function words) weighs `formWeight`. A content word
//        weighs what its piece weighs: 1 in locked text and in your own words, the share of
//        samples that wrote the wording in an area. Spans are in UTF-8 bytes, so they hold for
//        any tokenizer; RaoLM gives each of its tokens the weight of the span holding the token's
//        last byte (`convention`). Whitespace is a span of its own, so a BPE token made only of
//        whitespace lands on form.
//

import Foundation

public struct WeightSpan: Codable, Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var weight: Double
    /// form, locked, area or edit.
    public var basis: String

    public init(start: Int, end: Int, weight: Double, basis: String) {
        self.start = start
        self.end = end
        self.weight = weight
        self.basis = basis
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Int.self)
        end = try c.decode(Int.self)
        weight = try c.decode(Double.self)
        basis = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(start)
        try c.encode(end)
        try c.encode((weight * 10_000).rounded() / 10_000)
        try c.encode(basis)
    }
}

public struct PartitionWeights: Codable, Sendable, Hashable {
    public var documentID: String
    public var partitionIndex: Int
    public var textSHA256: String
    public var spans: [WeightSpan]
}

public enum Weights {
    public static let convention = "Each span is [start, end, weight, basis] in UTF-8 bytes of the partition text; together they cover it exactly. A tokenizer's token takes the weight of the span holding its last byte."

    public struct TokenWeight: Sendable, Hashable {
        public var weight: Double
        public var basis: String
    }

    /// The weight of each token of a document made of pieces.
    public static func tokenWeights(_ tokens: [Token], pieces: [Piece], formWeight: Double) -> [TokenWeight] {
        var bounds: [(start: Int, end: Int)] = []
        var offset = 0
        for piece in pieces {
            let length = piece.text.utf8.count
            bounds.append((offset, offset + length))
            offset += length
        }
        var p = 0
        return tokens.map { token in
            guard token.role == .content, !pieces.isEmpty else { return TokenWeight(weight: formWeight, basis: "form") }
            while p < bounds.count - 1, bounds[p].end <= token.start { p += 1 }
            let piece = pieces[p]
            return TokenWeight(weight: piece.weight, basis: piece.basis.rawValue)
        }
    }

    /// Spans over one partition, from its own tokens and the weight each one maps to (nil: form).
    public static func spans(partition text: String, tokens: Tokenized, weights: [TokenWeight?], formWeight: Double) -> [WeightSpan] {
        var spans: [WeightSpan] = []
        func add(_ start: Int, _ end: Int, _ weight: Double, _ basis: String) {
            guard end > start else { return }
            if let last = spans.last, last.end == start, last.weight == weight, last.basis == basis {
                spans[spans.count - 1].end = end
            } else {
                spans.append(WeightSpan(start: start, end: end, weight: weight, basis: basis))
            }
        }
        var cursor = 0
        for (index, token) in tokens.tokens.enumerated() {
            add(cursor, token.start, formWeight, "form")
            let weight = token.kind == .newline ? nil : weights[index]
            add(token.start, token.end, weight?.weight ?? formWeight, weight?.basis ?? "form")
            cursor = token.end
        }
        add(cursor, text.utf8.count, formWeight, "form")
        return spans
    }
}
