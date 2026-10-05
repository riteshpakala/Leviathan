//
//  ModelCommands.swift
//  LeviathonCLI
//
//  WHAT: leviathon models list | add | fetch | terms — the models Leviathon samples.
//  PIN:  `add` creates a model or updates the fields given, starting from its provider's preset.
//        New models start under the preset's terms: `prohibited` for closed APIs, `unknown`
//        otherwise. `terms` is the only way to mark one `permitted`, after reading its licence.
//

import ArgumentParser
import Foundation
import LeviathonCore

extension TrainingUse: ExpressibleByArgument {}
extension MaxTokensField: ExpressibleByArgument {}

struct ModelsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models", abstract: "List, add and update the models Leviathon samples.",
        subcommands: [List.self, Add.self, Fetch.self, SetTerms.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the models under dataset/.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let targets = ModelStore.all(in: workspace)
                let rows = targets.map { target -> [String] in
                    let limits = target.sampling
                    return [target.ref.description, target.providerID, target.requestModel,
                            limits.temperature == .defaultOnly ? "default only"
                                : "\(Output.temperature(limits.minTemperature))–\(Output.temperature(limits.maxTemperature))",
                            target.terms.trainingUse.rawValue]
                }
                try global.emit(targets, targets.isEmpty ? "no models (leviathon models add …)"
                    : Output.table(["model", "provider", "request model", "temperature", "terms"], rows))
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a model, or update the fields given on one that exists.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "The provider that serves it.")
        var provider: String

        @Option(help: "The model's maker (its folder under dataset/), not the host.")
        var company: String

        @Option(help: "The model's id as you name it (its folder under dataset/<company>/).")
        var model: String

        @Option(help: "What to send in the request's model field (default: --model).")
        var requestModel: String?

        @Option(help: "Lowest temperature the model takes.")
        var minTemperature: Double?

        @Option(help: "Highest temperature the model takes.")
        var maxTemperature: Double?

        @Flag(help: "The model takes no temperature: sample it repeatedly at the host's default.")
        var defaultOnly = false

        @Flag(help: "The model takes a temperature (undoes --default-only).")
        var takesTemperature = false

        @Option(help: "Max tokens per response.")
        var maxTokens: Int?

        @Option(help: "The request field for max tokens: max_tokens or max_completion_tokens.")
        var maxTokensField: MaxTokensField?

        @Flag(inversion: .prefixedNo, help: "Ask the host for token log-probabilities.")
        var logprobs: Bool?

        @Option(help: "permitted, prohibited or unknown.")
        var trainingUse: TrainingUse?

        @Option(help: "The model's licence.")
        var licence: String?

        @Option(help: "Where the licence or terms were read.")
        var termsSource: String?

        @Option(help: "A note kept with the model.")
        var note: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let host = try ProviderStore.provider(provider, in: workspace)
                let ref = ModelRef(company: company, model: model)
                let existing = try? ModelStore.load(ref, in: workspace)
                let preset = host.preset.flatMap(ProviderPresets.preset)
                var target = existing ?? ModelTarget(
                    company: company, modelID: model, providerID: host.id, requestModel: requestModel,
                    sampling: preset?.sampling ?? SamplingLimits(), terms: Terms(trainingUse: preset?.trainingUse ?? .unknown))
                target.providerID = host.id
                if let requestModel { target.requestModel = requestModel }
                if let minTemperature { target.sampling.minTemperature = minTemperature }
                if let maxTemperature { target.sampling.maxTemperature = maxTemperature }
                if defaultOnly { target.sampling.temperature = .defaultOnly }
                if takesTemperature { target.sampling.temperature = .range }
                if let maxTokens { target.sampling.maxTokens = maxTokens }
                if let maxTokensField { target.sampling.maxTokensField = maxTokensField }
                if let logprobs { target.sampling.logprobs = logprobs }
                if let trainingUse { target.terms.trainingUse = trainingUse }
                if let licence { target.terms.licence = licence }
                if let termsSource { target.terms.source = termsSource }
                if let note { target.notes = note }
                guard target.sampling.minTemperature <= target.sampling.maxTemperature else {
                    throw LeviathonFailure("the temperature range is empty", code: LeviathonFailure.ExitCode.usage)
                }
                try ModelStore.save(target, in: workspace)
                let limits = target.sampling
                try global.emit(target, "\(existing == nil ? "added" : "updated") \(target.ref) on \(host.id) as '\(target.requestModel)': "
                    + (limits.temperature == .defaultOnly ? "default temperature only"
                        : "temperature \(Output.temperature(limits.minTemperature))–\(Output.temperature(limits.maxTemperature))")
                    + ", terms \(target.terms.trainingUse.rawValue)"
                    + (target.terms.trainingUse == .permitted ? "" : " (Thread export refused until marked permitted)"))
            }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the model ids a provider serves (GET /models).")
        @OptionGroup var global: GlobalOptions

        @Option(help: "The provider's id.")
        var provider: String

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let host = try ProviderStore.provider(provider, in: workspace)
                let (key, _) = APIKeyResolver.resolve(host, store: KeychainSecretStore())
                let models = try await OpenAICompatibleClient(provider: host, apiKey: key, retry: RetryPolicy(maxAttempts: 2)).listModels()
                try global.emit(models, models.joined(separator: "\n"))
            }
        }
    }

    struct SetTerms: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "terms", abstract: "Set the terms a model's outputs come under.")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The model, as company/model.")
        var model: String

        @Option(help: "permitted, prohibited or unknown.")
        var trainingUse: TrainingUse

        @Option(help: "The model's licence.")
        var licence: String?

        @Option(help: "Where the licence or terms were read.")
        var source: String?

        @Option(help: "A note on the terms.")
        var note: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                var target = try ModelStore.load(try ModelRef(parsing: model), in: workspace)
                target.terms.trainingUse = trainingUse
                if let licence { target.terms.licence = licence }
                if let source { target.terms.source = source }
                if let note { target.terms.note = note }
                try ModelStore.save(target, in: workspace)
                try global.emit(target.terms, "\(target.ref): training use \(trainingUse.rawValue)"
                    + (target.terms.licence.map { ", licence \($0)" } ?? ""))
            }
        }
    }
}
