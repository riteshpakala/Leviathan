//
//  OpenAICompatibleClient.swift
//  LeviathonCore
//
//  WHAT: POST {baseURL}/chat/completions and GET {baseURL}/models on any OpenAI-compatible host.
//  PIN:  One completion per request: hosts differ on `n`, so it is never sent. Non-streaming,
//        so `usage` arrives whole. Decoding is lenient: only choices[0].message is read, content
//        may be a string or a list of text parts, and reasoning comes from `reasoning_content`
//        or `reasoning`. Retries 408, 409, 425, 429, 5xx and transport failures with backoff,
//        honouring Retry-After; any other status fails at once with the host's own message.
//

import Foundation

public struct RetryPolicy: Sendable, Hashable {
    public var maxAttempts: Int
    public var baseDelay: Double
    public var maxDelay: Double
    /// The longest Retry-After honoured; a host asking for longer gets this.
    public var maxRetryAfter: Double

    public init(maxAttempts: Int = 4, baseDelay: Double = 1, maxDelay: Double = 30, maxRetryAfter: Double = 120) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
    }

    /// The wait before attempt `attempt + 1` (attempt counts from 1).
    public func delay(after attempt: Int, retryAfter: Double?) -> Double {
        if let retryAfter { return min(max(retryAfter, 0), maxRetryAfter) }
        return min(baseDelay * pow(2, Double(attempt - 1)), maxDelay)
    }
}

public struct OpenAICompatibleClient: ChatClient {
    public let provider: Provider
    public let apiKey: String?
    public let session: URLSession
    public let retry: RetryPolicy
    public let sleep: @Sendable (Double) async throws -> Void

    public init(provider: Provider, apiKey: String?, session: URLSession = .shared, retry: RetryPolicy = RetryPolicy(),
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.provider = provider
        self.apiKey = apiKey
        self.session = session
        self.retry = retry
        self.sleep = sleep
    }

    // MARK: Request

