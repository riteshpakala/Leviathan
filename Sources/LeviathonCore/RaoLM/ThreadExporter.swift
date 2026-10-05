//
//  ThreadExporter.swift
//  LeviathonCore
//
//  WHAT: Writes one Thread (a model on a prompt set) as a RaoLM corpus, beside the weights and
//        expectations RaoLM cannot read yet.
//  OUT:  threads/<set>/thread/: manifest.json, facts.jsonl, documents/<id>.json and .txt (what
//        RaoLM's CorpusStore reads), snapshot.json (what `raolm train --corpus` reads),
//        expectations.jsonl, weights.jsonl and thread.json.
//  PIN:  One document per prompt: your latest resolution if you saved one, else the baseline.
//        The other samples only inform the measurements, since near-copies of one answer in a
//        Thread would blur its facts. Refuses a model whose terms are not `permitted`.
//        Deterministic: the same transcript and edits write the same bytes (the snapshot's time
//        is the newest record's). The manifest is written last, so a directory with one is whole.
//

import Foundation

public struct ExportOptions: Codable, Sendable, Hashable {
    /// Write candidates as RaoLM facts of this kind; RaoLM must know the kind to read them.
    public var factKind: String?
    public var formWeight: Double
    public var minConfidence: Double
    public var minSupport: Int
    public var parameters: PassageParameters

    public init(factKind: String? = nil, formWeight: Double = 0.5, minConfidence: Double = 0.8, minSupport: Int = 3,
                parameters: PassageParameters = PassageParameters()) {
        self.factKind = factKind
        self.formWeight = formWeight
        self.minConfidence = minConfidence
        self.minSupport = minSupport
        self.parameters = parameters
    }
}

public struct ThreadDocumentCard: Codable, Sendable, Hashable {
    public var id: String
    public var promptID: String
    public var partitions: Int
    public var contentWords: Int
    /// Mean weight of the document's content words: its sampling weight.
    public var weight: Double
    public var edited: Bool
    public var resolutionID: String?
    public var baselineRecordID: String
    public var samples: Int
    public var expectations: Int
    public var candidates: Int
}

public struct SkippedPrompt: Codable, Sendable, Hashable {
    public var promptID: String
    public var reason: String
}

/// thread.json: what a Thread was made from and under which rules.
public struct ThreadCard: Codable, Sendable {
    public var slug: String
    public var company: String
    public var modelID: String
    public var set: String
    public var generator: String
    public var generatorVersion: Int
    public var options: ExportOptions
    public var passageVersion: Int
    public var weightsConvention: String
    public var terms: Terms
    public var corpusHash: String
    /// Mean of the documents' weights.
    public var samplingWeight: Double
    public var documents: [ThreadDocumentCard]
    public var skipped: [SkippedPrompt]
}

public struct ExportSummary: Codable, Sendable {
    public var slug: String
    public var directory: String
    public var corpusHash: String
    public var documents: Int
    public var partitions: Int
    public var expectations: Int
    public var candidates: Int
    public var facts: Int
    public var samplingWeight: Double
    public var skipped: [SkippedPrompt]
    /// Prompts whose saved edit no longer matches the current areas; its stored pieces were used.
    public var staleEdits: [String]
    public var warnings: [String]
}

public enum ThreadExporter {
    public static let generator = "Leviathon"
    public static let generatorVersion = 1
    public static let owner = "leviathon"

    struct Built {
        var document: CorpusDocument
        var weights: [PartitionWeights]
        var expectations: [ExpectationRecord]
        var card: ThreadDocumentCard
        var createdAt: Date
    }

