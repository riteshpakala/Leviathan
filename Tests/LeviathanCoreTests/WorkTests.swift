import Foundation
import Testing
@testable import LeviathanCore

/// Made-up writing: no line of anyone's real work belongs in a test.
enum Synthetic {
    static let opening = "The quiet harbour keeps its lamps lit long after the boats come in. Mira walks the narrow pier each evening.\n\nTonight a bell answers her from the river mouth."
    static let narrative = Data("""
        {"authorPreamble": "Write quiet prose.", "openingPassage": "\(opening.replacingOccurrences(of: "\n", with: "\\n"))", "openingUserTurn": "Begin.",
         "toolDirectives": {"pen": "Continue the plot."}, "dreamDirective": "DREAM: one short passage.",
         "characters": [{"id": "mira", "name": "Mira", "role": "keeper", "essence": "Counts what the harbour forgets."}]}
        """.utf8)

    static func season(version: Int = 2, passages: [(id: String, text: String, tool: String?, kind: String?)]) -> Data {
        let rows = passages.map { row -> [String: Any] in
            var passage: [String: Any] = ["id": row.id, "text": row.text, "createdAt": "2026-09-01T10:00:00Z"]
            if let tool = row.tool { passage["tool"] = tool; passage["excerpt"] = "a bell" }
            if let kind = row.kind { passage["kind"] = kind }
            return passage
        }
        let object: [String: Any] = ["format": "gita.season", "version": version, "title": "Lamps", "passages": rows, "strokes": []]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func passages(_ count: Int) -> [(id: String, text: String, tool: String?, kind: String?)] {
        [("P0", opening, nil, nil)] + (1..<count).map { i in
            ("P\(i)", "Passage \(i) begins on the stones by the water. The narrow boat drifts toward her and stops. Nobody rows it, and the lamp inside is warm.",
             i % 3 == 0 ? nil : "pen", i % 3 == 0 ? "dream" : nil)
        }
    }
}

@Suite("Works")
struct WorkTests {
    func work(_ id: String = "demo", seasonCount: Int = 4, narrativeFirst: Bool = true) throws -> Workspace {
        let workspace = try Support.workspace()
        _ = try WorkImport.ensure(id, title: "Lamps", author: "A. Writer", in: workspace)
        if narrativeFirst { _ = try WorkImport.narrative(Synthetic.narrative, name: "Narrative.json", work: id, in: workspace) }
        _ = try WorkImport.season(Synthetic.season(passages: Synthetic.passages(seasonCount)), name: "season.json", work: id, in: workspace)
        if !narrativeFirst { _ = try WorkImport.narrative(Synthetic.narrative, name: "Narrative.json", work: id, in: workspace) }
        return workspace
    }

    @Test("scoped to a work, its text moves under works/<id>/ while models and providers stay shared")
    func scopedPaths() throws {
        let root = Workspace(root: URL(fileURLWithPath: "/r"))
        let scoped = root.scoped(to: "w")
        let ref = ModelRef(company: "acme", model: "m1")
        #expect(scoped.transcriptsFile(ref).path == "/r/works/w/dataset/acme/m1/transcripts.jsonl")
        #expect(scoped.threadDirectory(ref, set: "s").path == "/r/works/w/dataset/acme/m1/threads/s")
        #expect(scoped.promptSetDirectory("s").path == "/r/works/w/prompts/s")
        #expect(scoped.modelFile(ref).path == "/r/dataset/acme/m1/model.json")
        #expect(scoped.providersFile.path == "/r/providers.json")
        #expect(scoped.evidenceDirectory(slug: "x").path == "/r/works/w/evidence/x")
        #expect(root.evidenceDirectory(slug: "x").path == "/r/catalogue/evidence/x")
        #expect(root.transcriptsFile(ref).path == "/r/dataset/acme/m1/transcripts.jsonl")
    }

    @Test("a season imports with origins: the opening that matches the narrative is authored, the rest generated")
    func seasonImport() throws {
        let workspace = try work()
        let passages = try WorkStore.passages("demo", in: workspace)
        #expect(passages.map(\.index) == [0, 1, 2, 3])
        #expect(passages.map(\.origin) == [.authored, .generated, .generated, .generated])
        #expect(passages[1].tool == "pen" && passages[3].isDream && passages[0].createdAt != nil)
        let work = try WorkStore.load("demo", in: workspace)
        #expect(work.terms(for: "authored").trainingUse == .permitted && work.terms(for: "generated").trainingUse == .unknown)
        #expect(work.terms(for: "authored").writer == "A. Writer" && work.isPrivate)
    }

    @Test("importing the narrative after the season still recognises the opening")
    func narrativeAfter() throws {
        let workspace = try work(narrativeFirst: false)
        #expect(try WorkStore.passages("demo", in: workspace).first?.origin == .authored)
    }

