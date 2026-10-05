import Foundation
import Testing
@testable import LeviathanCore

@Suite("Thread export")
struct ExportTests {
    static let base = """
        The keeper of the lighthouse was born in Pinebrook. She trained under the harbour master for six years.

        Later she wrote a short book about the northern coast, and it is still read in the town.
        """

    /// A workspace with one permitted model, one prompt and five samples.
    func setUp(trainingUse: TrainingUse = .permitted) async throws -> (Workspace, ModelTarget) {
        let workspace = try Support.workspace()
        let target = ModelTarget(company: "acme", modelID: "m1", providerID: "fake", terms: Terms(trainingUse: trainingUse, licence: "Apache-2.0"))
        try ModelStore.save(target, in: workspace)
        _ = try PromptStore.add(set: "writing", id: "keeper", text: "Tell me about the keeper.", in: workspace)
        let prompt = try PromptStore.load("writing", in: workspace).prompts[0]
        let texts: [(Double, String)] = [
            (0, Self.base), (0, Self.base), (0.4, Self.base),
            (0.8, Self.base.replacingOccurrences(of: "Pinebrook", with: "Kestrel")),
            (1.2, Self.base.replacingOccurrences(of: "six years", with: "a decade")),
        ]
        let store = TranscriptStore(url: workspace.transcriptsFile(target.ref))
        var counts: [Double: Int] = [:]
        for (offset, row) in texts.enumerated() {
            let index = counts[row.0, default: 0]
            counts[row.0] = index + 1
            try await store.append(Support.record(row.1, temperature: row.0, index: index, prompt: prompt, set: "writing", seconds: Double(offset)))
        }
        await store.close()
        return (workspace, target)
    }

