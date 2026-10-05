//
//  ModelCommands.swift
//  LeviathanCLI
//
//  WHAT: leviathan models list | add | fetch | terms — the models Leviathan samples.
//  PIN:  `add` creates a model or updates the fields given, starting from its provider's preset.
//        New models start under the preset's terms: `prohibited` for closed APIs, `unknown`
//        otherwise. `terms` is the only way to mark one `permitted`, after reading its licence.
//

import ArgumentParser
import Foundation
import LeviathanCore

extension TrainingUse: ExpressibleByArgument {}
extension MaxTokensField: ExpressibleByArgument {}

struct ModelsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models", abstract: "List, add and update the models Leviathan samples.",
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
                try global.emit(targets, targets.isEmpty ? "no models (leviathan models add …)"
                    : Output.table(["model", "provider", "request model", "temperature", "terms"], rows))
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a model, or update the fields given on one that exists.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "The provider that serves it.")
        var provider: String

        @Option(help: "Fill everything but the terms from the host's model list: the id the host lists (leviathan models fetch --details).")
        var fromCatalogue: String?

        @Option(help: "The model's maker (its folder under dataset/), not the host.")
        var company: String?

        @Option(help: "The model's id as you name it (its folder under dataset/<company>/).")
        var model: String?

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

        @Option(help: "Price per million input tokens, in dollars.")
        var inputPrice: Double?

        @Option(help: "Price per million output tokens, in dollars.")
        var outputPrice: Double?

        @Option(help: "A note kept with the model.")
        var note: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let host = try ProviderStore.provider(provider, in: workspace)
                var suggested: ModelTarget?
                if let fromCatalogue {
                    let (key, _) = APIKeyResolver.resolve(host, store: KeychainSecretStore())
                    let catalogue = try await OpenAICompatibleClient(provider: host, apiKey: key, retry: RetryPolicy(maxAttempts: 2)).catalogue()
                    guard let entry = catalogue.first(where: { $0.id == fromCatalogue }) else {
                        throw LeviathanFailure("\(host.id) lists no model '\(fromCatalogue)'",
                                               hint: "leviathan models fetch --provider \(host.id) --details --search …",
                                               code: LeviathanFailure.ExitCode.noInput)
                    }
                    suggested = entry.target(on: host)
                }
                guard let company = company ?? suggested?.company, let model = model ?? suggested?.modelID else {
                    throw LeviathanFailure("give --company and --model, or --from-catalogue", code: LeviathanFailure.ExitCode.usage)
                }
                let ref = ModelRef(company: company, model: model)
                let existing = try? ModelStore.load(ref, in: workspace)
                let preset = host.presetInfo
                var target = existing ?? suggested.map { found in
                    var target = found
                    target.company = company
                    target.modelID = model
                    return target
                } ?? ModelTarget(
                    company: company, modelID: model, providerID: host.id, requestModel: requestModel,
                    sampling: preset?.sampling ?? SamplingLimits(), terms: Terms(trainingUse: preset?.trainingUse ?? .unknown))
                target.providerID = host.id
                if existing != nil, let suggested {
                    target.requestModel = suggested.requestModel
                    if suggested.pricing != nil { target.pricing = suggested.pricing }
                }
                if inputPrice != nil || outputPrice != nil {
                    var pricing = target.pricing ?? Pricing()
                    if let inputPrice { pricing.inputPerMillion = inputPrice }
                    if let outputPrice { pricing.outputPerMillion = outputPrice }
                    pricing.source = "given"
                    target.pricing = pricing
                }
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
                    throw LeviathanFailure("the temperature range is empty", code: LeviathanFailure.ExitCode.usage)
                }
                try ModelStore.save(target, in: workspace)
                let limits = target.sampling
                try global.emit(target, "\(existing == nil ? "added" : "updated") \(target.ref) on \(host.id) as '\(target.requestModel)': "
                    + (limits.temperature == .defaultOnly ? "default temperature only"
                        : "temperature \(Output.temperature(limits.minTemperature))–\(Output.temperature(limits.maxTemperature))")
                    + (target.pricing.map { ", \(Output.price($0.inputPerMillion)) in / \(Output.price($0.outputPerMillion)) out per million tokens" } ?? "")
                    + ", terms \(target.terms.trainingUse.rawValue)"
                    + (target.terms.trainingUse == .permitted ? "" : " (Thread export refused until marked permitted)")
                    + (target.terms.note.map { "\n  \($0)" } ?? ""))
            }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the models a provider serves (GET /models). Costs nothing.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "The provider's id.")
        var provider: String

        @Flag(help: "Show price, context length, temperature, log-probabilities and open weights.")
        var details = false

        @Flag(help: "Only models whose open weights the host links.")
        var openWeights = false

        @Option(help: "Only models whose id or name holds every word given.")
        var search: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let host = try ProviderStore.provider(provider, in: workspace)
                let (key, _) = APIKeyResolver.resolve(host, store: KeychainSecretStore())
                var models = try await OpenAICompatibleClient(provider: host, apiKey: key, retry: RetryPolicy(maxAttempts: 2)).catalogue()
                if openWeights { models = models.filter(\.openWeights) }
                if let search { models = models.filter { $0.matches(search) } }
                guard details || global.json else {
                    try global.emit(models.map(\.id), models.map(\.id).joined(separator: "\n"))
                    return
                }
                func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "?" }
                let rows = models.map { model in
                    [model.id, Output.price(model.inputPrice), Output.price(model.outputPrice), model.contextLength.map(String.init) ?? "–",
                     flag(model.takesTemperature), flag(model.returnsLogprobs), model.huggingFaceID ?? model.licence ?? "–"]
                }
                try global.emit(models, models.isEmpty ? "no models match"
                    : Output.table(["id", "$/M in", "$/M out", "context", "temp", "logprobs", "open weights / licence"], rows))
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
