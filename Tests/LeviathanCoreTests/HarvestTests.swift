import Foundation
import Testing
@testable import LeviathanCore

/// A host that answers from a function of the request, with no network.
struct FakeClient: ChatClient {
    let answer: @Sendable (ChatRequest) throws -> ChatCompletion

    func complete(_ request: ChatRequest) async throws -> ChatCompletion { try answer(request) }
    func listModels() async throws -> [String] { ["m1"] }
}

@Suite("Transcripts and harvest")
struct HarvestTests {
    func setUp() throws -> (Workspace, ModelTarget, Provider, PromptSet) {
        let workspace = try Support.workspace()
        let target = ModelTarget(company: "Acme", modelID: "m1:7b", providerID: "fake",
                                 sampling: SamplingLimits(minTemperature: 0, maxTemperature: 1), terms: Terms(trainingUse: .permitted))
        try ModelStore.save(target, in: workspace)
        _ = try PromptStore.add(set: "writing", id: "drone", text: "Describe the drone.", in: workspace)
        _ = try PromptStore.add(set: "writing", id: "ridge", text: "Describe the ridge.", in: workspace)
        let provider = Provider(id: "fake", name: "Fake", baseURL: "http://localhost:1/v1")
        return (workspace, target, provider, try PromptStore.load("writing", in: workspace))
    }

    @Test("a model's folder is its sanitized company and id")
    func folders() throws {
        let (workspace, target, _, _) = try setUp()
        #expect(target.ref.description == "Acme/m1-7b")
        #expect(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("dataset/Acme/m1-7b/model.json").path))
        #expect(ModelStore.all(in: workspace).map(\.modelID) == ["m1:7b"])
    }

    @Test("out-of-range temperatures are dropped and reported; default-only models sample at the default")
    func plan() throws {
        let (_, target, _, set) = try setUp()
        let plan = HarvestPlan.make(target: target, prompts: set.prompts, plan: SamplingPlan(), existing: [])
        #expect(plan.dropped == [1.2])
        #expect(plan.pending.count == 2 * 3 * 3)
        var defaultOnly = target
        defaultOnly.sampling.temperature = .defaultOnly
        let repeated = HarvestPlan.make(target: defaultOnly, prompts: set.prompts, plan: SamplingPlan(), existing: [])
        #expect(repeated.pending.count == 2 * 12)
        #expect(repeated.pending.allSatisfy { $0.temperature == nil })
    }

    @Test("a harvest appends every sample, and running again skips what is there")
    func harvestAndResume() async throws {
        let (workspace, target, provider, set) = try setUp()
        let client = FakeClient { request in
            ChatCompletion(content: "Answer at \(request.temperature ?? -1).", finishReason: "stop", usage: Usage(promptTokens: 4, completionTokens: 5))
        }
        let store = TranscriptStore(url: workspace.transcriptsFile(target.ref))
        let harvester = Harvester(target: target, provider: provider, set: set, client: client, store: store)
        let sampling = SamplingPlan(temperatures: [0, 0.8], samplesPerTemperature: 2)
        let first = HarvestPlan.make(target: target, prompts: set.prompts, plan: sampling, existing: [])
        let summary = try await harvester.run(first, sampling: sampling, runID: "r1")
        #expect(summary.completed == 8 && summary.stop == nil && summary.completionTokens == 40)
        let contents = try store.read()
        #expect(contents.records.count == 8)
        #expect(Set(contents.records.map(\.key)).count == 8)
        #expect(contents.records.allSatisfy { $0.lineage.trainingUse == .permitted && $0.pack == "writing" })
        let again = HarvestPlan.make(target: target, prompts: set.prompts, plan: sampling, existing: Set(contents.records.map(\.key)))
        #expect(again.pending.isEmpty && again.skipped == 8)
    }

    @Test("a rejected temperature stops the run with a config code, keeping what completed")
    func temperatureRejected() async throws {
        let (workspace, target, provider, set) = try setUp()
        let client = FakeClient { request in
            if request.temperature ?? 0 > 0 { throw ChatError.http(status: 400, message: "Unsupported parameter: temperature") }
            return ChatCompletion(content: "ok", finishReason: "stop")
        }
        var single = provider
        single.maxConcurrent = 1
        let store = TranscriptStore(url: workspace.transcriptsFile(target.ref))
        let sampling = SamplingPlan(temperatures: [0, 0.8], samplesPerTemperature: 1)
        let plan = HarvestPlan.make(target: target, prompts: Array(set.prompts.prefix(1)), plan: sampling, existing: [])
        let summary = try await Harvester(target: target, provider: single, set: set, client: client, store: store)
            .run(plan, sampling: sampling, runID: "r1")
        #expect(summary.completed == 1)
        #expect(summary.stop?.code == LeviathanFailure.ExitCode.config)
        #expect(try store.read().records.count == 1)
    }

    @Test("a torn last line is reported, and the next append starts a fresh line")
    func tornTail() async throws {
        let workspace = try Support.workspace()
        let url = workspace.root.appendingPathComponent("t.jsonl")
        let record = Support.record("Hello.", temperature: 0, index: 0, prompt: Support.prompt)
        try Data((try JSONCoding.line(record) + "\n{\"id\":\"torn").utf8).write(to: url)
        let store = TranscriptStore(url: url)
        #expect(try store.read().unreadable == [2])
        var second = record
        second.id = "second"
        try await store.append(second)
        await store.close()
        let contents = try store.read()
        #expect(contents.records.map(\.id) == [record.id, "second"])
        #expect(contents.unreadable == [2])
    }

    @Test("folder names and slugs keep to their alphabets")
    func names() {
        #expect(PathComponent.sanitize("qwen2.5:14b") == "qwen2.5-14b")
        #expect(PathComponent.sanitize("../evil") == "evil")
        #expect(PathComponent.sanitize("::") == "unnamed")
        #expect(throws: LeviathanFailure.self) { try PromptStore.load("../outside", in: Workspace(root: URL(fileURLWithPath: "/tmp"))) }
        #expect(PathComponent.slug(["Qwen", "qwen2.5-14b", "writing"]) == "qwen-qwen2-5-14b-writing")
        let long = PathComponent.slug(["company", String(repeating: "model", count: 20), "set"])
        #expect(long.count == PathComponent.slugLimit)
        #expect(DocumentID.isValidHandle("raolm-" + long))
        #expect(long != PathComponent.slug(["company", String(repeating: "model", count: 21), "set"]))
    }

    @Test("the workspace root is found from inside it, and not from elsewhere")
    func root() throws {
        let workspace = try Support.workspace()
        let inner = workspace.root.appendingPathComponent("dataset/a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let found = try Workspace.resolve(environment: [:], workingDirectory: inner, buildCheckout: nil)
        #expect(found.workspace.root.path == workspace.root.standardizedFileURL.path && found.source == .workingDirectory)
        #expect(throws: LeviathanFailure.self) {
            try Workspace.resolve(environment: [:], workingDirectory: URL(fileURLWithPath: "/"), buildCheckout: nil)
        }
    }
}
