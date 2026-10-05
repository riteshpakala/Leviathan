//
//  PassageStore.swift
//  LeviathanCore
//
//  WHAT: Builds the passages of one Thread (a model on a prompt set) from its transcript, and
//        reads and writes them under threads/<set>/passages/.
//  PIN:  A passage is built from the records whose prompt hash matches the prompt as it is
//        now, on the baseline the prompt's latest resolution names when there is one. Passage
//        files are derived and replaced on every derive; a prompt with no records loses its file.
//        A prompt whose reference is a baseline (your own passage) is built on that text: it
//        joins as a record of its own, never written to the transcript, and the models'
//        samples are measured against it.
//

import Foundation

public struct ThreadSource: Sendable {
    public var workspace: Workspace
    public var target: ModelTarget
    public var set: PromptSet
    public var records: [TranscriptRecord]
    public var unreadableLines: [Int]
    public var resolutions: [Resolution]
    /// The work this Thread belongs to, when the workspace is scoped to one.
    public var work: Work?

    public static let referencePrefix = "reference-"

    /// Your text as a record the passage can be built on, for a prompt whose reference is a baseline.
    public func referenceRecord(for prompt: Prompt) -> TranscriptRecord? {
        guard let reference = prompt.reference, reference.role == .baseline else { return nil }
        return TranscriptRecord(
            id: Self.referencePrefix + String(prompt.sha.dropFirst("sha256:".count).prefix(16)), createdAt: Date(timeIntervalSince1970: 0),
            runID: "reference", pack: set.id, task: TranscriptTask(promptID: prompt.id, promptSHA: prompt.sha, messages: prompt.messages),
            teacher: Teacher(company: "author", modelID: "reference", provider: "reference", baseURL: "", requestModel: "reference", reportedModel: nil),
            sampling: SamplingPoint(temperature: nil, topP: nil, maxTokens: nil, seed: nil, sampleIndex: 0), response: reference.text, trace: nil,
            finishReason: "stop", usage: nil, latencyMS: 0, logprobs: nil, verification: nil, judge: nil,
            lineage: Lineage(synthesisMethod: "reference", seedID: reference.passageID, trainingUse: work?.terms(for: reference.origin).trainingUse ?? .unknown,
                             licence: nil),
            raw: nil)
    }

    public var ref: ModelRef { target.ref }
    /// Inside a work the slug leads with the work, so its Threads never share ids with the root's.
    public var slug: String { PathComponent.slug((workspace.work.map { [$0] } ?? []) + [ref.company, ref.model, set.id]) }

    /// Loads everything one Thread is derived from.
    public static func load(_ workspace: Workspace, ref: ModelRef, set: String) throws -> ThreadSource {
        let target = try ModelStore.load(ref, in: workspace)
        let promptSet = try PromptStore.load(set, in: workspace)
        let contents = try TranscriptStore.read(workspace.transcriptsFile(ref))
        return ThreadSource(workspace: workspace, target: target, set: promptSet,
                            records: contents.records.filter { $0.pack == set }, unreadableLines: contents.unreadable,
                            resolutions: try EditStore.all(workspace, ref: ref, set: set),
                            work: try workspace.work.map { try WorkStore.load($0, in: workspace) })
    }

    public func records(for prompt: Prompt) -> [TranscriptRecord] {
        records.filter { $0.task.promptSHA == prompt.sha }
    }

    public func resolution(for prompt: Prompt) -> Resolution? {
        EditStore.latest(resolutions, promptID: prompt.id, promptSHA: prompt.sha)
    }

    /// The prompt's passage, or nil when it has no records yet.
    public func passage(for prompt: Prompt, parameters: PassageParameters = PassageParameters(), baseline: String? = nil) throws -> Passage? {
        var records = records(for: prompt)
        guard !records.isEmpty else { return nil }
        let reference = referenceRecord(for: prompt)
        if let reference { records.append(reference) }
        return try PassageBuilder.build(set: set.id, model: ref.description, prompt: prompt, records: records,
                                        baselineRecordID: baseline ?? resolution(for: prompt)?.baselineRecordID ?? reference?.id, parameters: parameters)
    }
}

public struct DeriveSummary: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public var promptID: String
        public var samples: Int
        public var aligned: Int
        public var divergent: Int
        public var setAside: Int
        public var areas: Int
        public var expectations: Int
        public var lockedShare: Double
        public var file: String
    }

    public var model: String
    public var set: String
    public var passages: [Row]
    /// Prompts with no records for their current text.
    public var unharvested: [String]
    public var unreadableLines: [Int]
}

public enum PassageStore {
    public static func derive(_ source: ThreadSource, parameters: PassageParameters = PassageParameters()) throws -> DeriveSummary {
        let directory = source.workspace.passagesDirectory(source.ref, set: source.set.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rows: [DeriveSummary.Row] = []
        var unharvested: [String] = []
        var written = Set<String>()
        for prompt in source.set.prompts {
            guard let passage = try source.passage(for: prompt, parameters: parameters) else {
                unharvested.append(prompt.id)
                continue
            }
            let url = source.workspace.passageFile(source.ref, set: source.set.id, prompt: prompt.id)
            try JSONCoding.write(passage, to: url)
            written.insert(url.lastPathComponent)
            rows.append(DeriveSummary.Row(
                promptID: prompt.id, samples: passage.measures.samples, aligned: passage.measures.aligned,
                divergent: passage.measures.divergent, setAside: passage.measures.setAside, areas: passage.areas.count,
                expectations: passage.expectations.count, lockedShare: passage.measures.lockedShare, file: source.workspace.relative(url)))
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".json") && !written.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return DeriveSummary(model: source.ref.description, set: source.set.id, passages: rows, unharvested: unharvested,
                             unreadableLines: source.unreadableLines)
    }

    public static func load(_ workspace: Workspace, ref: ModelRef, set: String, prompt: String) throws -> Passage {
        let url = workspace.passageFile(ref, set: set, prompt: prompt)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LeviathanFailure("no passage for \(prompt) yet", hint: "leviathan derive --set \(set) --model \(ref)",
                                   code: LeviathanFailure.ExitCode.noInput)
        }
        return try JSONCoding.read(Passage.self, from: url)
    }
}