    @Test("importing again adds only new passages; a newer format and another format are refused")
    func reimport() throws {
        let workspace = try work()
        let again = try WorkImport.season(Synthetic.season(passages: Synthetic.passages(6)), name: "later.json", work: "demo", in: workspace)
        #expect(again.added == 2 && again.alreadyPresent == 4 && again.total == 6)
        #expect(try WorkStore.passages("demo", in: workspace).map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(throws: LeviathanFailure.self) {
            _ = try WorkImport.season(Synthetic.season(version: 3, passages: Synthetic.passages(2)), name: "new.json", work: "demo", in: workspace)
        }
        #expect(throws: LeviathanFailure.self) {
            _ = try WorkImport.season(Data(#"{"format":"other","version":1,"passages":[]}"#.utf8), name: "x.json", work: "demo", in: workspace)
        }
        let v1 = try WorkImport.season(Synthetic.season(version: 1, passages: [("V1", "An older export's passage, long enough to keep.", nil, nil)]),
                                       name: "v1.json", work: "demo", in: workspace)
        #expect(v1.added == 1)
    }

    @Test("plain text imports as authored passages, one per paragraph, short ones folded in")
    func textImport() throws {
        let workspace = try Support.workspace()
        _ = try WorkImport.ensure("notes", title: nil, author: nil, in: workspace)
        let paragraph = String(repeating: "The tide comes in over the flats and the gulls lift. ", count: 8)
        let summary = try WorkImport.text("\(paragraph)\n\nShort.\n\n\(paragraph)", name: "draft.md", work: "notes", in: workspace)
        #expect(summary.added == 2 && summary.authored == 2)
        #expect(try WorkStore.passages("notes", in: workspace).allSatisfy { $0.source == "text:draft.md" && $0.origin == .authored })
    }

    @Test("a private work's text goes only to a cleared host, with the host's privacy fields merged in")
    func gate() throws {
        let work = Work(id: "w", title: "Lamps")
        var router = ProviderPresets.preset("openrouter")!.provider()
        #expect(throws: LeviathanFailure.self) { try PrivateText.check(router, work: work) }
        do {
            try PrivateText.check(router, work: work)
        } catch let failure as LeviathanFailure {
            #expect(failure.code == LeviathanFailure.ExitCode.noPermission)
        }
        try PrivateText.check(router, work: nil)
        router = try PrivateText.clear(router, allow: true, source: "https://openrouter.ai/docs/features/provider-routing")
        let prepared = try PrivateText.prepare(router, work: work)
        #expect(prepared.extraBody["provider"] == .object(["require_parameters": .bool(true), "data_collection": .string("deny"), "zdr": .bool(true)]))
        #expect(try PrivateText.prepare(router, work: nil).extraBody == router.extraBody)
        #expect(throws: LeviathanFailure.self) { _ = try PrivateText.clear(router, allow: true, source: nil) }

        var deepseek = ProviderPresets.preset("deepseek")!.provider()
        #expect(throws: LeviathanFailure.self) { _ = try PrivateText.clear(deepseek, allow: true, source: "x") }
        deepseek.acceptsPrivateText = true
        #expect(throws: LeviathanFailure.self) { try PrivateText.check(deepseek, work: work) }
        try PrivateText.check(ProviderPresets.preset("ollama")!.provider(), work: work)
    }

    @Test("a JSON prompt's hash covers what is sent, not its reference, and the set's system leads only when it has none")
    func promptFiles() throws {
        let workspace = try Support.workspace()
        let messages = [ChatMessage(role: "user", content: "Edit this.")]
        _ = try PromptStore.add(set: "s", id: "a", file: PromptFile(messages: messages, reference: PromptReference(text: "one", role: .baseline)), in: workspace)
        _ = try PromptStore.add(set: "s", id: "b", file: PromptFile(messages: messages, reference: PromptReference(text: "two", role: .comparison)), in: workspace)
        _ = try PromptStore.add(set: "s", id: "c", file: PromptFile(messages: [ChatMessage(role: "system", content: "Own.")] + messages), in: workspace)
        try PromptStore.saveSettings(PromptSetSettings(), set: "s", in: workspace)
        try PromptStore.setSystem(set: "s", text: "Set system.", in: workspace)
        let set = try PromptStore.load("s", in: workspace)
        #expect(set.prompts.map(\.id) == ["a", "b", "c"])
        let (a, b, c) = (set.prompts[0], set.prompts[1], set.prompts[2])
        #expect(a.sha == b.sha && a.reference?.text == "one" && b.reference?.role == .comparison)
        #expect(a.messages.map(\.role) == ["system", "user"] && a.messages[0].content == "Set system." && a.text == "Edit this.")
        #expect(c.messages.map(\.content) == ["Own.", "Edit this."])
    }

