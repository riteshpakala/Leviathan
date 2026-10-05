//
//  ProviderCommands.swift
//  LeviathanCLI
//
//  WHAT: leviathan providers list | presets | add | connect | test | remove | key — the hosts in
//        providers.json.
//  PIN:  `test` only reads the key's status and the host's models: it costs nothing. `key` reads
//        the key from stdin into the Keychain, so it never appears in shell history or arguments.
//        `connect openrouter` signs in through the browser and saves the key it gets back;
//        no key is ever printed.
//

import ArgumentParser
import Foundation
import LeviathanCore

struct ProvidersGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers", abstract: "List, add, connect, test and remove the hosts Leviathan calls.",
        subcommands: [List.self, Presets.self, Add.self, Connect.self, Test.self, Private.self, Remove.self, Key.self])

    struct Private: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear a host to receive your works' text, after reading its data terms; or withdraw that.",
            discussion: "A runtime on this Mac is cleared from the start. DeepSeek's own API can never be cleared.")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The provider's id.")
        var id: String

        @Flag(help: "Clear it.")
        var allow = false

        @Flag(help: "Withdraw it.")
        var revoke = false

        @Option(help: "Where you read the host's data terms.")
        var source: String?

        func run() async throws {
            try await global.guarded {
                guard allow != revoke else { throw LeviathanFailure("give --allow or --revoke", code: LeviathanFailure.ExitCode.usage) }
                let workspace = try global.rootWorkspace()
                let provider = try PrivateText.clear(try ProviderStore.provider(id, in: workspace), allow: allow, source: source)
                try ProviderStore.upsert(provider, in: workspace)
                try global.emit(provider, allow
                    ? "\(id) may receive your works' text (terms read at \(provider.privateSource ?? ""))"
                        + (provider.privateExtraBody.isEmpty ? "" : "; its requests add \((try? JSONCoding.line(provider.privateExtraBody)) ?? "")")
                    : "\(id) no longer receives your works' text")
            }
        }
    }

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
                try global.emit(providers, providers.isEmpty ? "no providers (leviathan providers add --preset ollama)"
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

        @Option(help: "Start from a preset (leviathan providers presets).")
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
                        throw LeviathanFailure("no preset '\(preset)'", hint: "leviathan providers presets", code: LeviathanFailure.ExitCode.usage)
                    }
                    provider = found.provider(id: id)
                } else {
                    guard let id, let baseURL else {
                        throw LeviathanFailure("without --preset, give --id and --base-url", code: LeviathanFailure.ExitCode.usage)
                    }
                    provider = Provider(id: id, name: id, baseURL: baseURL)
                }
                guard PathComponent.isPlain(provider.id) else {
                    throw LeviathanFailure("provider ids take [A-Za-z0-9._-]", code: LeviathanFailure.ExitCode.usage)
                }
                if let baseURL { provider.baseURL = baseURL }
                if let keyEnv { provider.apiKeyEnv = keyEnv }
                if noKey { provider.apiKeyEnv = nil }
                if let maxConcurrent { provider.maxConcurrent = max(1, maxConcurrent) }
                if let timeout { provider.timeoutSeconds = timeout }
                for entry in header {
                    let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { throw LeviathanFailure("--header takes Name=Value", code: LeviathanFailure.ExitCode.usage) }
                    provider.headers[parts[0]] = parts[1]
                }
                if let extraBody {
                    guard case .object(let fields) = JSONValue.parse(Data(extraBody.utf8)) ?? .null else {
                        throw LeviathanFailure("--extra-body must be a JSON object", code: LeviathanFailure.ExitCode.usage)
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

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a host from its preset and give it a key: OpenRouter signs in through the browser.",
            discussion: "Hosts without sign-in are added and then take a key from the app, or from stdin: leviathan providers key <id> < keyfile")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The preset (leviathan providers presets).")
        var preset: String

        @Option(help: "The provider's id (default: the preset's).")
        var id: String?

        @Option(help: "Seconds to wait for the browser.")
        var timeout: Double = 300

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                guard let found = ProviderPresets.preset(preset) else {
                    throw LeviathanFailure("no preset '\(preset)'", hint: "leviathan providers presets", code: LeviathanFailure.ExitCode.usage)
                }
                let provider = try ProviderStore.load(workspace).first { $0.id == (id ?? found.id) } ?? found.provider(id: id)
                try ProviderStore.upsert(provider, in: workspace)
                let store = KeychainSecretStore()
                if found.signIn {
                    // $LEVIATHAN_BROWSER names another program to open the page with, or "none" to only print it.
                    let browser = ProcessInfo.processInfo.environment["LEVIATHAN_BROWSER"] ?? "/usr/bin/open"
                    let key = try await OpenRouterAuth(provider: provider).signIn(timeout: timeout) { url in
                        Output.progress("Approve Leviathan in the browser. If it did not open, visit:\n  \(url.absoluteString)")
                        if browser != "none" { _ = try? Process.run(URL(fileURLWithPath: browser), arguments: [url.absoluteString]) }
                    }
                    try store.write(key, account: provider.id)
                    Output.progress("saved the key for \(provider.id) to the Keychain")
                }
                let (key, source) = APIKeyResolver.resolve(provider, store: store)
                if provider.apiKeyEnv != nil, key == nil {
                    try global.emit(["added": provider.id], "added \(provider.id); give it a key in the app (Connect a Host), "
                        + "or: leviathan providers key \(provider.id) < keyfile" + (found.keysURL.map { "\n  keys: \($0)" } ?? ""))
                    return
                }
                let check = try await ProviderCheck.run(provider, key: key, source: source)
                try global.emit(check, check.summary)
            }
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check the key and list the host's models. Costs nothing.")
        @OptionGroup var global: GlobalOptions

        @Argument(help: "The provider's id.")
        var id: String

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let provider = try ProviderStore.provider(id, in: workspace)
                let (key, source) = APIKeyResolver.resolve(provider, store: KeychainSecretStore())
                do {
                    let check = try await ProviderCheck.run(provider, key: key, source: source)
                    let ids = check.models.map(\.id)
                    try global.emit(check, check.summary + "\n" + ids.prefix(40).map { "  \($0)" }.joined(separator: "\n")
                        + (ids.count > 40 ? "\n  …" : ""))
                } catch let error as ChatError {
                    throw LeviathanFailure(error.plain + (key == nil && provider.apiKeyEnv != nil ? " No key was found for \(provider.id)." : ""),
                                           hint: error.rejectsKey ? "give \(provider.id) a key in the app (Connect a Host)" : nil,
                                           code: error.rejectsKey ? LeviathanFailure.ExitCode.config : LeviathanFailure.ExitCode.unavailable)
                }
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
                guard !key.isEmpty else { throw LeviathanFailure("no key on stdin", code: LeviathanFailure.ExitCode.usage) }
                try store.write(key, account: id)
                try global.emit(["saved": id], "saved a key for \(id) to the Keychain")
            }
        }
    }
}
