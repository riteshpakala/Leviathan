//
//  ModelTarget.swift
//  LeviathanCore
//
//  WHAT: A model Leviathan samples: who made it, which provider serves it, what to send on the
//        wire, whether it takes a temperature and over what range, and the terms its outputs
//        come under. Stored as dataset/<company>/<model-id>/model.json.
//  PIN:  `company` is the model's maker, not the host: a Mistral model served by OpenRouter is
//        filed under mistralai. The folder names are sanitized; the exact ids stay here.
//

import Foundation

/// A model's folder: dataset/<company>/<model>.
public struct ModelRef: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public var company: String
    public var model: String

    public init(company: String, model: String) {
        self.company = PathComponent.sanitize(company)
        self.model = PathComponent.sanitize(model)
    }

    /// Parses `company/model`.
    public init(parsing text: String) throws {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw LeviathanFailure("'\(text)' is not company/model", hint: "for example qwen/qwen2.5-14b", code: LeviathanFailure.ExitCode.usage)
        }
        self.init(company: parts[0], model: parts[1])
    }

    public var description: String { "\(company)/\(model)" }

    public static func < (lhs: ModelRef, rhs: ModelRef) -> Bool { lhs.description < rhs.description }
}

public enum TemperatureMode: String, Codable, Sendable, CaseIterable {
    /// The model takes a temperature within `minTemperature...maxTemperature`.
    case range
    /// The model rejects or ignores a temperature: no temperature is sent, and samples repeat at
    /// the host's default.
    case defaultOnly
}

public enum MaxTokensField: String, Codable, Sendable, CaseIterable {
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"
}

public struct SamplingLimits: Codable, Sendable, Hashable {
    public var temperature: TemperatureMode
    public var minTemperature: Double
    public var maxTemperature: Double
    /// Max tokens per response when a plan does not say.
    public var maxTokens: Int
    public var maxTokensField: MaxTokensField
    /// Ask the host for token log-probabilities.
    public var logprobs: Bool

    public init(temperature: TemperatureMode = .range, minTemperature: Double = 0, maxTemperature: Double = 2, maxTokens: Int = 1024,
                maxTokensField: MaxTokensField = .maxTokens, logprobs: Bool = false) {
        self.temperature = temperature
        self.minTemperature = minTemperature
        self.maxTemperature = maxTemperature
        self.maxTokens = maxTokens
        self.maxTokensField = maxTokensField
        self.logprobs = logprobs
    }

    public func accepts(_ temperature: Double) -> Bool {
        self.temperature == .range && temperature >= minTemperature - 1e-9 && temperature <= maxTemperature + 1e-9
    }
}

public enum TrainingUse: String, Codable, Sendable, CaseIterable {
    /// Its licence lets you train on its outputs; Thread exports are allowed.
    case permitted
    /// Its terms bar training on its outputs; it is measured but never exported.
    case prohibited
    /// Not yet checked; treated as prohibited for export.
    case unknown
}

public struct Terms: Codable, Sendable, Hashable {
    public var trainingUse: TrainingUse
    public var licence: String?
    /// Where the licence or terms were read.
    public var source: String?
    public var note: String?

    public init(trainingUse: TrainingUse = .unknown, licence: String? = nil, source: String? = nil, note: String? = nil) {
        self.trainingUse = trainingUse
        self.licence = licence
        self.source = source
        self.note = note
    }
}

/// What a model costs on its host, in dollars per million tokens.
public struct Pricing: Codable, Sendable, Hashable {
    public var inputPerMillion: Double?
    public var outputPerMillion: Double?
    /// Where the prices came from: the host's model list, or a person.
    public var source: String?

    public init(inputPerMillion: Double? = nil, outputPerMillion: Double? = nil, source: String? = nil) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.source = source
    }

    /// Dollars for a request of this many tokens; nil when a price it needs is unknown.
    public func cost(input: Int, output: Int) -> Double? {
        guard let inputPerMillion, let outputPerMillion else { return nil }
        return (Double(input) * inputPerMillion + Double(output) * outputPerMillion) / 1_000_000
    }
}

public struct ModelTarget: Codable, Sendable, Hashable {
    /// The maker, as written (folder name is sanitized from it).
    public var company: String
    /// The model's id, as written (folder name is sanitized from it).
    public var modelID: String
    public var providerID: String
    /// What goes in the request's `model` field.
    public var requestModel: String
    public var sampling: SamplingLimits
    public var terms: Terms
    public var pricing: Pricing?
    public var notes: String?

    public init(company: String, modelID: String, providerID: String, requestModel: String? = nil,
                sampling: SamplingLimits = SamplingLimits(), terms: Terms = Terms(), pricing: Pricing? = nil, notes: String? = nil) {
        self.company = company
        self.modelID = modelID
        self.providerID = providerID
        self.requestModel = requestModel ?? modelID
        self.sampling = sampling
        self.terms = terms
        self.pricing = pricing
        self.notes = notes
    }

    public var ref: ModelRef { ModelRef(company: company, model: modelID) }
}

public enum ModelStore {
    public static func load(_ ref: ModelRef, in workspace: Workspace) throws -> ModelTarget {
        let url = workspace.modelFile(ref)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LeviathanFailure("no model \(ref) (no \(workspace.relative(url)))", hint: "leviathan models add",
                                   code: LeviathanFailure.ExitCode.noInput)
        }
        do {
            return try JSONCoding.read(ModelTarget.self, from: url)
        } catch {
            throw LeviathanFailure("\(workspace.relative(url)) is malformed: \(error)", code: LeviathanFailure.ExitCode.data)
        }
    }

    public static func save(_ target: ModelTarget, in workspace: Workspace) throws {
        try JSONCoding.write(target, to: workspace.modelFile(target.ref))
    }

    /// Every model with a model.json, sorted by company and model.
    public static func all(in workspace: Workspace) -> [ModelTarget] {
        let manager = FileManager.default
        let dataset = workspace.datasetDirectory
        guard let companies = try? manager.contentsOfDirectory(atPath: dataset.path) else { return [] }
        var targets: [ModelTarget] = []
        for company in companies.sorted() where !company.hasPrefix(".") {
            let companyURL = dataset.appendingPathComponent(company, isDirectory: true)
            guard let models = try? manager.contentsOfDirectory(atPath: companyURL.path) else { continue }
            for model in models.sorted() where !model.hasPrefix(".") {
                let file = companyURL.appendingPathComponent(model).appendingPathComponent("model.json")
                if let target = try? JSONCoding.read(ModelTarget.self, from: file) { targets.append(target) }
            }
        }
        return targets
    }
}
