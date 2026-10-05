//
//  ProviderCommands.swift
//  LeviathonCLI
//
//  WHAT: leviathon providers list | presets | add | test | remove | key — the hosts in
//        providers.json.
//  PIN:  `test` only lists the host's models (GET /models): it costs nothing. `key` reads the
//        key from stdin into the Keychain, so it never appears in shell history or arguments.
//

import ArgumentParser
import Foundation
import LeviathonCore

struct ProvidersGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers", abstract: "List, add, test and remove the hosts Leviathon calls.",
        subcommands: [List.self, Presets.self, Add.self, Test.self, Remove.self, Key.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the providers in providers.json.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let providers = try ProviderStore.load(workspace)
                let store = KeychainSecretStore()
                let rows = providers.map { provider -> [String] in
                    let key = APIKeyResolver.resolve(provider, store: store).source
                    return [provider.id, provider.baseURL, provider.apiKeyEnv.map { "$\($0)" } ?? "–", key.rawValue, String(provider.maxConcurrent)]
                }
                try global.emit(providers, providers.isEmpty ? "no providers (leviathon providers add --preset ollama)"
                    : Output.table(["id", "base URL", "key variable", "key found", "concurrent"], rows))
            }
        }
    }

    struct Presets: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the presets, with what their documentation left open.")
        @OptionGroup var global: GlobalOptions

        struct Row: Codable {
            var id, name, baseURL: String
            var apiKeyEnv: String?
            var temperature: String
            var maxTokensField: String
            var logprobs: Bool
            var trainingUse: TrainingUse
            var docs, note: String
        }

        func run() async throws {
            try await global.guarded {
                let rows = ProviderPresets.all.map { preset in
                    Row(id: preset.id, name: preset.name, baseURL: preset.baseURL, apiKeyEnv: preset.apiKeyEnv,
                        temperature: "\(Output.temperature(preset.sampling.minTemperature))–\(Output.temperature(preset.sampling.maxTemperature))",
                        maxTokensField: preset.sampling.maxTokensField.rawValue, logprobs: preset.sampling.logprobs,
                        trainingUse: preset.trainingUse, docs: preset.docs, note: preset.note)
                }
                try global.emit(rows, rows.map { row in
                    "\(row.id) — \(row.name)\n  \(row.baseURL)  key \(row.apiKeyEnv.map { "$\($0)" } ?? "none")  temperature \(row.temperature)  "
                        + "\(row.maxTokensField)  logprobs \(row.logprobs ? "on" : "off")  terms \(row.trainingUse.rawValue)\n  \(row.note)\n  \(row.docs)"
                }.joined(separator: "\n\n"))
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add or replace a provider, from a preset or from scratch.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "Start from a preset (leviathon providers presets).")
        var preset: String?

        @Option(help: "The provider's id (default: the preset's).")
        var id: String?

        @Option(help: "Base URL, /v1 included where the host uses it.")
        var baseURL: String?

        @Option(help: "The environment variable holding the API key.")
        var keyEnv: String?

        @Flag(help: "The host needs no key.")
        var noKey = false

        @Option(help: "Requests in flight at once.")
        var maxConcurrent: Int?

        @Option(help: "Seconds before a request times out.")
        var timeout: Double?

        @Option(help: "An extra header, as Name=Value (repeatable).")
        var header: [String] = []

        @Option(help: "Extra JSON fields merged into every request body, as one JSON object.")
        var extraBody: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                var provider: Provider
                if let preset {
                    guard let found = ProviderPresets.preset(preset) else {
                        throw LeviathonFailure("no preset '\(preset)'", hint: "leviathon providers presets", code: LeviathonFailure.ExitCode.usage)
                    }
                    provider = found.provider(id: id)
                } else {
                    guard let id, let baseURL else {
                        throw LeviathonFailure("without --preset, give --id and --base-url", code: LeviathonFailure.ExitCode.usage)
                    }
                    provider = Provider(id: id, name: id, baseURL: baseURL)
                }
                guard PathComponent.isPlain(provider.id) else {
                    throw LeviathonFailure("provider ids take [A-Za-z0-9._-]", code: LeviathonFailure.ExitCode.usage)
                }
                if let baseURL { provider.baseURL = baseURL }
                if let keyEnv { provider.apiKeyEnv = keyEnv }
                if noKey { provider.apiKeyEnv = nil }
                if let maxConcurrent { provider.maxConcurrent = max(1, maxConcurrent) }
                if let timeout { provider.timeoutSeconds = timeout }
                for entry in header {
                    let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { throw LeviathonFailure("--header takes Name=Value", code: LeviathonFailure.ExitCode.usage) }
                    provider.headers[parts[0]] = parts[1]
                }
                if let extraBody {
                    guard case .object(let fields) = JSONValue.parse(Data(extraBody.utf8)) ?? .null else {
                        throw LeviathonFailure("--extra-body must be a JSON object", code: LeviathonFailure.ExitCode.usage)
                    }
                    provider.extraBody.merge(fields) { _, new in new }
                }
                _ = try provider.endpoint("chat/completions")
                try ProviderStore.upsert(provider, in: workspace)
                try global.emit(provider, "saved provider \(provider.id): \(provider.baseURL)"
                    + (provider.apiKeyEnv.map { " (key from $\($0))" } ?? " (no key)"))
            }
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the host's models (GET /models). Costs nothing.")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The provider's id.")
        var id: String

        struct Result: Codable {
            var provider: String
            var keySource: APIKeySource
            var models: [String]
        }

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let provider = try ProviderStore.provider(id, in: workspace)
                let (key, source) = APIKeyResolver.resolve(provider, store: KeychainSecretStore())
                let client = OpenAICompatibleClient(provider: provider, apiKey: key, retry: RetryPolicy(maxAttempts: 1))
                let models = try await client.listModels()
                try global.emit(Result(provider: provider.id, keySource: source, models: models),
                                "\(provider.id) answered with \(models.count) model\(models.count == 1 ? "" : "s") (key: \(source.rawValue))\n"
                                    + models.prefix(40).map { "  \($0)" }.joined(separator: "\n") + (models.count > 40 ? "\n  …" : ""))
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a provider from providers.json.")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The provider's id.")
        var id: String

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                _ = try ProviderStore.provider(id, in: workspace)
                try ProviderStore.remove(id, in: workspace)
                try global.emit(["removed": id], "removed provider \(id)")
            }
        }
    }

    struct Key: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a provider's API key to the Keychain, read from stdin.")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The provider's id.")
        var id: String

        @Flag(help: "Remove the saved key instead.")
        var delete = false

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                _ = try ProviderStore.provider(id, in: workspace)
                let store = KeychainSecretStore()
                if delete {
                    try store.delete(id)
                    try global.emit(["deleted": id], "removed the saved key for \(id)")
                    return
                }
                let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw LeviathonFailure("no key on stdin", code: LeviathonFailure.ExitCode.usage) }
                try store.write(key, account: id)
                try global.emit(["saved": id], "saved a key for \(id) to the Keychain")
            }
        }
    }
}
