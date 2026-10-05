//
//  PassageStore.swift
//  LeviathonCore
//
//  WHAT: Builds the passages of one Thread (a model on a prompt set) from its transcript, and
//        reads and writes them under threads/<set>/passages/.
//  PIN:  A passage is built from the records whose prompt hash matches the prompt as it is
//        now, on the baseline the prompt's latest resolution names when there is one. Passage
//        files are derived and replaced on every derive; a prompt with no records loses its file.
//

import Foundation

public struct ThreadSource: Sendable {
    public var workspace: Workspace
    public var target: ModelTarget
    public var set: PromptSet
    public var records: [TranscriptRecord]
    public var unreadableLines: [Int]
    public var resolutions: [Resolution]

    public var ref: ModelRef { target.ref }
    public var slug: String { PathComponent.slug([ref.company, ref.model, set.id]) }

    /// Loads everything one Thread is derived from.
    public static func load(_ workspace: Workspace, ref: ModelRef, set: String) throws -> ThreadSource {
        let target = try ModelStore.load(ref, in: workspace)
        let promptSet = try PromptStore.load(set, in: workspace)
        let contents = try TranscriptStore.read(workspace.transcriptsFile(ref))
        return ThreadSource(workspace: workspace, target: target, set: promptSet,
                            records: contents.records.filter { $0.pack == set }, unreadableLines: contents.unreadable,
                            resolutions: try EditStore.all(workspace, ref: ref, set: set))
    }

    public func records(for prompt: Prompt) -> [TranscriptRecord] {
        records.filter { $0.task.promptSHA == prompt.sha }
    }

    public func resolution(for prompt: Prompt) -> Resolution? {
        EditStore.latest(resolutions, promptID: prompt.id, promptSHA: prompt.sha)
    }

    /// The prompt's passage, or nil when it has no records yet.
    public func passage(for prompt: Prompt, parameters: PassageParameters = PassageParameters(), baseline: String? = nil) throws -> Passage? {
        let records = records(for: prompt)
        guard !records.isEmpty else { return nil }
        return try PassageBuilder.build(set: set.id, model: ref.description, prompt: prompt, records: records,
                                        baselineRecordID: baseline ?? resolution(for: prompt)?.baselineRecordID, parameters: parameters)
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
            throw LeviathonFailure("no passage for \(prompt) yet", hint: "leviathon derive --set \(set) --model \(ref)",
                                   code: LeviathonFailure.ExitCode.noInput)
        }
        return try JSONCoding.read(Passage.self, from: url)
    }
}
