//
//  ProviderPresets.swift
//  LeviathonCore
//
//  WHAT: Starting points for the hosts Leviathon was written against: base URL, key variable,
//        and what a model there takes by default (temperature range, max-tokens field,
//        log-probabilities, extra fields), with the terms its outputs start under.
//  PIN:  Checked against each provider's documentation on 2026-10-05; `note` says what the
//        docs left open. A range the docs do not state is set to what they recommend, so a host
//        that clamps silently never receives a value it would change. Closed APIs start as
//        `prohibited`; every other host starts as `unknown` until you have read the model's
//        licence. Every value can be changed per provider and per model.
//

import Foundation

public struct ProviderPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var apiKeyEnv: String?
    public var local: Bool
    public var extraBody: [String: JSONValue]
    public var sampling: SamplingLimits
    public var trainingUse: TrainingUse
    public var docs: String
    public var note: String

    public func provider(id: String? = nil) -> Provider {
        Provider(id: id ?? self.id, name: name, baseURL: baseURL, apiKeyEnv: apiKeyEnv, extraBody: extraBody,
                 maxConcurrent: local ? 1 : 4, timeoutSeconds: local ? 600 : 300, preset: self.id)
    }
}

public enum ProviderPresets {
    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1", apiKeyEnv: nil, local: true, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://docs.ollama.com/api/openai-compatibility",
            note: "No key needed locally. Log-probabilities need Ollama 0.12.11 or later. No temperature range is documented; 0–2 is assumed."),
        ProviderPreset(
            id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", apiKeyEnv: nil, local: true, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://lmstudio.ai/docs/developer/openai-compat",
            note: "No key unless the server's token auth is on. Log-probabilities and a temperature range are not documented."),
        ProviderPreset(
            id: "vllm", name: "vLLM", baseURL: "http://localhost:8000/v1", apiKeyEnv: "VLLM_API_KEY", local: true, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxCompletionTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/",
            note: "Temperatures above 0 and below 0.01 are raised to 0.01. Reasoning text needs --reasoning-parser."),
        ProviderPreset(
            id: "llamacpp", name: "llama.cpp server", baseURL: "http://localhost:8080/v1", apiKeyEnv: "LLAMA_API_KEY", local: true,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md",
            note: "No upper temperature bound; 0–2 is kept for comparability. GET /models lists one model, named by --alias."),
        ProviderPreset(
            id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", apiKeyEnv: "MISTRAL_API_KEY", local: false, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 0.7, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://docs.mistral.ai/api/endpoint/chat",
            note: "The docs recommend 0–0.7 and state no maximum, so the range stops at 0.7; widen it per model if you confirm more."),
        ProviderPreset(
            id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", apiKeyEnv: "DEEPSEEK_API_KEY", local: false,
            extraBody: ["thinking": .object(["type": .string("disabled")])],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://api-docs.deepseek.com/guides/thinking_mode/",
            note: "Thinking is on by default and then temperature has no effect, so the preset turns thinking off for the sweep."),
        ProviderPreset(
            id: "together", name: "Together AI", baseURL: "https://api.together.ai/v1", apiKeyEnv: "TOGETHER_API_KEY", local: false,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 1, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://docs.together.ai/reference/chat-completions-1",
            note: "Temperature is documented as 0–1. Its log-probabilities use a different format, so they are off."),
        ProviderPreset(
            id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", apiKeyEnv: "GROQ_API_KEY", local: false, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxCompletionTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://console.groq.com/docs/openai",
            note: "Sending logprobs is a 400. A temperature of 0 is converted to 1e-8."),
        ProviderPreset(
            id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", apiKeyEnv: "OPENROUTER_API_KEY", local: false,
            extraBody: ["provider": .object(["require_parameters": .bool(true)])],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://openrouter.ai/docs/api-reference/parameters",
            note: "Parameters a routed provider does not support are dropped silently, so the preset requires them. Serves closed models too: set terms per model."),
        ProviderPreset(
            id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", apiKeyEnv: "OPENAI_API_KEY", local: false, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxCompletionTokens, logprobs: false),
            trainingUse: .prohibited, docs: "https://developers.openai.com/api/docs/guides/latest-model",
            note: "Models running with reasoning take no temperature: mark those default-only. Terms bar training a competing model on outputs."),
        ProviderPreset(
            id: "anthropic", name: "Anthropic (OpenAI compatibility)", baseURL: "https://api.anthropic.com/v1/", apiKeyEnv: "ANTHROPIC_API_KEY",
            local: false, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 1, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .prohibited, docs: "https://platform.claude.com/docs/en/api/openai-sdk",
            note: "Values above 1 are capped at 1 without an error, so the range stops at 1. Opus 4.7 and later, Sonnet 5 and later and Fable reject temperature on the native API: mark them default-only. Log-probabilities are ignored."),
        ProviderPreset(
            id: "gemini", name: "Google Gemini (OpenAI compatibility)", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            apiKeyEnv: "GEMINI_API_KEY", local: false, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .prohibited, docs: "https://ai.google.dev/gemini-api/docs/openai",
            note: "Google recommends leaving Gemini 3 at its default of 1.0, since lower values may loop. Log-probabilities on this endpoint are unconfirmed."),
    ]

    public static func preset(_ id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}