    @Test("writes a corpus RaoLM reads: ids and hashes recompute, the snapshot matches the manifest")
    func export() async throws {
        let (workspace, target) = try await setUp()
        let source = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        let summary = try ThreadExporter.export(source, options: ExportOptions(minSupport: 2))
        let directory = workspace.exportDirectory(target.ref, set: "writing")
        let manifest = try JSONCoding.read(CorpusManifest.self, from: directory.appendingPathComponent("manifest.json"))
        let snapshot = try JSONCoding.read(CorpusSnapshot.self, from: directory.appendingPathComponent("snapshot.json"))
        #expect(manifest.slug == "acme-m1-writing" && manifest.generator == "Leviathan")
        #expect(manifest.documentCount == 1 && summary.documents == 1)
        #expect(snapshot.corpusHash == manifest.corpusHash)
        #expect(snapshot.group == "raolm-acme-m1-writing" && DocumentID.isValidHandle(snapshot.group))
        let id = try #require(manifest.documentIDs.first)
        let document = try JSONCoding.read(CorpusDocument.self, from: directory.appendingPathComponent("documents/\(id).json"))
        #expect(DocumentID.isValid(document.id))
        #expect(document.id == DocumentID.make(slug: manifest.slug, canonicalText: ContentHash.canonical(document.text)))
        // RaoLM's chunker merges a paragraph under 120 characters into the next.
        #expect(document.text == TextChunker.stablePartitions(Self.base).joined(separator: "\n\n"))
        #expect(document.kind == "transcript")
        #expect(document.facts.isEmpty)
        #expect(try String(contentsOf: directory.appendingPathComponent("facts.jsonl"), encoding: .utf8).isEmpty)
        #expect(try String(contentsOf: directory.appendingPathComponent("documents/\(id).txt"), encoding: .utf8)
            == "keeper\n\n" + document.text + "\n")
    }

    @Test("weights cover every partition exactly; form, locked and area content weigh as the rules say")
    func weights() async throws {
        let (workspace, target) = try await setUp()
        let source = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        _ = try ThreadExporter.export(source, options: ExportOptions(formWeight: 0.5))
        let directory = workspace.exportDirectory(target.ref, set: "writing")
        let rows = try JSONCoding.readLines(PartitionWeights.self, from: directory.appendingPathComponent("weights.jsonl"))
        let document = try JSONCoding.read(CorpusDocument.self, from: directory.appendingPathComponent(
            "documents/\(try JSONCoding.read(CorpusManifest.self, from: directory.appendingPathComponent("manifest.json")).documentIDs[0]).json"))
        #expect(rows.count == document.partitions.count)
        for row in rows {
            let text = document.partitions[row.partitionIndex].text
            #expect(row.spans.first?.start == 0 && row.spans.last?.end == text.utf8.count)
            #expect(zip(row.spans, row.spans.dropFirst()).allSatisfy { $0.end == $1.start })
            func weight(of word: String) -> WeightSpan? {
                guard let range = text.range(of: word) else { return nil }
                let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
                return row.spans.first { $0.start <= start && start < $0.end }
            }
            if let span = weight(of: "Pinebrook") {
                // Three of the four other samples kept it; only the 0.8 sample changed it.
                #expect(span.basis == "area" && abs(span.weight - 0.75) < 1e-9)
            }
            if let span = weight(of: "keeper") { #expect(span.basis == "locked" && span.weight == 1) }
            if let span = weight(of: "the") { #expect(span.basis == "form" && span.weight == 0.5) }
        }
        let card = try JSONCoding.read(ThreadCard.self, from: directory.appendingPathComponent("thread.json"))
        #expect(card.documents.first?.weight ?? 0 < 1)
        #expect(card.samplingWeight == card.documents.first?.weight)
    }

    @Test("expectations land at their offsets, with confidence; candidates become facts only when asked")
    func expectations() async throws {
        let (workspace, target) = try await setUp()
        let source = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        let summary = try ThreadExporter.export(source, options: ExportOptions(factKind: "expectation", minConfidence: 0.7, minSupport: 3))
        let directory = workspace.exportDirectory(target.ref, set: "writing")
        let rows = try JSONCoding.readLines(ExpectationRecord.self, from: directory.appendingPathComponent("expectations.jsonl"))
        #expect(!rows.isEmpty && summary.expectations == rows.count)
        let document = try JSONCoding.read(CorpusDocument.self, from: directory.appendingPathComponent("documents/\(rows[0].fact.documentID).json"))
        for row in rows {
            let text = document.partitions[row.fact.partitionIndex].text
            #expect(Tokenizer.slice(text, row.fact.sentenceStart, row.fact.answerStart) == row.fact.prompt)
            #expect(Tokenizer.slice(text, row.fact.answerStart, row.fact.answerEnd) == row.fact.answer)
            #expect(row.fact.answer.hasPrefix(" "))
        }
        let born = try #require(rows.first { $0.fact.answer == " Pinebrook" })
        #expect(born.fact.prompt == "The keeper of the lighthouse was born in")
        #expect(born.support == 4 && born.kept == 3 && born.onsetTemperature == 0.8)
        #expect(born.candidate)
        #expect(document.facts.contains { $0.answer == " Pinebrook" && $0.kind == "expectation" })
        #expect(summary.facts == document.facts.count)
    }

    @Test("a saved edit becomes the document, and its words weigh 1")
    func edited() async throws {
        let (workspace, target) = try await setUp()
        let source = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        let passage = try #require(try source.passage(for: source.set.prompts[0]))
        let area = try #require(passage.areas.first { $0.baselineText.contains("Pinebrook") })
        let resolution = try Resolver.resolve(passage, choices: [Choice(tokens: area.tokens, text: "Marrow Bay")])
        try EditStore.append(resolution, workspace: workspace, ref: target.ref)
        let reloaded = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        _ = try ThreadExporter.export(reloaded)
        let directory = workspace.exportDirectory(target.ref, set: "writing")
        let card = try JSONCoding.read(ThreadCard.self, from: directory.appendingPathComponent("thread.json"))
        let id = try #require(card.documents.first?.id)
        let document = try JSONCoding.read(CorpusDocument.self, from: directory.appendingPathComponent("documents/\(id).json"))
        #expect(document.text.contains("born in Marrow Bay."))
        #expect(card.documents.first?.edited == true && card.documents.first?.resolutionID == resolution.id)
        let rows = try JSONCoding.readLines(ExpectationRecord.self, from: directory.appendingPathComponent("expectations.jsonl"))
        #expect(!rows.contains { $0.fact.answer.contains("Marrow") || $0.fact.answer == " Pinebrook" })
    }

    @Test("a model whose terms are not permitted is refused")
    func refused() async throws {
        let (workspace, target) = try await setUp(trainingUse: .prohibited)
        let source = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        do {
            _ = try ThreadExporter.export(source)
            Issue.record("expected a refusal")
        } catch let failure as LeviathanFailure {
            #expect(failure.code == LeviathanFailure.ExitCode.noPermission)
        }
        #expect(!FileManager.default.fileExists(atPath: workspace.exportDirectory(target.ref, set: "writing").path))
    }

    @Test("measuring writes evidence by temperature, cut word and onset")
    func measure() async throws {
        let (workspace, target) = try await setUp(trainingUse: .prohibited)
        let source = try ThreadSource.load(workspace, ref: target.ref, set: "writing")
        let evidence = try Measurements.measure(source, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(evidence.trainingUse == .prohibited)
        #expect(evidence.byTemperature.map(\.temperature) == [0, 0.4, 0.8, 1.2])
        #expect(evidence.byTemperature.first?.formKept == 1)
        #expect(evidence.cutWords.contains { $0.word == "in" })
        #expect(evidence.onsets.contains { $0.temperature == "0.800" && $0.areas >= 1 })
        let url = try Measurements.write(evidence, workspace: workspace)
        #expect(url.path.hasSuffix("catalogue/evidence/acme-m1-writing/\(evidence.date).json"))
    }

    @Test("bits per word come from the host's tokens, each counted for the word holding its last byte")
    func bits() {
        let logprobs = [TokenLogprob(token: "The", logprob: -log(2)), TokenLogprob(token: " ke", logprob: -log(4)),
                        TokenLogprob(token: "eper", logprob: -log(2)), TokenLogprob(token: ".", logprob: 0)]
        let bits = Measurements.wordBits("The keeper.", logprobs)
        #expect(bits.form == [1])
        #expect(bits.content == [3])
        #expect(Measurements.wordBits("Other text.", logprobs).form.isEmpty)
    }
}
