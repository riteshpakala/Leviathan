//
//  Passage.swift
//  LeviathonCore
//
//  WHAT: The template derived from one prompt's samples: the baseline response as tokens, the
//        text every aligned sample kept (locked), the areas where they diverge with every variant
//        seen, the expectations cut at function words, and what was measured.
//  PIN:  Derived, never edited: written to threads/<set>/passages/<prompt-id>.json and rebuilt
//        from the transcript at will. Shares and counts leave the baseline sample out, since it
//        is the wording they are measured against. Joining the segments' texts gives back the
//        baseline response byte for byte.
//

import Foundation

public enum SampleStatus: String, Codable, Sendable {
    /// The response the passage is built on.
    case baseline
    /// Lined up against the baseline; it shapes the areas and the expectations.
    case aligned
    /// Shares too little with the baseline to align: a whole-response alternate.
    case divergent
    /// Not used: truncated, filtered or empty.
    case setAside
}

public struct PassageSample: Codable, Sendable, Hashable {
    public var recordID: String
    public var temperature: Double?
    public var sampleIndex: Int
    public var status: SampleStatus
    public var reason: String?
    /// Kept baseline tokens over the longer text; nil for the baseline and samples set aside.
    public var overlap: Double?
    /// Runs of baseline tokens this sample kept.
    public var kept: [IndexRange]?

    public var temperatureKey: String { SamplingPoint.key(temperature) }
}

public struct SampleRef: Codable, Sendable, Hashable {
    public var recordID: String
    public var temperature: Double?
    public var sampleIndex: Int
}

public struct Variant: Codable, Sendable, Hashable {
    /// The text between the area's locked neighbours, the whitespace at both edges included.
    public var text: String
    public var isBaseline: Bool
    public var samples: [SampleRef]
    /// Share of the aligned samples (the baseline left out) that wrote this.
    public var share: Double
}

public struct TemperatureShare: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var samples: Int
    /// Share of those samples that kept the baseline's wording.
    public var keptBaseline: Double
}

public struct Area: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Baseline tokens the area replaces; empty for an insertion between two tokens.
    public var tokens: IndexRange
    public var baselineText: String
    public var variants: [Variant]
    /// The lowest temperature at which a sample wrote something else; nil if only at the default.
    public var onsetTemperature: Double?
    public var onsetKey: String?
    public var byTemperature: [TemperatureShare]
    /// Bits of entropy over the variants the aligned samples wrote.
    public var entropy: Double
    /// Whether any variant holds a content word; an area of form only is punctuation or
    /// function words.
    public var holdsContent: Bool

    public var baselineVariant: Variant? { variants.first(where: \.isBaseline) }
}

public enum SegmentKind: String, Codable, Sendable {
    case locked, area
}

public struct Segment: Codable, Sendable, Hashable {
    public var kind: SegmentKind
    public var tokens: IndexRange
    /// The baseline's text for this segment.
    public var text: String
    /// The area's id, for an area segment.
    public var area: Int?
}

public struct ExpectationCount: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var support: Int
    public var kept: Int
}

/// A stem cut at a function word, and the content the baseline wrote after it.
public struct Expectation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sentence: IndexRange
    /// From the sentence's first word through the function word.
    public var stem: IndexRange
    public var answer: IndexRange
    public var stemText: String
    /// Begins with the whitespace before the first answer word, as RaoLM's answers do.
    public var answerText: String
    /// The function word the stem ends in, lowercased.
    public var cutWord: String
    /// Aligned samples (the baseline left out) that kept every word of the stem.
    public var support: Int
    /// Of those, the ones that also kept every word of the answer.
    public var kept: Int
    public var confidence: Double?
    /// The lowest temperature at which a supporting sample broke it.
    public var onsetTemperature: Double?
    public var byTemperature: [ExpectationCount]
}

public struct TemperatureMeasure: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var samples: Int
    public var aligned: Int
    public var divergent: Int
    public var setAside: Int
    public var meanOverlap: Double?
    /// Mean share of the baseline's form words a sample kept.
    public var formKept: Double?
    /// Mean share of the baseline's content words a sample kept.
    public var contentKept: Double?
}

public struct PassageMeasures: Codable, Sendable, Hashable {
    public var samples: Int
    public var aligned: Int
    public var divergent: Int
    public var setAside: Int
    public var words: Int
    public var formWords: Int
    public var contentWords: Int
    public var lockedWords: Int
    public var lockedShare: Double
    public var byTemperature: [TemperatureMeasure]
}

public struct PassageParameters: Codable, Sendable, Hashable {
    /// A sample keeping less than this share of tokens is a whole-response alternate.
    public var divergence: Double
    /// A stable run with fewer words than this between two unstable stretches joins them.
    public var absorbWords: Int
    public var minStemWords: Int
    public var maxAnswerWords: Int
    public var cellCap: Int

    public init(divergence: Double = 0.5, absorbWords: Int = 3, minStemWords: Int = 3, maxAnswerWords: Int = 6,
                cellCap: Int = Aligner.defaultCellCap) {
        self.divergence = divergence
        self.absorbWords = absorbWords
        self.minStemWords = minStemWords
        self.maxAnswerWords = maxAnswerWords
        self.cellCap = cellCap
    }
}

public struct Passage: Codable, Sendable, Hashable {
    public var version: Int
    public var parameters: PassageParameters
    public var set: String
    public var model: String
    public var promptID: String
    public var promptSHA: String
    public var messages: [ChatMessage]
    public var baselineRecordID: String
    public var baselineTemperature: Double?
    public var baseline: Tokenized
    public var samples: [PassageSample]
    public var segments: [Segment]
    public var areas: [Area]
    public var expectations: [Expectation]
    public var measures: PassageMeasures

    public var text: String { baseline.text }

    public func area(_ id: Int) -> Area? { areas.first { $0.id == id } }
}