    public static func export(_ source: ThreadSource, options: ExportOptions = ExportOptions()) throws -> ExportSummary {
        let target = source.target
        guard target.terms.trainingUse == .permitted else {
            throw LeviathonFailure(
                "\(source.ref)'s terms are '\(target.terms.trainingUse.rawValue)', so no Thread is exported for it",
                hint: "once you have checked the model's licence allows training on its outputs: leviathon models terms \(source.ref) --training-use permitted",
                code: LeviathonFailure.ExitCode.noPermission)
        }
        let kind = source.set.settings.documentKind
        guard DocumentKinds.raolm.contains(kind) else {
            throw LeviathonFailure("prompt set \(source.set.id) uses document kind '\(kind)', which RaoLM does not read",
                                   code: LeviathonFailure.ExitCode.config)
        }
        let slug = source.slug
        var built: [Built] = []
        var skipped: [SkippedPrompt] = []
        var stale: [String] = []
        var warnings: [String] = []
        var seen = Set<String>()
        for prompt in source.set.prompts {
            guard let passage = try source.passage(for: prompt, parameters: options.parameters) else {
                skipped.append(SkippedPrompt(promptID: prompt.id, reason: "not harvested"))
                continue
            }
            let resolution = source.resolution(for: prompt).flatMap { $0.baselineRecordID == passage.baselineRecordID ? $0 : nil }
            var pieces = try Resolver.pieces(passage, choices: []).pieces
            if let resolution {
                let current = try Resolver.pieces(passage, choices: resolution.choices)
                if current.unmatched.isEmpty {
                    pieces = current.pieces
                } else {
                    pieces = resolution.pieces
                    stale.append(prompt.id)
                }
            }
            let document = try build(passage: passage, pieces: pieces, prompt: prompt, slug: slug, kind: kind, options: options,
                                     resolution: resolution, records: source.records(for: prompt))
            guard seen.insert(document.document.id).inserted else {
                skipped.append(SkippedPrompt(promptID: prompt.id, reason: "same text as an earlier prompt's document"))
                continue
            }
            built.append(document)
        }
        if let kind = options.factKind {
            warnings.append("facts are written with kind '\(kind)'; RaoLM reads them only if its FactKind has that case")
        }

        let documents = built.map(\.document)
        let manifest = CorpusManifest(slug: slug, generator: generator, generatorVersion: generatorVersion, documents: documents)
        let exportedAt = Date(timeIntervalSince1970: (built.map(\.createdAt).max() ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970.rounded(.down))
        let snapshot = CorpusSnapshot(
            corpus: documents, slug: slug, owner: owner,
            createdAt: Dictionary(uniqueKeysWithValues: built.map { ($0.document.id, Int64(($0.createdAt.timeIntervalSince1970 * 1000).rounded(.down))) }),
            exportedAt: exportedAt)
        let cards = built.map(\.card)
        let samplingWeight = cards.isEmpty ? 0 : cards.map(\.weight).reduce(0, +) / Double(cards.count)
        let card = ThreadCard(
            slug: slug, company: target.company, modelID: target.modelID, set: source.set.id, generator: generator,
            generatorVersion: generatorVersion, options: options, passageVersion: PassageBuilder.version,
            weightsConvention: Weights.convention, terms: target.terms, corpusHash: manifest.corpusHash,
            samplingWeight: round4(samplingWeight), documents: cards, skipped: skipped)

        let directory = source.workspace.exportDirectory(source.ref, set: source.set.id)
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        let documentsDirectory = directory.appendingPathComponent("documents", isDirectory: true)
        try manager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        for document in documents {
            try JSONCoding.write(document, to: documentsDirectory.appendingPathComponent("\(document.id).json"))
            try Data((document.name + "\n\n" + document.text + "\n").utf8).write(to: documentsDirectory.appendingPathComponent("\(document.id).txt"),
                                                                                  options: .atomic)
        }
        try JSONCoding.writeLines(documents.flatMap(\.facts), to: directory.appendingPathComponent("facts.jsonl"))
        try JSONCoding.writeLines(built.flatMap(\.expectations), to: directory.appendingPathComponent("expectations.jsonl"))
        try JSONCoding.writeLines(built.flatMap(\.weights), to: directory.appendingPathComponent("weights.jsonl"))
        try JSONCoding.write(snapshot, to: directory.appendingPathComponent(CorpusSnapshot.fileName))
        try JSONCoding.write(card, to: directory.appendingPathComponent("thread.json"))
        try JSONCoding.write(manifest, to: directory.appendingPathComponent("manifest.json"))

        return ExportSummary(
            slug: slug, directory: source.workspace.relative(directory), corpusHash: manifest.corpusHash, documents: documents.count,
            partitions: manifest.partitionCount, expectations: built.reduce(0) { $0 + $1.expectations.count },
            candidates: built.reduce(0) { $0 + $1.expectations.filter(\.candidate).count }, facts: manifest.factCount,
            samplingWeight: round4(samplingWeight), skipped: skipped, staleEdits: stale, warnings: warnings)
    }

    static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    // MARK: One document

    static func build(passage: Passage, pieces: [Piece], prompt: Prompt, slug: String, kind: String, options: ExportOptions,
                      resolution: Resolution?, records: [TranscriptRecord]) throws -> Built {
        let text = pieces.map(\.text).joined()
        guard ContentHash.canonical(text) == text else {
            throw LeviathonFailure("the document for \(prompt.id) is not in canonical form", code: LeviathonFailure.ExitCode.software)
        }
        let docTokens = Tokenizer.tokenize(text).tokens
        let tokenWeights = Weights.tokenWeights(docTokens, pieces: pieces, formWeight: options.formWeight)
        var document = CorpusDocument.make(slug: slug, name: prompt.id, kind: kind, subject: prompt.id, text: text)

        // Document tokens ↔ partition tokens, position by position (newlines left out: the
        // chunker only moves whitespace).
        let partitionTokens = document.partitions.map { Tokenizer.tokenize($0.text) }
        let docVisible = docTokens.indices.filter { docTokens[$0].kind != .newline }
        var partitionVisible: [(partition: Int, token: Int)] = []
        for (p, tokenized) in partitionTokens.enumerated() {
            for (k, token) in tokenized.tokens.enumerated() where token.kind != .newline { partitionVisible.append((p, k)) }
        }
        guard docVisible.count == partitionVisible.count,
              zip(docVisible, partitionVisible).allSatisfy({ docTokens[$0].text == partitionTokens[$1.partition].tokens[$1.token].text }) else {
            throw LeviathonFailure("the partitions of \(prompt.id) do not hold the document's words in order", code: LeviathonFailure.ExitCode.software)
        }
        var docToPartition = [(partition: Int, token: Int)?](repeating: nil, count: docTokens.count)
        var partitionWeights = partitionTokens.map { [Weights.TokenWeight?](repeating: nil, count: $0.tokens.count) }
        for (d, place) in zip(docVisible, partitionVisible) {
            docToPartition[d] = place
            partitionWeights[place.partition][place.token] = tokenWeights[d]
        }
        let weights = document.partitions.enumerated().map { p, partition in
            PartitionWeights(documentID: document.id, partitionIndex: p, textSHA256: partition.textSHA256,
                             spans: Weights.spans(partition: partition.text, tokens: partitionTokens[p], weights: partitionWeights[p],
                                                  formWeight: options.formWeight))
        }

        let baselineToDoc = mapBaseline(passage: passage, pieces: pieces, docTokens: docTokens)
        let sentences = Tokenizer.sentences(passage.baseline.tokens)
        var expectations: [ExpectationRecord] = []
        for expectation in passage.expectations {
            guard let fact = locate(expectation, passage: passage, sentences: sentences, baselineToDoc: baselineToDoc,
                                    docToPartition: docToPartition, partitionTokens: partitionTokens, document: document,
                                    kind: options.factKind ?? ExpectationRecord.kind, number: expectations.count) else { continue }
            let candidate = (expectation.confidence ?? 0) >= options.minConfidence && expectation.support >= options.minSupport
            expectations.append(ExpectationRecord(
                fact: fact, promptID: prompt.id, cutWord: expectation.cutWord, support: expectation.support, kept: expectation.kept,
                confidence: expectation.confidence, onsetTemperature: expectation.onsetTemperature,
                byTemperature: expectation.byTemperature, candidate: candidate))
        }
        if options.factKind != nil { document.facts = expectations.filter(\.candidate).map(\.fact) }

        let content = tokenWeights.indices.filter { docTokens[$0].role == .content }
        let weight = content.isEmpty ? 1 : content.map { tokenWeights[$0].weight }.reduce(0, +) / Double(content.count)
        let baselineRecord = records.first { $0.id == passage.baselineRecordID }
        let card = ThreadDocumentCard(
            id: document.id, promptID: prompt.id, partitions: document.partitions.count, contentWords: content.count, weight: round4(weight),
            edited: pieces.contains { $0.basis == .edit || ($0.basis == .area && $0.baseline == nil) }, resolutionID: resolution?.id,
            baselineRecordID: passage.baselineRecordID, samples: passage.samples.count, expectations: expectations.count,
            candidates: expectations.filter(\.candidate).count)
        return Built(document: document, weights: weights, expectations: expectations, card: card,
                     createdAt: records.map(\.createdAt).max() ?? baselineRecord?.createdAt ?? Date(timeIntervalSince1970: 0))
    }

    /// Baseline token → document token, for every piece that reproduces baseline tokens verbatim.
    static func mapBaseline(passage: Passage, pieces: [Piece], docTokens: [Token]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var offset = 0
        var d = 0
        let baseline = passage.baseline.tokens
        for piece in pieces {
            let start = offset
            let end = offset + piece.text.utf8.count
            offset = end
            while d < docTokens.count, docTokens[d].start < start { d += 1 }
            var inside: [Int] = []
            var k = d
            while k < docTokens.count, docTokens[k].end <= end {
                inside.append(k)
                k += 1
            }
            guard let range = piece.baseline, inside.count == range.count,
                  zip(range.range, inside).allSatisfy({ baseline[$0].text == docTokens[$1].text }) else { continue }
            for (b, doc) in zip(range.range, inside) { map[b] = doc }
        }
        return map
    }

    /// The expectation as a RaoLM fact in one partition, or nil if your edits touch it or a
    /// partition boundary cuts it.
    static func locate(_ expectation: Expectation, passage: Passage, sentences: [Range<Int>], baselineToDoc: [Int: Int],
                       docToPartition: [(partition: Int, token: Int)?], partitionTokens: [Tokenized], document: CorpusDocument,
                       kind: String, number: Int) -> Fact? {
        let span = IndexRange(expectation.stem.lower, expectation.answer.upper)
        var places: [(partition: Int, token: Int)] = []
        for b in span.range {
            guard let doc = baselineToDoc[b] else { return nil }
            if passage.baseline.tokens[b].kind == .newline { return nil }
            guard let place = docToPartition[doc] else { return nil }
            places.append(place)
        }
        guard let partition = places.first?.partition, places.allSatisfy({ $0.partition == partition }) else { return nil }
        let tokens = partitionTokens[partition].tokens
        let text = document.partitions[partition].text
        let stemCount = expectation.stem.count
        let sentenceStart = tokens[places[0].token].start
        let answerStart = tokens[places[stemCount - 1].token].end
        let answerEnd = tokens[places[places.count - 1].token].end
        let prompt = Tokenizer.slice(text, sentenceStart, answerStart)
        let answer = Tokenizer.slice(text, answerStart, answerEnd)
        guard answer.first?.isWhitespace == true, prompt.utf8.count == answerStart - sentenceStart else { return nil }

        // The sentence runs to its last token that sits in this partition.
        var sentenceEnd = answerEnd
        for b in expectation.sentence.range where b >= span.upper {
            guard let doc = baselineToDoc[b], let place = docToPartition[doc], place.partition == partition else { break }
            sentenceEnd = tokens[place.token].end
        }
        // Context starts at the sentence before, if it starts in this partition.
        var contextStart = sentenceStart
        if let index = sentences.firstIndex(where: { $0.lowerBound == expectation.sentence.lower }), index > 0,
           let firstWord = sentences[index - 1].first(where: { passage.baseline.tokens[$0].isWord }),
           let doc = baselineToDoc[firstWord], let place = docToPartition[doc], place.partition == partition {
            contextStart = tokens[place.token].start
        }
        return Fact(
            id: "\(document.id)#e\(number)", kind: kind, documentID: document.id, partitionIndex: partition, subject: document.subject,
            prompt: prompt, answer: answer, sentence: Tokenizer.slice(text, sentenceStart, sentenceEnd), sentenceStart: sentenceStart,
            contextStart: contextStart, answerStart: answerStart, answerEnd: answerEnd)
    }
}