    /// The request body: Leviathon's fields, then the provider's extraBody over them.
    public func body(for request: ChatRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(request.messages.map { .object(["role": .string($0.role), "content": .string($0.content)]) }),
            "stream": .bool(false),
        ]
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if let topP = request.topP { body["top_p"] = .number(topP) }
        if let seed = request.seed { body["seed"] = .number(Double(seed)) }
        if let maxTokens = request.maxTokens { body[request.maxTokensField.rawValue] = .number(Double(maxTokens)) }
        if request.logprobs {
            body["logprobs"] = .bool(true)
            if let top = request.topLogprobs { body["top_logprobs"] = .number(Double(top)) }
        }
        for (key, value) in provider.extraBody { body[key] = value }
        return body
    }

    func urlRequest(_ url: URL, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: provider.timeoutSeconds)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in provider.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    // MARK: Calls

    public func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        let url = try provider.endpoint("chat/completions")
        let bodyValue = JSONValue.object(body(for: request))
        let bodyData = try JSONCoding.lineEncoder().encode(bodyValue)
        let started = Date()
        let (data, _) = try await send(urlRequest(url, method: "POST", body: bodyData))
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        guard let json = JSONValue.parse(data) else {
            throw ChatError.unreadable("the body is not JSON: \(Self.clip(String(decoding: data, as: UTF8.self)))")
        }
        var completion = try Self.decodeCompletion(json)
        completion.latencyMS = latency
        completion.rawRequest = bodyValue
        completion.rawResponse = json
        return completion
    }

    public func listModels() async throws -> [String] {
        let url = try provider.endpoint("models")
        let (data, _) = try await send(urlRequest(url, method: "GET", body: nil))
        guard let json = JSONValue.parse(data) else { throw ChatError.unreadable("GET /models did not return JSON") }
        let rows = json["data"]?.array ?? json["models"]?.array ?? json.array ?? []
        return rows.compactMap { $0["id"]?.string ?? $0["name"]?.string ?? $0.string }.sorted()
    }

    /// Sends with retries; returns the body of the first 2xx.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var lastFailure = ""
        while true {
            attempt += 1
            try Task.checkCancellation()
            var retryAfter: Double?
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ChatError.transport("no HTTP response") }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                let error = ChatError.http(status: http.statusCode, message: Self.errorMessage(data))
                guard error.isRetryable else { throw error }
                lastFailure = error.description
                retryAfter = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            } catch let error as ChatError {
                guard error.isRetryable else { throw error }
                lastFailure = error.description
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastFailure = ChatError.transport(error.localizedDescription).description
            }
            guard attempt < retry.maxAttempts else { throw ChatError.exhausted(attempts: attempt, last: lastFailure) }
            try await sleep(retry.delay(after: attempt, retryAfter: retryAfter))
        }
    }

    // MARK: Decoding

    static func decodeCompletion(_ json: JSONValue) throws -> ChatCompletion {
        if let error = json["error"], !error.isNull {
            throw ChatError.http(status: 200, message: error["message"]?.string ?? error.string ?? "the host returned an error")
        }
        guard let choice = json["choices"]?[0] else {
            throw ChatError.unreadable("no choices in the response")
        }
        let message = choice["message"] ?? .null
        let content = text(of: message["content"]) ?? text(of: choice["text"]) ?? ""
        let reasoning = message["reasoning_content"]?.string ?? message["reasoning"]?.string ?? thinking(of: message["content"])
        var usage: Usage?
        if let u = json["usage"], u.object != nil {
            usage = Usage(promptTokens: u["prompt_tokens"]?.int, completionTokens: u["completion_tokens"]?.int, totalTokens: u["total_tokens"]?.int)
        }
        var logprobs: [TokenLogprob]?
        if let rows = choice["logprobs"]?["content"]?.array {
            logprobs = rows.compactMap { row in
                guard let token = row["token"]?.string, let logprob = row["logprob"]?.number else { return nil }
                let top = row["top_logprobs"]?.array?.compactMap { alt -> TopLogprob? in
                    guard let token = alt["token"]?.string, let logprob = alt["logprob"]?.number else { return nil }
                    return TopLogprob(token: token, logprob: logprob)
                }
                return TokenLogprob(token: token, logprob: logprob, top: top)
            }
        }
        return ChatCompletion(content: content, reasoning: reasoning?.isEmpty == true ? nil : reasoning,
                              finishReason: choice["finish_reason"]?.string, reportedModel: json["model"]?.string, usage: usage,
                              logprobs: logprobs)
    }

    /// Text from a content field that is a string, or a list of parts. Only text parts count:
    /// Mistral, for one, puts a `thinking` part beside the answer.
    static func text(of value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.string { return string }
        if let parts = value.array {
            let texts = parts.compactMap { part -> String? in
                if let string = part.string { return string }
                guard part["type"]?.string ?? "text" == "text" else { return nil }
                return part["text"]?.string
            }
            return texts.isEmpty ? nil : texts.joined()
        }
        return nil
    }

    /// The text of `thinking` parts in a content list, nested text parts flattened.
    static func thinking(of value: JSONValue?) -> String? {
        guard let parts = value?.array else { return nil }
        func flatten(_ value: JSONValue) -> [String] {
            if let string = value.string { return [string] }
            if let text = value["text"]?.string { return [text] }
            if let list = value.array { return list.flatMap(flatten) }
            return []
        }
        let texts = parts.filter { $0["type"]?.string == "thinking" }.flatMap { flatten($0["thinking"] ?? .null) }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// The host's own words from an error body.
    static func errorMessage(_ data: Data) -> String {
        if let json = JSONValue.parse(data) {
            if let message = json["error"]?["message"]?.string { return message }
            if let message = json["error"]?.string { return message }
            if let message = json["message"]?.string { return message }
            if let detail = json["detail"]?.string { return detail }
            if let detail = json["detail"], let line = try? JSONCoding.line(detail) { return clip(line) }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no body)" : clip(text)
    }

    /// Retry-After as seconds or an HTTP date.
    static func retryAfter(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    static func clip(_ text: String, _ limit: Int = 500) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
