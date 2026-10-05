//
//  Measurements.swift
//  LeviathanCore
//
//  WHAT: The evidence one Thread gives about how its model answers, written to
//        catalogue/evidence/<thread-slug>/<date>.json for catalogue/PROPERTIES.md to cite.
//  OUT:  Per temperature: samples, alternates, what share of the baseline's form and content
//        words a sample kept, and bits per form and content word where the host returned
//        log-probabilities. Expectation confidence by the function word that cuts the stem.
//        Where areas and broken expectations first appear by temperature. Area counts.
//  PIN:  Measures any model, whatever its terms; the evidence names the terms it was taken
//        under. Bits are −log₂ p summed over the host's tokens, each token counted for the word
//        holding its last non-space byte.
//

import Foundation

public struct EvidenceTemperature: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var samples: Int
    public var aligned: Int
    public var divergent: Int
    public var setAside: Int
    public var meanOverlap: Double?
    public var formKept: Double?
    public var contentKept: Double?
    /// Mean bits per form word and per content word, from log-probabilities.
    public var bitsPerFormWord: Double?
    public var bitsPerContentWord: Double?
    public var wordsWithBits: Int
}

public struct CutWordStat: Codable, Sendable, Hashable {
    public var word: String
    public var expectations: Int
    /// Expectations at least one sample supported.
    public var supported: Int
    public var meanConfidence: Double?
}

public struct OnsetBin: Codable, Sendable, Hashable {
    /// A temperature key, "default", or "never".
    public var temperature: String
    public var areas: Int
    public var expectations: Int
}

public struct AreaStats: Codable, Sendable, Hashable {
    public var total: Int
    public var insertions: Int
    public var holdingContent: Int
    public var formOnly: Int
    public var meanVariants: Double?
    public var meanEntropy: Double?
}

public struct PassageDigest: Codable, Sendable, Hashable {
    public var promptID: String
    public var samples: Int
    public var aligned: Int
    public var divergent: Int
    public var setAside: Int
    public var lockedShare: Double
    public var areas: Int
    public var expectations: Int
}

public struct Evidence: Codable, Sendable {
    public var slug: String
    public var model: String
    public var set: String
    public var date: String
    public var generator: String
    public var generatorVersion: Int
    public var passageVersion: Int
    public var parameters: PassageParameters
    public var trainingUse: TrainingUse
    public var prompts: Int
    public var harvested: Int
    public var samples: Int
    public var meanLockedShare: Double?
    public var byTemperature: [EvidenceTemperature]
    public var cutWords: [CutWordStat]
    public var onsets: [OnsetBin]
    public var areas: AreaStats
    public var passages: [PassageDigest]
}

public enum Measurements {

