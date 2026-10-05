//
//  PassageBuilder.swift
//  LeviathonCore
//
//  WHAT: Builds a passage from one prompt's samples.
//  IN:   The prompt's records (any order), and optionally the record to build on.
//  OUT:  The baseline as tokens; segments that alternate locked text and areas; every variant
//        each area saw; expectations with their counts; measures per temperature.
//  PIN:  1. Baseline: the record named, else sample 0 at the lowest temperature.
//        2. Truncated, filtered and empty samples are set aside with the reason.
//        3. Each other sample is aligned to the baseline; one keeping under `divergence` of the
//           tokens is a whole-response alternate and shapes nothing below.
//        4. A baseline token is unstable if an aligned sample dropped or changed it; the gap
//           between two tokens is unstable if a sample inserted text there. A stable run of fewer
//           than `absorbWords` words between two unstable stretches joins them. What is left
//           unstable are the areas.
//        5. Each aligned sample's variant for an area is its text between the area's two locked
//           neighbours, the whitespace at both edges included, so variants join cleanly.
//        Every token outside an area was kept by every aligned sample, so locked text needs no
//        weight below 1.
//

import Foundation

public enum PassageBuilder {
    public static let version = 1

    struct Sample {
        var record: TranscriptRecord
        var text: String
        var tokenized: Tokenized?
        var status: SampleStatus
        var reason: String?
        var alignment: Alignment?

        var ref: SampleRef { SampleRef(recordID: record.id, temperature: record.sampling.temperature, sampleIndex: record.sampling.sampleIndex) }
        var temperature: Double? { record.sampling.temperature }
    }

