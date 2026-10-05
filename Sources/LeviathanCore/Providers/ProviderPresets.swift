//
//  ProviderPresets.swift
//  LeviathanCore
//
//  WHAT: Starting points for the hosts Leviathan was written against: base URL, key variable,
//        where to get a key, and what a model there takes by default (temperature range,
//        max-tokens field, log-probabilities, extra fields), with the terms its outputs start under.
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
    /// One line on what the host is, for the connect sheet.
    public var summary: String
    public var baseURL: String
    public var apiKeyEnv: String?
    /// Where a person makes a key for this host.
    public var keysURL: String?
    public var local: Bool
    public var extraBody: [String: JSONValue]
    public var sampling: SamplingLimits
    public var trainingUse: TrainingUse
    /// The host offers sign-in that hands back a key (OpenRouter's PKCE flow).
    public var signIn: Bool = false
    /// Path under the base URL that describes the key itself: its credit and limit.
    public var keyStatusPath: String? = nil
    public var docs: String
    public var note: String
    /// Fields that keep a request carrying private text out of logging and retention.
    public var privateExtraBody: [String: JSONValue] = [:]
    /// Why this host may never receive a private work's text, when it may not.
    public var privateRefusal: String? = nil
    /// Where the host states what it does with what it is sent.
    public var dataTerms: String? = nil

    public func provider(id: String? = nil) -> Provider {
        Provider(id: id ?? self.id, name: name, baseURL: baseURL, apiKeyEnv: apiKeyEnv, extraBody: extraBody,
                 maxConcurrent: local ? 1 : 4, timeoutSeconds: local ? 600 : 300, preset: self.id,
                 acceptsPrivateText: local && privateRefusal == nil, privateSource: local ? "runs on this Mac" : nil,
                 privateExtraBody: privateExtraBody)
    }
}