    public static func measure(_ source: ThreadSource, parameters: PassageParameters = PassageParameters(), now: Date = Date()) throws -> Evidence {
        var passages: [Passage] = []
        for prompt in source.set.prompts {
            if let passage = try source.passage(for: prompt, parameters: parameters) { passages.append(passage) }
        }
        let records = Dictionary(source.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        struct Row {
            var temperature: Double?
            var status: SampleStatus
            var overlap: Double?
            var formKept: Double?
            var contentKept: Double?
            var formBits: [Double]
            var contentBits: [Double]
        }
        var rows: [Row] = []
        for passage in passages {
            for sample in passage.samples {
                let shares = kept(passage, sample)
                var row = Row(temperature: sample.temperature, status: sample.status, overlap: sample.overlap, formKept: shares.form,
                              contentKept: shares.content, formBits: [], contentBits: [])
                if sample.status != .setAside, let record = records[sample.recordID], let logprobs = record.logprobs, !logprobs.isEmpty {
                    let bits = wordBits(record.response, logprobs)
                    row.formBits = bits.form
                    row.contentBits = bits.content
                }
                if sample.status != .baseline { rows.append(row) }
            }
        }

        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let keys = Set(rows.map { SamplingPoint.key($0.temperature) })
        let byTemperature = keys.map { key -> EvidenceTemperature in
            let group = rows.filter { SamplingPoint.key($0.temperature) == key }
            let formBits = group.flatMap(\.formBits)
            let contentBits = group.flatMap(\.contentBits)
            return EvidenceTemperature(
                temperature: group.first?.temperature, samples: group.count, aligned: group.filter { $0.status == .aligned }.count,
                divergent: group.filter { $0.status == .divergent }.count, setAside: group.filter { $0.status == .setAside }.count,
                meanOverlap: mean(group.compactMap(\.overlap)), formKept: mean(group.compactMap(\.formKept)),
                contentKept: mean(group.compactMap(\.contentKept)), bitsPerFormWord: mean(formBits), bitsPerContentWord: mean(contentBits),
                wordsWithBits: formBits.count + contentBits.count)
        }.sorted { ($0.temperature ?? .infinity) < ($1.temperature ?? .infinity) }

        let expectations = passages.flatMap(\.expectations)
        var cutWords: [CutWordStat] = []
        for (word, list) in Dictionary(grouping: expectations, by: \.cutWord) {
            let supported = list.filter { $0.support > 0 }.count
            let confidences: [Double] = list.compactMap(\.confidence)
            cutWords.append(CutWordStat(word: word, expectations: list.count, supported: supported, meanConfidence: mean(confidences)))
        }
        cutWords.sort { $0.expectations != $1.expectations ? $0.expectations > $1.expectations : $0.word < $1.word }

        let areas = passages.flatMap(\.areas)
        var bins: [String: OnsetBin] = [:]
        for area in areas {
            let key = area.onsetKey ?? "never"
            bins[key, default: OnsetBin(temperature: key, areas: 0, expectations: 0)].areas += 1
        }
        for expectation in expectations where expectation.support > 0 {
            let key = expectation.kept < expectation.support ? SamplingPoint.key(expectation.onsetTemperature) : "never"
            bins[key, default: OnsetBin(temperature: key, areas: 0, expectations: 0)].expectations += 1
        }
        let onsets = bins.values.sorted { order($0.temperature) < order($1.temperature) }

        let areaStats = AreaStats(
            total: areas.count, insertions: areas.filter { $0.tokens.isEmpty }.count, holdingContent: areas.filter(\.holdsContent).count,
            formOnly: areas.filter { !$0.holdsContent }.count, meanVariants: mean(areas.map { Double($0.variants.count) }),
            meanEntropy: mean(areas.map(\.entropy)))
        let digests: [PassageDigest] = passages.map { passage in
            let measures = passage.measures
            return PassageDigest(promptID: passage.promptID, samples: measures.samples, aligned: measures.aligned, divergent: measures.divergent,
                                 setAside: measures.setAside, lockedShare: measures.lockedShare, areas: passage.areas.count,
                                 expectations: passage.expectations.count)
        }
        let lockedShares: [Double] = passages.map(\.measures.lockedShare)
        let samples: Int = passages.reduce(0) { $0 + $1.samples.count }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return Evidence(
            slug: source.slug, model: source.ref.description, set: source.set.id, date: formatter.string(from: now),
            generator: ThreadExporter.generator, generatorVersion: ThreadExporter.generatorVersion, passageVersion: PassageBuilder.version,
            parameters: parameters, trainingUse: source.target.terms.trainingUse, prompts: source.set.prompts.count,
            harvested: passages.count, samples: samples, meanLockedShare: mean(lockedShares), byTemperature: byTemperature,
            cutWords: cutWords, onsets: onsets, areas: areaStats, passages: digests)
    }

    public static func write(_ evidence: Evidence, workspace: Workspace) throws -> URL {
        let url = workspace.evidenceDirectory(slug: evidence.slug).appendingPathComponent("\(evidence.date).json")
        try JSONCoding.write(evidence, to: url)
        return url
    }

    /// The share of the baseline's form words and content words a sample kept; nil for the
    /// baseline itself and for samples that were not aligned.
    public static func kept(_ passage: Passage, _ sample: PassageSample) -> (form: Double?, content: Double?) {
        guard sample.status != .baseline, let kept = sample.kept else { return (nil, nil) }
        let tokens = passage.baseline.tokens
        var isKept = [Bool](repeating: false, count: tokens.count)
        for run in kept { for i in run.range where i < tokens.count { isKept[i] = true } }
        let form = tokens.indices.filter { tokens[$0].isWord && tokens[$0].role == .form }
        let content = tokens.indices.filter { tokens[$0].isWord && tokens[$0].role == .content }
        return (form.isEmpty ? nil : Double(form.filter { isKept[$0] }.count) / Double(form.count),
                content.isEmpty ? nil : Double(content.filter { isKept[$0] }.count) / Double(content.count))
    }

    /// Temperature keys in numeric order, then "default", then "never".
    static func order(_ key: String) -> Double {
        if let value = Double(key) { return value }
        return key == "default" ? 1_000 : 2_000
    }

    /// Bits per word of a response, from the host's tokens and their log-probabilities. Empty when
    /// the tokens do not spell the response.
    public static func wordBits(_ response: String, _ logprobs: [TokenLogprob]) -> (form: [Double], content: [Double]) {
        guard logprobs.map(\.token).joined() == response else { return ([], []) }
        let words = Tokenizer.tokenize(response).tokens
        var bits = [Double](repeating: 0, count: words.count)
        var counted = [Bool](repeating: false, count: words.count)
        var offset = 0
        var w = 0
        for piece in logprobs {
            let bytes = Array(piece.token.utf8)
            let start = offset
            offset += bytes.count
            // The last byte of the token that is not whitespace.
            var last = bytes.count - 1
            while last >= 0, bytes[last] == 0x20 || bytes[last] == 0x09 || bytes[last] == 0x0A || bytes[last] == 0x0D { last -= 1 }
            guard last >= 0 else { continue }
            let position = start + last
            while w < words.count, words[w].end <= position { w += 1 }
            guard w < words.count, words[w].start <= position else { continue }
            bits[w] += -piece.logprob / log(2)
            counted[w] = true
        }
        var form: [Double] = []
        var content: [Double] = []
        for i in words.indices where counted[i] && words[i].isWord {
            if words[i].role == .form { form.append(bits[i]) } else { content.append(bits[i]) }
        }
        return (form, content)
    }
}
