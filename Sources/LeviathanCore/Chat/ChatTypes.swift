//
//  ChatTypes.swift
//  LeviathanCore
//
//  WHAT: One chat completion request and what came back.
//

import Foundation

public struct ChatMessage: Codable, Sendable, Hashable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Sendable, Hashable {
    public var model: String
    public var messages: [ChatMessage]
    /// Nil sends no temperature: the host's default applies.
    public var temperature: Double?
    public var topP: Double?
    public var seed: Int?
    public var maxTokens: Int?
    public var maxTokensField: MaxTokensField
    public var logprobs: Bool
    public var topLogprobs: Int?

    public init(model: String, messages: [ChatMessage], temperature: Double? = nil, topP: Double? = nil, seed: Int? = nil,
                maxTokens: Int? = nil, maxTokensField: MaxTokensField = .maxTokens, logprobs: Bool = false, topLogprobs: Int? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
        self.maxTokens = maxTokens
        self.maxTokensField = maxTokensField
        self.logprobs = logprobs
        self.topLogprobs = topLogprobs
    }
}

public struct Usage: Codable, Sendable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct TopLogprob: Codable, Sendable, Hashable {
    public var token: String
    public var logprob: Double
}

/// One generated token with its natural-log probability, as the host reported it.
public struct TokenLogprob: Codable, Sendable, Hashable {
    public var token: String
    public var logprob: Double
    public var top: [TopLogprob]?

    public init(token: String, logprob: Double, top: [TopLogprob]? = nil) {
        self.token = token
        self.logprob = logprob
        self.top = top
    }
}

public struct ChatCompletion: Sendable, Hashable {
    public var content: String
    /// Reasoning text, where the host returns it (`reasoning_content` or `reasoning`).
    public var reasoning: String?
    public var finishReason: String?
    /// The model the host says answered.
    public var reportedModel: String?
    public var usage: Usage?
    public var logprobs: [TokenLogprob]?
    public var latencyMS: Int
    public var rawRequest: JSONValue
    public var rawResponse: JSONValue

    public init(content: String, reasoning: String? = nil, finishReason: String? = nil, reportedModel: String? = nil, usage: Usage? = nil,
                logprobs: [TokenLogprob]? = nil, latencyMS: Int = 0, rawRequest: JSONValue = .null, rawResponse: JSONValue = .null) {
        self.content = content
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.reportedModel = reportedModel
        self.usage = usage
        self.logprobs = logprobs
        self.latencyMS = latencyMS
        self.rawRequest = rawRequest
        self.rawResponse = rawResponse
    }
}