    @Test("a revise passage is built on your text, and the samples are measured against it")
    func referenceBaseline() async throws {
        let workspace = try work()
        _ = try Study.make(.revise, work: "demo", in: workspace)
        let scoped = workspace.scoped(to: "demo")
        let target = ModelTarget(company: "acme", modelID: "m1", providerID: "fake", terms: Terms(trainingUse: .permitted))
        try ModelStore.save(target, in: scoped)
        let set = try PromptStore.load("revise", in: scoped)
        let prompt = try set.prompt("p001")
        let reference = try #require(prompt.reference?.text)
        let edited = reference.replacingOccurrences(of: "narrow", with: "slender")
        let store = TranscriptStore(url: scoped.transcriptsFile(target.ref))
        for (index, text) in [reference, edited, edited].enumerated() {
            try await store.append(Support.record(text, temperature: 0.4, index: index, prompt: prompt, set: "revise"))
        }
        await store.close()
        let source = try ThreadSource.load(scoped, ref: target.ref, set: "revise")
        let passage = try #require(try source.passage(for: prompt))
        #expect(passage.builtOnReference && passage.text == ContentHash.canonical(reference))
        #expect(passage.samples.filter { $0.status == .aligned }.count == 3)
        let area = try #require(passage.areas.first { $0.baselineText.contains("narrow") })
        #expect(area.baselineVariant?.share == 1.0 / 3.0)
        #expect(source.slug.hasPrefix("demo-"))
        // The reference never enters the transcript.
        #expect(try store.read().records.count == 3)
    }

    @Test("an export built on your text takes only passages whose origin is permitted")
    func exportRule() async throws {
        let workspace = try work()
        _ = try Study.make(.revise, work: "demo", in: workspace)
        let scoped = workspace.scoped(to: "demo")
        let target = ModelTarget(company: "acme", modelID: "m1", providerID: "fake", terms: Terms(trainingUse: .permitted))
        try ModelStore.save(target, in: scoped)
        let set = try PromptStore.load("revise", in: scoped)
        let store = TranscriptStore(url: scoped.transcriptsFile(target.ref))
        for prompt in set.prompts {
            try await store.append(Support.record(prompt.reference!.text, temperature: 0, index: 0, prompt: prompt, set: "revise"))
        }
        await store.close()
        let summary = try ThreadExporter.export(try ThreadSource.load(scoped, ref: target.ref, set: "revise"))
        #expect(summary.documents == 1)
        #expect(summary.skipped.map(\.promptID) == ["p001", "p002", "p003"])
        #expect(summary.skipped.allSatisfy { $0.reason.contains("generated") })
    }

    @Test("continue rebuilds the app's request: preamble, cast, the mark's directive, earlier passages as turns, then the mark")
    func continueStudy() throws {
        let workspace = try work(seasonCount: 9)
        _ = try Study.make(.continue, work: "demo", in: workspace)
        let set = try PromptStore.load("continue", in: workspace.scoped(to: "demo"))
        let p8 = try set.prompt("p008")
        let system = p8.messages[0].content
        #expect(system.hasPrefix("Write quiet prose.") && system.contains("CHARACTERS:\n- Mira (keeper): Counts what the harbour forgets."))
        #expect(system.contains("Continue the plot.") && system.contains("STORY OPENING (for continuity): The quiet harbour"))
        #expect(p8.messages.count == 1 + 2 * Study.historyWindow + 1)
        #expect(p8.messages.last?.content == "(pen) Continue from the marked passage: \"a bell\"")
        #expect(p8.reference?.role == .comparison && p8.reference?.origin == "generated")
        let p0 = try set.prompt("p000")
        #expect(p0.messages.map(\.role) == ["system", "user"] && p0.messages[1].content == "Begin.")
        let dream = try set.prompt("p003")
        #expect(dream.messages[0].content.hasSuffix("DREAM: one short passage.") && dream.messages.last?.content == Study.dreamUserTurn)
    }

