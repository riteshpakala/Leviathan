import Foundation
@testable import LeviathanCore

/// Builders shared by the tests.
enum Support {
    static func record(_ response: String, temperature: Double?, index: Int, prompt: Prompt, set: String = "s",
                       finish: String? = "stop", logprobs: [TokenLogprob]? = nil, seconds: Double = 0) -> TranscriptRecord {
        TranscriptRecord(
            id: "r-\(SamplingPoint.key(temperature))-\(index)", createdAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds), runID: "run",
            pack: set, task: TranscriptTask(promptID: prompt.id, promptSHA: prompt.sha, messages: prompt.messages),
            teacher: Teacher(company: "acme", modelID: "m1", provider: "mock", baseURL: "http://localhost", requestModel: "m1", reportedModel: nil),
            sampling: SamplingPoint(temperature: temperature, topP: nil, maxTokens: 256, seed: nil, sampleIndex: index),
            response: response, trace: nil, finishReason: finish, usage: nil, latencyMS: 1, logprobs: logprobs, verification: nil, judge: nil,
            lineage: Lineage(synthesisMethod: "manual", seedID: nil, trainingUse: .permitted, licence: "test"), raw: nil)
    }

    static let prompt = Prompt(id: "p1", text: "Describe the drone.", system: nil)

    /// Records from (temperature, response) pairs, indices counted per temperature.
    static func records(_ rows: [(Double?, String)], prompt: Prompt = Support.prompt) -> [TranscriptRecord] {
        var counts: [String: Int] = [:]
        return rows.enumerated().map { offset, row in
            let key = SamplingPoint.key(row.0)
            let index = counts[key, default: 0]
            counts[key] = index + 1
            return record(row.1, temperature: row.0, index: index, prompt: prompt, seconds: Double(offset))
        }
    }

    static func passage(_ rows: [(Double?, String)], parameters: PassageParameters = PassageParameters()) throws -> Passage {
        try PassageBuilder.build(set: "s", model: "acme/m1", prompt: prompt, records: records(rows), parameters: parameters)
    }

    /// A fresh workspace in a temporary directory.
    static func workspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leviathan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let package = Package(\n    name: \"Leviathan\"\n)\n".utf8).write(to: root.appendingPathComponent("Package.swift"))
        return Workspace(root: root)
    }

    static func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/raolm/\(name)", withExtension: nil) else {
            throw LeviathanFailure("missing fixture \(name)")
        }
        return url
    }

    static func fixtureDocuments() throws -> [(url: URL, data: Data)] {
        guard let directory = Bundle.module.url(forResource: "Fixtures/raolm", withExtension: nil) else {
            throw LeviathanFailure("missing fixtures")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        return try names.map { name in
            let url = directory.appendingPathComponent(name)
            return (url, try Data(contentsOf: url))
        }
    }
}
