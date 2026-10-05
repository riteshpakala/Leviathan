//
//  ChatClient.swift
//  LeviathanCore
//
//  WHAT: What the harvester asks of a host, and how a request can fail.
//

import Foundation

public protocol ChatClient: Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatCompletion
    /// The model ids the host lists at GET /models.
    func listModels() async throws -> [String]
}

public enum ChatError: Error, CustomStringConvertible, Sendable {
    /// The host answered with an error status. `message` is the host's own text.
    case http(status: Int, message: String)
    /// The request never got an answer: connection refused, timed out, reset.
    case transport(String)
    /// The host answered 2xx with a body Leviathan could not read.
    case unreadable(String)
    /// Retries ran out; carries the last failure.
    case exhausted(attempts: Int, last: String)

    public var description: String {
        switch self {
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .transport(let message): return "transport: \(message)"
        case .unreadable(let message): return "unreadable response: \(message)"
        case .exhausted(let attempts, let last): return "gave up after \(attempts) attempts: \(last)"
        }
    }

    /// Statuses worth trying again: timeouts, rate limits, the host's own failures.
    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
    }

    /// A 4xx whose message is about the temperature: the model does not take one, or not this one.
    public var rejectsTemperature: Bool {
        guard case .http(let status, let message) = self, (400..<500).contains(status), status != 429 else { return false }
        return message.lowercased().contains("temperature")
    }

    /// Whether running the same request again could succeed.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _): return ChatError.isRetryable(status: status)
        case .transport: return true
        case .unreadable, .exhausted: return false
        }
    }
}
