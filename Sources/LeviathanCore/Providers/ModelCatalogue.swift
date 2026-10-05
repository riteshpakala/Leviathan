//
//  ModelCatalogue.swift
//  LeviathanCore
//
//  WHAT: What a host's GET /models says about each model: price, context length, which request
//        fields it takes, its open weights and licence where the host lists them. Feeds the
//        model picker and `leviathan models fetch --details`.
//  PIN:  Lenient: every field but the id is optional, and a host that lists ids alone still
//        gives a usable list. Prices are kept in dollars per million tokens: OpenRouter quotes
//        `pricing.prompt`/`completion` per token, Together quotes `pricing.input`/`output` per
//        million. A host's licence field is shown as the host's claim, never taken as terms.
//

import Foundation

public struct CatalogueModel: Codable, Sendable, Hashable, Identifiable {
    /// What goes in the request's `model` field.
    public var id: String
    public var name: String?
    public var contextLength: Int?
    /// Dollars per million tokens.
    public var inputPrice: Double?
    public var outputPrice: Double?
    /// Request fields the host says the model takes; nil when the host does not say.
    public var supportedParameters: [String]?
    /// The weights' repository on Hugging Face, when the host links one.
    public var huggingFaceID: String?
    /// The licence the host lists for the model.
    public var licence: String?
    /// The maker, when the host names one.
    public var organization: String?
    public var description: String?

    public init(id: String, name: String? = nil, contextLength: Int? = nil, inputPrice: Double? = nil, outputPrice: Double? = nil,
                supportedParameters: [String]? = nil, huggingFaceID: String? = nil, licence: String? = nil, organization: String? = nil,
                description: String? = nil) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.supportedParameters = supportedParameters
        self.huggingFaceID = huggingFaceID
        self.licence = licence
        self.organization = organization
        self.description = description
    }

    public var openWeights: Bool { huggingFaceID?.isEmpty == false }
    public var huggingFaceURL: URL? { huggingFaceID.flatMap { URL(string: "https://huggingface.co/\($0)") } }

    /// Whether the host says the model takes a temperature; nil when it does not say.
    public var takesTemperature: Bool? { supportedParameters.map { $0.contains("temperature") } }
    public var returnsLogprobs: Bool? { supportedParameters.map { $0.contains("logprobs") } }

    /// The maker: the part of the id before "/", else the host's organization field, else `fallback`.
    public func company(fallback: String) -> String {
        if let slash = id.firstIndex(of: "/") { return String(id[..<slash]).lowercased() }
        if let organization, !organization.isEmpty { return organization.lowercased() }
        return fallback
    }

    /// The model's own name: the part of the id after the maker.
    public var modelName: String {
        id.firstIndex(of: "/").map { String(id[id.index(after: $0)...]) } ?? id
    }

    public func matches(_ search: String) -> Bool {
        let words = search.lowercased().split(separator: " ")
        let haystack = [id, name ?? "", organization ?? "", huggingFaceID ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Makers whose models without open weights are closed APIs whose terms bar training on outputs.
    public static let closedMakers: Set<String> = ["anthropic", "openai", "google", "x-ai"]

    /// The model target this entry suggests on a provider: ids, prices and sampling filled in,
    /// terms as the preset starts them, or `prohibited` for a closed maker's model on a router.
    public func target(on provider: Provider) -> ModelTarget {
        let preset = provider.presetInfo
        var sampling = preset?.sampling ?? SamplingLimits()
        if takesTemperature == false { sampling.temperature = .defaultOnly }
        if returnsLogprobs == false { sampling.logprobs = false }
        var terms = Terms(trainingUse: preset?.trainingUse ?? .unknown)
        let maker = company(fallback: provider.preset ?? provider.id)
        if !openWeights, huggingFaceID != nil || supportedParameters != nil, Self.closedMakers.contains(maker) {
            terms.trainingUse = .prohibited
            terms.note = "A closed model: \(maker)'s terms bar training on its outputs."
        }
        if let licence, !licence.isEmpty { terms.note = "\(provider.name) lists the licence as \(licence)." }
        var target = ModelTarget(company: maker, modelID: modelName, providerID: provider.id, requestModel: id, sampling: sampling, terms: terms)
        if inputPrice != nil || outputPrice != nil {
            target.pricing = Pricing(inputPerMillion: inputPrice, outputPerMillion: outputPrice, source: "\(provider.id) GET /models")
        }
        return target
    }
}

public enum ModelCatalogue {
    /// Every model in a GET /models body: `data` (OpenAI, OpenRouter, Anthropic), `models`, or a bare array (Together).
    public static func parse(_ json: JSONValue) -> [CatalogueModel] {
        let rows = json["data"]?.array ?? json["models"]?.array ?? json.array ?? []
        var seen = Set<String>()
        return rows.compactMap { row -> CatalogueModel? in
            guard let id = row["id"]?.string ?? row["name"]?.string ?? row.string, !id.isEmpty, seen.insert(id).inserted else { return nil }
            var model = CatalogueModel(id: id)
            model.name = row["name"]?.string ?? row["display_name"]?.string
            if model.name == id { model.name = nil }
            model.contextLength = row["context_length"]?.int ?? row["max_input_tokens"]?.int ?? row["context_window"]?.int
                ?? row["top_provider"]?["context_length"]?.int
            if let pricing = row["pricing"] {
                if pricing["prompt"] != nil || pricing["completion"] != nil {
                    // Per token to per million, rounded so 0.0000001 reads 0.1 rather than 0.09999….
                    model.inputPrice = number(pricing["prompt"]).map { ($0 * 1e12).rounded() / 1e6 }
                    model.outputPrice = number(pricing["completion"]).map { ($0 * 1e12).rounded() / 1e6 }
                } else {
                    model.inputPrice = number(pricing["input"])
                    model.outputPrice = number(pricing["output"])
                }
            }
            model.supportedParameters = row["supported_parameters"]?.array?.compactMap(\.string)
            model.huggingFaceID = row["hugging_face_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            model.licence = row["license"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            model.organization = row["organization"]?.string ?? row["owned_by"]?.string
            model.description = row["description"]?.string
            return model
        }.sorted { $0.id < $1.id }
    }

    /// A price given as a number or as a numeric string; negative means "varies" on OpenRouter.
    static func number(_ value: JSONValue?) -> Double? {
        let parsed = value?.number ?? value?.string.flatMap(Double.init)
        guard let parsed, parsed >= 0 else { return nil }
        return parsed
    }
}