public enum ProviderPresets {
    /// Hosted first, OpenRouter at the top; then the runtimes on this Mac.
    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "openrouter", name: "OpenRouter", summary: "One key for hundreds of models from many makers, open-weight and closed.",
            baseURL: "https://openrouter.ai/api/v1", apiKeyEnv: "OPENROUTER_API_KEY", keysURL: "https://openrouter.ai/settings/keys", local: false,
            extraBody: ["provider": .object(["require_parameters": .bool(true)])],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, signIn: true, keyStatusPath: "key", docs: "https://openrouter.ai/docs/api-reference/parameters",
            note: "Parameters a routed provider does not support are dropped silently, so the preset requires them. Serves closed models too: set terms per model.",
            privateExtraBody: ["provider": .object(["data_collection": .string("deny"), "zdr": .bool(true)])],
            dataTerms: "https://openrouter.ai/docs/features/provider-routing"),
        ProviderPreset(
            id: "anthropic", name: "Anthropic", summary: "Claude models, through Anthropic's OpenAI-compatible endpoint.",
            baseURL: "https://api.anthropic.com/v1/", apiKeyEnv: "ANTHROPIC_API_KEY", keysURL: "https://platform.claude.com/settings/keys", local: false,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 1, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .prohibited, docs: "https://platform.claude.com/docs/en/api/openai-sdk",
            note: "Values above 1 are capped at 1 without an error, so the range stops at 1. Opus 4.7 and later, Sonnet 5 and later and Fable reject temperature on the native API: mark them default-only. Log-probabilities, seed and reasoning_effort are ignored. A key with access to several workspaces also needs the anthropic-workspace-id header.",
            dataTerms: "https://www.anthropic.com/legal/commercial-terms"),
        ProviderPreset(
            id: "together", name: "Together AI", summary: "Open-weight models hosted directly, with their licences listed.",
            baseURL: "https://api.together.ai/v1", apiKeyEnv: "TOGETHER_API_KEY", keysURL: "https://api.together.ai/settings/api-keys", local: false,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 1, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://docs.together.ai/reference/chat-completions-1",
            note: "Temperature is documented as 0–1. Its log-probabilities use a different format, so they are off.",
            dataTerms: "https://docs.together.ai/docs/privacy-and-security"),
        ProviderPreset(
            id: "deepseek", name: "DeepSeek", summary: "DeepSeek's own API. Returns token log-probabilities.",
            baseURL: "https://api.deepseek.com", apiKeyEnv: "DEEPSEEK_API_KEY", keysURL: "https://platform.deepseek.com/api_keys", local: false,
            extraBody: ["thinking": .object(["type": .string("disabled")])],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://api-docs.deepseek.com/guides/thinking_mode/",
            note: "Thinking is on by default and then temperature has no effect, so the preset turns thinking off for the sweep. Its privacy policy allows training on inputs.",
            privateRefusal: "DeepSeek's privacy policy allows training on what it is sent and stores it in China. Reach DeepSeek's models through OpenRouter or Together for private text.",
            dataTerms: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"),
        ProviderPreset(
            id: "mistral", name: "Mistral", summary: "Mistral's own API.",
            baseURL: "https://api.mistral.ai/v1", apiKeyEnv: "MISTRAL_API_KEY", keysURL: "https://console.mistral.ai/api-keys", local: false,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 0.7, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://docs.mistral.ai/api/endpoint/chat",
            note: "The docs recommend 0–0.7 and state no maximum, so the range stops at 0.7; widen it per model if you confirm more."),
        ProviderPreset(
            id: "groq", name: "Groq", summary: "Open-weight models on fast hardware.",
            baseURL: "https://api.groq.com/openai/v1", apiKeyEnv: "GROQ_API_KEY", keysURL: "https://console.groq.com/keys", local: false,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxCompletionTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://console.groq.com/docs/openai",
            note: "Sending logprobs is a 400. A temperature of 0 is converted to 1e-8."),
        ProviderPreset(
            id: "openai", name: "OpenAI", summary: "OpenAI's own API.",
            baseURL: "https://api.openai.com/v1", apiKeyEnv: "OPENAI_API_KEY", keysURL: "https://platform.openai.com/api-keys", local: false,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxCompletionTokens, logprobs: false),
            trainingUse: .prohibited, docs: "https://developers.openai.com/api/docs/guides/latest-model",
            note: "Models running with reasoning take no temperature: mark those default-only. Terms bar training a competing model on outputs."),
        ProviderPreset(
            id: "gemini", name: "Google Gemini", summary: "Gemini models, through Google's OpenAI-compatible endpoint.",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/", apiKeyEnv: "GEMINI_API_KEY",
            keysURL: "https://aistudio.google.com/apikey", local: false, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .prohibited, docs: "https://ai.google.dev/gemini-api/docs/openai",
            note: "Google recommends leaving Gemini 3 at its default of 1.0, since lower values may loop. Log-probabilities on this endpoint are unconfirmed."),
        ProviderPreset(
            id: "ollama", name: "Ollama", summary: "Open models running on this Mac. No key, no cost.",
            baseURL: "http://localhost:11434/v1", apiKeyEnv: nil, local: true, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://docs.ollama.com/api/openai-compatibility",
            note: "No key needed locally. Log-probabilities need Ollama 0.12.11 or later. No temperature range is documented; 0–2 is assumed."),
        ProviderPreset(
            id: "lmstudio", name: "LM Studio", summary: "Open models in LM Studio on this Mac.",
            baseURL: "http://localhost:1234/v1", apiKeyEnv: nil, local: true, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: false),
            trainingUse: .unknown, docs: "https://lmstudio.ai/docs/developer/openai-compat",
            note: "No key unless the server's token auth is on. Log-probabilities and a temperature range are not documented."),
        ProviderPreset(
            id: "vllm", name: "vLLM", summary: "A vLLM server you run.",
            baseURL: "http://localhost:8000/v1", apiKeyEnv: "VLLM_API_KEY", local: true, extraBody: [:],
            sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxCompletionTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/",
            note: "Temperatures above 0 and below 0.01 are raised to 0.01. Reasoning text needs --reasoning-parser."),
        ProviderPreset(
            id: "llamacpp", name: "llama.cpp server", summary: "A llama.cpp server you run.",
            baseURL: "http://localhost:8080/v1", apiKeyEnv: "LLAMA_API_KEY", local: true,
            extraBody: [:], sampling: SamplingLimits(minTemperature: 0, maxTemperature: 2, maxTokensField: .maxTokens, logprobs: true),
            trainingUse: .unknown, docs: "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md",
            note: "No upper temperature bound; 0–2 is kept for comparability. GET /models lists one model, named by --alias."),
    ]

    public static func preset(_ id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}

extension Provider {
    /// The preset this provider started from.
    public var presetInfo: ProviderPreset? { preset.flatMap(ProviderPresets.preset) }
}
