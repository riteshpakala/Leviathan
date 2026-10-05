//
//  ProviderCheck.swift
//  LeviathanCore
//
//  WHAT: Whether a provider answers with the key it has: the key's own credit and limit where
//        the host describes keys (OpenRouter's GET /key), and how many models it lists.
//  PIN:  Costs nothing: neither call generates text. Never carries the key, only where it was
//        found. A rejected key is said in plain words, apart from a host that is down.
//

import Foundation

public struct KeyStatus: Codable, Sendable, Hashable {
    public var label: String?
    /// Dollars. Nil when the key has no limit.
    public var limit: Double?
    public var limitRemaining: Double?
    /// Dollars spent with this key, all time.
    public var usage: Double?
    public var isFreeTier: Bool?

    public init(label: String? = nil, limit: Double? = nil, limitRemaining: Double? = nil, usage: Double? = nil, isFreeTier: Bool? = nil) {
        self.label = label
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.usage = usage
        self.isFreeTier = isFreeTier
    }

    public static func parse(_ json: JSONValue) -> KeyStatus {
        let data = json["data"] ?? json
        return KeyStatus(label: data["label"]?.string, limit: ModelCatalogue.number(data["limit"]),
                         limitRemaining: ModelCatalogue.number(data["limit_remaining"]), usage: ModelCatalogue.number(data["usage"]),
                         isFreeTier: { if case .bool(let value) = data["is_free_tier"] ?? .null { return value } else { return nil } }())
    }

    /// "$4.20 left of $10.00 · $5.80 used", or "no limit · $5.80 used".
    public var summary: String {
        var parts: [String] = []
        if let limit {
            parts.append("\(Self.dollars(limitRemaining ?? limit)) left of \(Self.dollars(limit))")
        } else {
            parts.append("no spending limit on this key")
        }
        if let usage { parts.append("\(Self.dollars(usage)) used") }
        if isFreeTier == true { parts.append("no credit bought yet") }
        return parts.joined(separator: " · ")
    }

    public static func dollars(_ value: Double) -> String {
        String(format: value < 0.01 && value > 0 ? "$%.4f" : "$%.2f", value)
    }

    /// Dollars per million tokens: two decimals, three when the third one matters.
    public static func price(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 0 { return "free" }
        if value >= 1 { return String(format: "$%.2f", value) }
        var text = String(format: "%.3f", value)
        if text.hasSuffix("0") { text.removeLast() }
        return "$" + text
    }
}

public struct ProviderCheck: Codable, Sendable {
    public var provider: String
    public var keySource: APIKeySource
    public var keyStatus: KeyStatus?
    public var models: [CatalogueModel]

    /// One line for a person: whether the key works, its credit, and the model count.
    public var summary: String {
        var line = "\(provider) answered with \(models.count) model\(models.count == 1 ? "" : "s") (key: \(keySource.rawValue))"
        if let keyStatus { line += "; \(keyStatus.summary)" }
        return line
    }

    public static func run(_ provider: Provider, key: String?, source: APIKeySource, session: URLSession = .shared) async throws -> ProviderCheck {
        let client = OpenAICompatibleClient(provider: provider, apiKey: key, session: session, retry: RetryPolicy(maxAttempts: 1))
        var status: KeyStatus?
        if let path = provider.presetInfo?.keyStatusPath {
            status = try await client.keyStatus(path: path)
        }
        return ProviderCheck(provider: provider.id, keySource: source, keyStatus: status, models: try await client.catalogue())
    }
}

extension ChatError {
    /// The host turned the key down: missing, wrong, revoked or out of credit.
    public var rejectsKey: Bool {
        guard case .http(let status, _) = self else { return false }
        return status == 401 || status == 402 || status == 403
    }

    /// The failure in words for a person setting a host up.
    public var plain: String {
        switch self {
        case .http(401, _), .http(403, _): return "The host turned the key down (\(description)). Check that it was copied whole and is still active."
        case .http(402, _): return "The key works but its account has no credit left (\(description))."
        case .transport: return "The host could not be reached (\(description)). Check the connection and the base URL."
        default: return description
        }
    }
}
