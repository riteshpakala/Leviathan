//
//  SecretStore.swift
//  LeviathonCore
//
//  WHAT: Where API keys come from: the environment variable a provider names, then a Keychain
//        item under the provider's id that the app saved.
//  PIN:  Keys are never written to providers.json, transcripts or logs. Keychain reads never
//        ask for interaction, so a headless run cannot hang on a dialog. A binary rebuilt and
//        re-signed during development may lose access to an item it saved earlier; the
//        environment variable is the path that always works.
//

import Foundation
import LocalAuthentication
import Security

public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ secret: String, account: String) throws
    func delete(_ account: String) throws
}

public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "nyc.rao.leviathon") {
        self.service = service
    }

    public func read(_ account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, account: String) throws {
        try? delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LeviathonFailure("could not save the key to the Keychain (status \(status))", code: LeviathonFailure.ExitCode.cantCreate)
        }
    }

    public func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LeviathonFailure("could not remove the key from the Keychain (status \(status))", code: LeviathonFailure.ExitCode.cantCreate)
        }
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
