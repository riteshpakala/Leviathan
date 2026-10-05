//
//  SecretStore.swift
//  LeviathanCore
//
//  WHAT: Where API keys come from: the environment variable a provider names, then a Keychain
//        item under the provider's id, saved by the app or by `leviathan providers key`.
//  PIN:  Keys are never written to providers.json, transcripts or logs, and never printed.
//        Items are written and read through /usr/bin/security, so the item trusts that tool
//        rather than whichever binary saved it: a key saved in the app reaches the command line,
//        and both keep it across rebuilds. The key travels to `security` over stdin as hex,
//        never in arguments, so it does not show in the process list.
//

import Foundation

public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ secret: String, account: String) throws
    func delete(_ account: String) throws
}

public struct KeychainSecretStore: SecretStore {
    public let service: String

    public static let defaultService = "nyc.rao.leviathan.keys"

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func read(_ account: String) -> String? {
        let found = Self.run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard found.status == 0 else { return nil }
        let value = String(decoding: found.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    public func write(_ secret: String, account: String) throws {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LeviathanFailure("the key is empty", code: LeviathanFailure.ExitCode.usage) }
        let saved = Self.run(["-i"], input: Data(Self.addCommand(service: service, account: account, secret: value).utf8))
        // `security -i` exits 0 even when a command inside it fails, so the write is confirmed by reading it back.
        guard saved.status == 0, read(account) == value else {
            throw LeviathanFailure("could not save the key to the Keychain", hint: Self.clip(saved.error), code: LeviathanFailure.ExitCode.cantCreate)
        }
    }

    public func delete(_ account: String) throws {
        let removed = Self.run(["delete-generic-password", "-s", service, "-a", account])
        // 44: no such item, which is what deleting wants.
        guard removed.status == 0 || removed.status == 44 else {
            throw LeviathanFailure("could not remove the key from the Keychain", hint: Self.clip(removed.error),
                                   code: LeviathanFailure.ExitCode.cantCreate)
        }
    }

    /// The line `security -i` reads: the secret as hex, so no quoting can break it. Service and
    /// account are provider ids, which take [A-Za-z0-9._-] only.
    static func addCommand(service: String, account: String, secret: String) -> String {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U -s \(service) -a \(account) -l \(service).\(account) -X \(hex)\n"
    }

    static func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            return (-1, Data(), "\(error)")
        }
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out, String(decoding: err, as: UTF8.self))
    }

    static func clip(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : String(line.prefix(200))
    }
}

/// A store in memory, for tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func read(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    public func write(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = secret
    }

    public func delete(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = nil
    }
}

public enum APIKeySource: String, Sendable, Codable {
    case environment, keychain, none
}

public enum APIKeyResolver {
    /// The key for a provider and where it came from. Nil when neither source has one.
    public static func resolve(
        _ provider: Provider, environment: [String: String] = ProcessInfo.processInfo.environment, store: (any SecretStore)? = nil
    ) -> (key: String?, source: APIKeySource) {
        if let name = provider.apiKeyEnv, let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return (value, .environment)
        }
        if let store, let value = store.read(provider.id), !value.isEmpty {
            return (value, .keychain)
        }
        return (nil, .none)
    }
}