    /// Lowest temperature first (no temperature last), then sample index, then time.
    static func order(_ a: TranscriptRecord, _ b: TranscriptRecord) -> Bool {
        let ta = a.sampling.temperature ?? .infinity
        let tb = b.sampling.temperature ?? .infinity
        if ta != tb { return ta < tb }
        if a.sampling.sampleIndex != b.sampling.sampleIndex { return a.sampling.sampleIndex < b.sampling.sampleIndex }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    static func setAsideReason(_ record: TranscriptRecord, text: String) -> String? {
        if text.isEmpty { return "empty" }
        switch record.finishReason {
        case "length": return "truncated"
        case "content_filter": return "filtered"
        default: return nil
        }
    }

    public static func build(set: String, model: String, prompt: Prompt, records: [TranscriptRecord], baselineRecordID: String? = nil,
                             parameters: PassageParameters = PassageParameters()) throws -> Passage {
        var samples = records.sorted(by: order).map { record -> Sample in
            let text = ContentHash.canonical(record.response)
            let reason = setAsideReason(record, text: text)
            return Sample(record: record, text: text, tokenized: nil, status: reason == nil ? .aligned : .setAside, reason: reason)
        }
        let usable = samples.indices.filter { samples[$0].status != .setAside }
        let baselineIndex = baselineRecordID.flatMap { id in usable.first { samples[$0].record.id == id } } ?? usable.first
        guard let baselineIndex else {
            throw LeviathonFailure("no usable sample for prompt \(prompt.id) (\(records.count) recorded, all set aside or none)",
                                   hint: "harvest it first: leviathon harvest --set \(set) --model \(model)", code: LeviathonFailure.ExitCode.noInput)
        }
        samples[baselineIndex].status = .baseline
        let baseline = Tokenizer.tokenize(samples[baselineIndex].text)
        samples[baselineIndex].tokenized = baseline
        let tokens = baseline.tokens
        let n = tokens.count

        for index in usable where index != baselineIndex {
            let tokenized = Tokenizer.tokenize(samples[index].text)
            let alignment = Aligner.align(baseline: tokens, sample: tokenized.tokens, cellCap: parameters.cellCap)
            samples[index].tokenized = tokenized
            samples[index].alignment = alignment
            samples[index].status = alignment.overlap >= parameters.divergence ? .aligned : .divergent
        }
        let aligned = samples.indices.filter { samples[$0].status == .aligned }

        // Unstable tokens and gaps, as slots: gap g at 2g, token i at 2i + 1.
        var unstable = [Bool](repeating: false, count: 2 * n + 1)
        for index in aligned {
            guard let alignment = samples[index].alignment else { continue }
            var previousBase = -1
            var previousSample = -1
            for i in 0..<n {
                guard let j = alignment.map[i] else {
                    unstable[2 * i + 1] = true
                    continue
                }
                if i == previousBase + 1, j > previousSample + 1 { unstable[2 * i] = true }
                previousBase = i
                previousSample = j
            }
            if previousBase == n - 1, previousSample < alignment.sampleCount - 1 { unstable[2 * n] = true }
        }
        absorb(&unstable, tokens: tokens, minWords: parameters.absorbWords)
        let ranges = areaRanges(unstable, tokenCount: n)

        // Areas and their variants.
        let baselineText = samples[baselineIndex].text
        var areas: [Area] = []
        for (id, range) in ranges.enumerated() {
            let baseWording = Tokenizer.slice(baselineText, range.lower > 0 ? tokens[range.lower - 1].end : 0,
                                              range.upper < n ? tokens[range.upper].start : baseline.byteCount)
            var groups: [(key: String, text: String, refs: [SampleRef], isBaseline: Bool)] = [
                (whitespaceKey(baseWording), baseWording, [samples[baselineIndex].ref], true),
            ]
            var perSample: [(temperature: Double?, key: String)] = []
            for index in aligned {
                guard let text = variant(of: samples[index], area: range, baselineTokenCount: n) else { continue }
                let key = whitespaceKey(text)
                perSample.append((samples[index].temperature, key))
                if let g = groups.firstIndex(where: { $0.key == key }) {
                    groups[g].refs.append(samples[index].ref)
                } else {
                    groups.append((key, text, [samples[index].ref], false))
                }
            }
            let total = perSample.count
            let variants = groups.map { group in
                Variant(text: group.text, isBaseline: group.isBaseline, samples: group.refs,
                        share: total == 0 ? (group.isBaseline ? 1 : 0) : Double(perSample.filter { $0.key == group.key }.count) / Double(total))
            }
            let baseKey = groups[0].key
            let departures = perSample.filter { $0.key != baseKey }
            let onset = departures.compactMap(\.temperature).min()
            let onsetKey = departures.isEmpty ? nil : SamplingPoint.key(onset)
            var byTemperature: [TemperatureShare] = []
            for key in Set(perSample.map { SamplingPoint.key($0.temperature) }).sorted() {
                let rows = perSample.filter { SamplingPoint.key($0.temperature) == key }
                byTemperature.append(TemperatureShare(temperature: rows.first?.temperature, samples: rows.count,
                                                      keptBaseline: Double(rows.filter { $0.key == baseKey }.count) / Double(rows.count)))
            }
            byTemperature.sort { ($0.temperature ?? .infinity) < ($1.temperature ?? .infinity) }
            let holdsContent = variants.contains { Tokenizer.tokenize($0.text).tokens.contains { $0.isWord && $0.role == .content } }
            areas.append(Area(id: id, tokens: range, baselineText: baseWording, variants: variants, onsetTemperature: onset, onsetKey: onsetKey,
                              byTemperature: byTemperature, entropy: entropy(perSample.map(\.key)), holdsContent: holdsContent))
        }

        let segments = makeSegments(areas: areas, tokens: tokens, text: baselineText, byteCount: baseline.byteCount)
        let expectations = measureExpectations(promptID: prompt.id, tokens: tokens, text: baselineText, samples: samples,
                                               aligned: aligned, parameters: parameters)
        let measures = makeMeasures(samples: samples, baselineIndex: baselineIndex, tokens: tokens, areas: areas)

        let passageSamples = samples.map { sample in
            PassageSample(recordID: sample.record.id, temperature: sample.temperature, sampleIndex: sample.record.sampling.sampleIndex,
                          status: sample.status, reason: sample.reason, overlap: sample.alignment?.overlap, kept: sample.alignment?.keptRuns)
        }
        return Passage(
            version: version, parameters: parameters, set: set, model: model, promptID: prompt.id, promptSHA: prompt.sha,
            messages: prompt.messages, baselineRecordID: samples[baselineIndex].record.id,
            baselineTemperature: samples[baselineIndex].temperature, baseline: baseline, samples: passageSamples, segments: segments,
            areas: areas, expectations: expectations, measures: measures)
    }

    // MARK: Steps

    /// Marks unstable every stable run with fewer than `minWords` words that has unstable slots
    /// on both sides.
    static func absorb(_ unstable: inout [Bool], tokens: [Token], minWords: Int) {
        var s = 0
        while s < unstable.count {
            guard !unstable[s] else {
                s += 1
                continue
            }
            var e = s
            while e < unstable.count, !unstable[e] { e += 1 }
            if s > 0, e < unstable.count {
                let words = stride(from: s, to: e, by: 1).filter { $0 % 2 == 1 && tokens[($0 - 1) / 2].isWord }.count
                if words < minWords {
                    for k in s..<e { unstable[k] = true }
                }
            }
            s = e
        }
    }

    /// Unstable runs as baseline token ranges, touching ranges merged.
    static func areaRanges(_ unstable: [Bool], tokenCount n: Int) -> [IndexRange] {
        var ranges: [IndexRange] = []
        var s = 0
        while s < unstable.count {
            guard unstable[s] else {
                s += 1
                continue
            }
            var e = s
            while e < unstable.count, unstable[e] { e += 1 }
            let tokenSlots = stride(from: s, to: e, by: 1).filter { $0 % 2 == 1 }
            let range = tokenSlots.isEmpty
                ? IndexRange(s / 2, s / 2)
                : IndexRange((tokenSlots.first! - 1) / 2, (tokenSlots.last! - 1) / 2 + 1)
            if let last = ranges.last, last.upper >= range.lower {
                ranges[ranges.count - 1] = IndexRange(last.lower, max(last.upper, range.upper))
            } else {
                ranges.append(range)
            }
            s = e
        }
        return ranges
    }

    /// A sample's text between the area's locked neighbours, edge whitespace included. Nil if the
    /// sample did not keep a neighbour (an aligned sample always does).
    static func variant(of sample: Sample, area: IndexRange, baselineTokenCount n: Int) -> String? {
        guard let alignment = sample.alignment, let tokenized = sample.tokenized else { return nil }
        let start: Int
        if area.lower > 0 {
            guard let j = alignment.map[area.lower - 1] else { return nil }
            start = tokenized.tokens[j].end
        } else {
            start = 0
        }
        let end: Int
        if area.upper < n {
            guard let j = alignment.map[area.upper] else { return nil }
            end = tokenized.tokens[j].start
        } else {
            end = tokenized.byteCount
        }
        return Tokenizer.slice(sample.text, start, end)
    }

    /// Runs of spaces and tabs read as one space, so variants differing only there group together.
    static func whitespaceKey(_ text: String) -> String {
        var out = ""
        var inSpace = false
        for character in text {
            if character == " " || character == "\t" {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(character)
                inSpace = false
            }
        }
        return out
    }

    static func entropy(_ keys: [String]) -> Double {
        guard !keys.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        let total = Double(keys.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    /// Locked text runs from its first token's text to its last token's end; an area owns the
    /// whitespace on both its edges. At the ends of the text, the first and last segments take
    /// whatever whitespace is there.
    static func makeSegments(areas: [Area], tokens: [Token], text: String, byteCount: Int) -> [Segment] {
        let n = tokens.count
        var segments: [Segment] = []
        var next = 0
        func locked(_ lower: Int, _ upper: Int) {
            guard upper > lower else { return }
            let start = lower == 0 ? 0 : tokens[lower].start
            let end = upper == n ? byteCount : tokens[upper - 1].end
            segments.append(Segment(kind: .locked, tokens: IndexRange(lower, upper), text: Tokenizer.slice(text, start, end), area: nil))
        }
        for area in areas {
            locked(next, area.tokens.lower)
            segments.append(Segment(kind: .area, tokens: area.tokens, text: area.baselineText, area: area.id))
            next = area.tokens.upper
        }
        locked(next, n)
        return segments
    }

    static func measureExpectations(promptID: String, tokens: [Token], text: String, samples: [Sample], aligned: [Int],
                                    parameters: PassageParameters) -> [Expectation] {
        let cuts = StemCutter.cut(tokens, minStemWords: parameters.minStemWords, maxAnswerWords: parameters.maxAnswerWords)
        return cuts.map { cut in
            let stemWords = cut.stem.range.filter { tokens[$0].isWord }
            let answerWords = cut.answer.range.filter { tokens[$0].isWord }
            var counts: [String: ExpectationCount] = [:]
            var support = 0
            var kept = 0
            var onset: Double?
            for index in aligned {
                guard let alignment = samples[index].alignment else { continue }
                let key = SamplingPoint.key(samples[index].temperature)
                var count = counts[key] ?? ExpectationCount(temperature: samples[index].temperature, support: 0, kept: 0)
                if stemWords.allSatisfy(alignment.kept) {
                    support += 1
                    count.support += 1
                    if answerWords.allSatisfy(alignment.kept) {
                        kept += 1
                        count.kept += 1
                    } else if let t = samples[index].temperature {
                        onset = min(onset ?? t, t)
                    }
                }
                counts[key] = count
            }
            let stemText = Tokenizer.slice(text, tokens[cut.stem.lower].start, tokens[cut.stem.upper - 1].end)
            let answerText = Tokenizer.slice(text, tokens[cut.answer.lower - 1].end, tokens[cut.answer.upper - 1].end)
            return Expectation(
                id: "\(promptID)#\(cut.stem.lower)-\(cut.answer.upper)", sentence: cut.sentence, stem: cut.stem, answer: cut.answer,
                stemText: stemText, answerText: answerText, cutWord: cut.cutWord, support: support, kept: kept,
                confidence: support > 0 ? Double(kept) / Double(support) : nil, onsetTemperature: onset,
                byTemperature: counts.values.sorted { ($0.temperature ?? .infinity) < ($1.temperature ?? .infinity) })
        }
    }

    static func makeMeasures(samples: [Sample], baselineIndex: Int, tokens: [Token], areas: [Area]) -> PassageMeasures {
        let words = tokens.indices.filter { tokens[$0].isWord }
        let form = words.filter { tokens[$0].role == .form }
        let content = words.filter { tokens[$0].role == .content }
        var inArea = [Bool](repeating: false, count: tokens.count)
        for area in areas { for i in area.tokens.range { inArea[i] = true } }
        let locked = words.filter { !inArea[$0] }.count

        var byKey: [String: [Sample]] = [:]
        for (index, sample) in samples.enumerated() where index != baselineIndex {
            byKey[SamplingPoint.key(sample.temperature), default: []].append(sample)
        }
        let byTemperature = byKey.values.map { rows -> TemperatureMeasure in
            let compared = rows.filter { $0.alignment != nil }
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            func share(_ indices: [Int], _ alignment: Alignment) -> Double? {
                indices.isEmpty ? nil : Double(indices.filter(alignment.kept).count) / Double(indices.count)
            }
            return TemperatureMeasure(
                temperature: rows.first?.temperature, samples: rows.count, aligned: rows.filter { $0.status == .aligned }.count,
                divergent: rows.filter { $0.status == .divergent }.count, setAside: rows.filter { $0.status == .setAside }.count,
                meanOverlap: mean(compared.compactMap { $0.alignment?.overlap }),
                formKept: mean(compared.compactMap { share(form, $0.alignment!) }),
                contentKept: mean(compared.compactMap { share(content, $0.alignment!) }))
        }.sorted { ($0.temperature ?? .infinity) < ($1.temperature ?? .infinity) }

        return PassageMeasures(
            samples: samples.count, aligned: samples.filter { $0.status == .aligned }.count,
            divergent: samples.filter { $0.status == .divergent }.count, setAside: samples.filter { $0.status == .setAside }.count,
            words: words.count, formWords: form.count, contentWords: content.count, lockedWords: locked,
            lockedShare: words.isEmpty ? 1 : Double(locked) / Double(words.count), byTemperature: byTemperature)
    }
}
