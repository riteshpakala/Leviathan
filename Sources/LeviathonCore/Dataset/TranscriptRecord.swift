//
//  TranscriptRecord.swift
//  LeviathonCore
//
//  WHAT: One generation, as appended to dataset/<company>/<model-id>/transcripts.jsonl: the
//        prompt, the teacher, the sampling point, the response, and its lineage.
//  PIN:  The system of record. Everything else Leviathon writes is derived from these lines.
//        `verification` and `judge` are reserved for the stages the Fable design adds later.
//        A sample point is (prompt hash, temperature, sample index): a run that finds one
//        already present skips it.
//

import Foundation

public struct TranscriptTask: Codable, Sendable, Hashable {
    public var promptID: String
    public var promptSHA: String
    public var messages: [ChatMessage]
}

public struct Teacher: Codable, Sendable, Hashable {
    public var company: String
    public var modelID: String
    public var provider: String
    public var baseURL: String
    public var requestModel: String
    /// The model the host said answered, when it said.
    public var reportedModel: String?
}

public struct SamplingPoint: Codable, Sendable, Hashable {
    /// Nil when no temperature was sent (the host's default applied).
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var seed: Int?
    public var sampleIndex: Int

    /// The temperature as a key: three decimals, or "default".
    public var temperatureKey: String { SamplingPoint.key(temperature) }

    public static func key(_ temperature: Double?) -> String {
        temperature.map { String(format: "%.3f", $0) } ?? "default"
    }
}

public struct Lineage: Codable, Sendable, Hashable {
    /// How the prompt came to be: "manual" for a prompt file a person wrote.
    public var synthesisMethod: String
    public var seedID: String?
    public var trainingUse: TrainingUse
    public var licence: String?
}

public struct RawExchange: Codable, Sendable, Hashable {
    public var request: JSONValue
    public var response: JSONValue
}

public struct TranscriptRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var runID: String
    /// The prompt set.
    public var pack: String
    public var task: TranscriptTask
    public var teacher: Teacher
    public var sampling: SamplingPoint
    public var response: String
    public var trace: String?
    public var finishReason: String?
    public var usage: Usage?
    public var latencyMS: Int
    public var logprobs: [TokenLogprob]?
    public var verification: JSONValue?
    public var judge: JSONValue?
    public var lineage: Lineage
    public var raw: RawExchange?

    public var key: SampleKey { SampleKey(promptSHA: task.promptSHA, temperature: sampling.temperatureKey, sampleIndex: sampling.sampleIndex) }
}

public struct SampleKey: Hashable, Sendable, Codable {
    public var promptSHA: String
    public var temperature: String
    public var sampleIndex: Int
}