    @Test("continue needs the narrative; recall cuts at a sentence end and keeps the rest as the baseline")
    func otherStudies() throws {
        let bare = try Support.workspace()
        _ = try WorkImport.ensure("bare", title: nil, author: nil, in: bare)
        _ = try WorkImport.season(Synthetic.season(passages: Synthetic.passages(2)), name: "s.json", work: "bare", in: bare)
        #expect(throws: LeviathanFailure.self) { _ = try Study.make(.continue, work: "bare", in: bare) }
        let summary = try Study.make(.recall, work: "bare", in: bare)
        #expect(summary.prompts == ["p000", "p001"])
        let prompt = try PromptStore.load("recall", in: bare.scoped(to: "bare")).prompt("p001")
        let rest = try #require(prompt.reference?.text)
        // The sentence end nearest 40% of the passage: after its first sentence.
        #expect(prompt.reference?.role == .baseline && rest.hasPrefix("The narrow boat drifts"))
        #expect(prompt.text.hasSuffix("Passage 1 begins on the stones by the water."))
        #expect(Study.split("Too short. To cut.") == nil)
    }
}

@Suite("Spend and refusals")
struct SpendTests {
    func setUp(price: Pricing?) throws -> (Workspace, ModelTarget, PromptSet) {
        let workspace = try Support.workspace()
        var target = ModelTarget(company: "acme", modelID: "m1", providerID: "fake", sampling: SamplingLimits(maxTokens: 1000))
        target.pricing = price
        try ModelStore.save(target, in: workspace)
        for id in ["a", "b", "c", "d", "e", "f"] { _ = try PromptStore.add(set: "s", id: id, text: String(repeating: "x", count: 300), in: workspace) }
        return (workspace, target, try PromptStore.load("s", in: workspace))
    }

    @Test("the estimate bounds the worst case and reads the typical case from earlier answers")
    func estimate() throws {
        let (_, target, set) = try setUp(price: Pricing(inputPerMillion: 10, outputPerMillion: 50))
        let sampling = SamplingPlan(temperatures: [0], samplesPerTemperature: 2)
        let plan = HarvestPlan.make(target: target, prompts: set.prompts, plan: sampling, existing: [])
        let fresh = CostEstimate.make(plan: plan, target: target, sampling: sampling, history: [])
        #expect(fresh.requests == 12 && fresh.inputTokens == 12 * 100 && fresh.worstOutputTokens == 12_000)
        #expect(abs((fresh.worst ?? 0) - (1200 * 10 + 12_000 * 50) / 1e6) < 1e-9)
        #expect(fresh.typicalOutputTokens == 12 * 333)
        var record = Support.record("x", temperature: 0, index: 0, prompt: set.prompts[0], set: "s")
        record.usage = Usage(promptTokens: 1, completionTokens: 200)
        let seen = CostEstimate.make(plan: plan, target: target, sampling: sampling, history: [record])
        #expect(seen.typicalOutputTokens == 12 * 200 && seen.basis.contains("1 earlier answer"))
        let unpriced = CostEstimate.make(plan: plan, target: ModelTarget(company: "a", modelID: "b", providerID: "c"), sampling: sampling, history: [])
        #expect(unpriced.worst == nil && unpriced.summary.hasPrefix("cost unknown"))
    }

    @Test("a run stops launching once the reported spend reaches its limit")
    func spendStop() async throws {
        let (workspace, target, set) = try setUp(price: Pricing(inputPerMillion: 0, outputPerMillion: 1_000_000))
        let client = FakeClient { _ in ChatCompletion(content: "ok", finishReason: "stop", usage: Usage(promptTokens: 1, completionTokens: 1)) }
        let provider = Provider(id: "fake", name: "Fake", baseURL: "http://localhost:1/v1", maxConcurrent: 1)
        let harvester = Harvester(target: target, provider: provider, set: set, client: client, store: TranscriptStore(url: workspace.transcriptsFile(target.ref)))
        let sampling = SamplingPlan(temperatures: [0], samplesPerTemperature: 1)
        let plan = HarvestPlan.make(target: target, prompts: set.prompts, plan: sampling, existing: [])
        let summary = try await harvester.run(plan, sampling: sampling, runID: "r", maxSpend: 3)
        #expect(summary.completed == 3 && summary.spent == 3)
        #expect(summary.stop?.code == LeviathanFailure.ExitCode.tempFail)
    }

    @Test("refusals are recorded, never retried, set aside, and five stop the run")
    func refusals() async throws {
        let (workspace, target, set) = try setUp(price: nil)
        let client = FakeClient { _ in ChatCompletion(content: "", finishReason: "refusal", usage: Usage(promptTokens: 1, completionTokens: 0)) }
        let provider = Provider(id: "fake", name: "Fake", baseURL: "http://localhost:1/v1", maxConcurrent: 1)
        let store = TranscriptStore(url: workspace.transcriptsFile(target.ref))
        let harvester = Harvester(target: target, provider: provider, set: set, client: client, store: store)
        let sampling = SamplingPlan(temperatures: [0], samplesPerTemperature: 1)
        let summary = try await harvester.run(HarvestPlan.make(target: target, prompts: set.prompts, plan: sampling, existing: []), sampling: sampling, runID: "r")
        #expect(summary.refused == 5 && summary.requested == 5 && summary.stop?.code == LeviathanFailure.ExitCode.noPermission)
        #expect(try store.read().records.count == 5)
        #expect(PassageBuilder.setAsideReason(Support.record("A real answer.", temperature: 0, index: 0, prompt: Support.prompt, finish: "refusal"),
                                              text: "A real answer.") == "refused")
    }
}
