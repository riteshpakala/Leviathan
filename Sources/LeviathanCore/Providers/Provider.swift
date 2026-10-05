//
//  Provider.swift
//  LeviathanCore
//
//  WHAT: A host that serves OpenAI-compatible chat completions, and the providers.json file
//        that lists them.
//  PIN:  No secrets here. A key is named by the environment variable that holds it, or lives
//        in the Keychain under the provider's id. `baseURL` is used as given, `/v1` included,
//        the way the OpenAI SDK takes `base_url`.
//

import Foundation

public struct Provider: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    /// The environment variable holding the API key; nil for hosts that need none.
    public var apiKeyEnv: String?
    /// Extra headers sent with every request.
    public var headers: [String: String]
    /// Fields merged into every request body, over Leviathan's own.
    public var extraBody: [String: JSONValue]
    /// Requests in flight at once.
    public var maxConcurrent: Int
    public var timeoutSeconds: Double
    /// The preset this entry started from, if any.
    public var preset: String?
    /// Cleared to receive a private work's text: you read the host's data terms at `privateSource`.
    public var acceptsPrivateText: Bool
    public var privateSource: String?
    /// Fields merged into requests that carry private text, over `extraBody`.
    public var privateExtraBody: [String: JSONValue]

    public init(id: String, name: String, baseURL: String, apiKeyEnv: String? = nil, headers: [String: String] = [:],
                extraBody: [String: JSONValue] = [:], maxConcurrent: Int = 2, timeoutSeconds: Double = 300, preset: String? = nil,
                acceptsPrivateText: Bool = false, privateSource: String? = nil, privateExtraBody: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.headers = headers
        self.extraBody = extraBody
        self.maxConcurrent = maxConcurrent
        self.timeoutSeconds = timeoutSeconds
        self.preset = preset
        self.acceptsPrivateText = acceptsPrivateText
        self.privateSource = privateSource
        self.privateExtraBody = privateExtraBody
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKeyEnv, headers, extraBody, maxConcurrent, timeoutSeconds, preset, acceptsPrivateText, privateSource,
             privateExtraBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        extraBody = try c.decodeIfPresent([String: JSONValue].self, forKey: .extraBody) ?? [:]
        maxConcurrent = max(1, try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 300
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        acceptsPrivateText = try c.decodeIfPresent(Bool.self, forKey: .acceptsPrivateText) ?? false
        privateSource = try c.decodeIfPresent(String.self, forKey: .privateSource)
        privateExtraBody = try c.decodeIfPresent([String: JSONValue].self, forKey: .privateExtraBody) ?? [:]
    }

    /// `{baseURL}/{path}` with exactly one slash between them.
    public func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + path), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw LeviathanFailure("provider \(id) has an unusable base URL '\(baseURL)'",
                                   hint: "use a full URL such as http://localhost:11434/v1", code: LeviathanFailure.ExitCode.config)
        }
        return url
    }
}

public struct ProviderFile: Codable, Sendable, Equatable {
    public var providers: [Provider]

    public init(providers: [Provider] = []) {
        self.providers = providers
    }
}

public enum ProviderStore {
    public static func load(_ workspace: Workspace) throws -> [Provider] {
        let url = workspace.providersFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONCoding.read(ProviderFile.self, from: url).providers
        } catch {
            throw LeviathanFailure("providers.json is malformed: \(error)", code: LeviathanFailure.ExitCode.data)
        }
    }

    public static func save(_ providers: [Provider], to workspace: Workspace) throws {
        try JSONCoding.write(ProviderFile(providers: providers.sorted { $0.id < $1.id }), to: workspace.providersFile)
    }

    public static func provider(_ id: String, in workspace: Workspace) throws -> Provider {
        guard let provider = try load(workspace).first(where: { $0.id == id }) else {
            throw LeviathanFailure("no provider '\(id)' in providers.json", hint: "leviathan providers add --preset <name>",
                                   code: LeviathanFailure.ExitCode.noInput)
        }
        return provider
    }

    /// Adds or replaces a provider by id.
    public static func upsert(_ provider: Provider, in workspace: Workspace) throws {
        var providers = try load(workspace).filter { $0.id != provider.id }
        providers.append(provider)
        try save(providers, to: workspace)
    }

    public static func remove(_ id: String, in workspace: Workspace) throws {
        try save(try load(workspace).filter { $0.id != id }, to: workspace)
    }
}
