//
//  Expectation.swift
//  LeviathanCore
//
//  WHAT: A measured expectation as exported to a Thread's expectations.jsonl: RaoLM's `Fact`
//        fields at the top level, so a row reads as a fact, plus what was measured about it.
//  PIN:  `kind` is "expectation" unless the export names a RaoLM fact kind. Offsets are UTF-8
//        bytes into the partition, the answer begins with its space, `sentenceStart` is where the
//        stem starts: the same conventions as RaoLM's synthetic facts. `paraphrases` and
//        `negativePrompt` are empty: Leviathan has none to give.
//

import Foundation

public struct ExpectationRecord: Codable, Sendable, Hashable {
    public var fact: Fact
    public var promptID: String
    public var cutWord: String
    /// Aligned samples (the baseline left out) that kept every word of the stem.
    public var support: Int
    /// Of those, the ones that also kept every word of the answer.
    public var kept: Int
    public var confidence: Double?
    public var onsetTemperature: Double?
    public var byTemperature: [ExpectationCount]
    /// Confident and supported enough to be offered to RaoLM as a fact.
    public var candidate: Bool

    public static let kind = "expectation"

    private enum Extra: String, CodingKey {
        case promptID, cutWord, support, kept, confidence, onsetTemperature, byTemperature, candidate
    }

    public init(fact: Fact, promptID: String, cutWord: String, support: Int, kept: Int, confidence: Double?, onsetTemperature: Double?,
                byTemperature: [ExpectationCount], candidate: Bool) {
        self.fact = fact
        self.promptID = promptID
        self.cutWord = cutWord
        self.support = support
        self.kept = kept
        self.confidence = confidence
        self.onsetTemperature = onsetTemperature
        self.byTemperature = byTemperature
        self.candidate = candidate
    }

    public init(from decoder: Decoder) throws {
        fact = try Fact(from: decoder)
        let c = try decoder.container(keyedBy: Extra.self)
        promptID = try c.decode(String.self, forKey: .promptID)
        cutWord = try c.decode(String.self, forKey: .cutWord)
        support = try c.decode(Int.self, forKey: .support)
        kept = try c.decode(Int.self, forKey: .kept)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        onsetTemperature = try c.decodeIfPresent(Double.self, forKey: .onsetTemperature)
        byTemperature = try c.decode([ExpectationCount].self, forKey: .byTemperature)
        candidate = try c.decode(Bool.self, forKey: .candidate)
    }

    public func encode(to encoder: Encoder) throws {
        try fact.encode(to: encoder)
        var c = encoder.container(keyedBy: Extra.self)
        try c.encode(promptID, forKey: .promptID)
        try c.encode(cutWord, forKey: .cutWord)
        try c.encode(support, forKey: .support)
        try c.encode(kept, forKey: .kept)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(onsetTemperature, forKey: .onsetTemperature)
        try c.encode(byTemperature, forKey: .byTemperature)
        try c.encode(candidate, forKey: .candidate)
    }
}
