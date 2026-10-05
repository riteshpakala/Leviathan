import Foundation
import Testing
@testable import LeviathonCore

/// Answers requests from a handler chosen by the request's host, so tests running in parallel
/// never share one.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, [String: String], Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [(URLRequest, Data?)]] = [:]
    private static let lock = NSLock()

    static func register(_ host: String, _ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
        seen[host] = []
    }

    static func requests(_ host: String) -> [(URLRequest, Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return seen[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.lock.lock()
        let handler = Self.handlers[host]
        Self.seen[host, default: []].append((request, body))
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, headers, data) = handler(request, body)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class SleepLog: @unchecked Sendable {
    private var delays: [Double] = []
    private let lock = NSLock()
    func record(_ delay: Double) {
        lock.lock()
        delays.append(delay)
        lock.unlock()
    }
    var all: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }
}

@Suite("OpenAI-compatible client")
struct ClientTests {
    func client(_ host: String, extraBody: [String: JSONValue] = [:], sleeps: SleepLog = SleepLog()) -> OpenAICompatibleClient {
        let provider = Provider(id: "stub", name: "Stub", baseURL: "http://\(host)/v1/", extraBody: extraBody)
        return OpenAICompatibleClient(provider: provider, apiKey: "secret", session: StubProtocol.session(),
                                      retry: RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 4), sleep: { sleeps.record($0) })
    }

    static let ok = Data(#"{"model":"m1-2026","choices":[{"message":{"role":"assistant","content":"Hello there."},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}"#.utf8)

    @Test("sends one completion with the temperature, the target's max-tokens field and the provider's extra fields")
    func requestShape() async throws {
        let host = "shape-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (200, [:], Self.ok) }
        let client = client(host, extraBody: ["thinking": .object(["type": .string("disabled")])])
        let completion = try await client.complete(ChatRequest(
            model: "m1", messages: [ChatMessage(role: "user", content: "Hi")], temperature: 0.4, maxTokens: 64,
            maxTokensField: .maxCompletionTokens))
        #expect(completion.content == "Hello there.")
        #expect(completion.usage?.completionTokens == 3)
        #expect(completion.reportedModel == "m1-2026")
        let (request, body) = try #require(StubProtocol.requests(host).first)
        #expect(request.url?.absoluteString == "http://\(host)/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let json = try #require(body.flatMap(JSONValue.parse))
        #expect(json["temperature"]?.number == 0.4)
        #expect(json["max_completion_tokens"]?.int == 64)
        #expect(json["max_tokens"] == nil)
        #expect(json["n"] == nil)
        #expect(json["stream"] == .bool(false))
        #expect(json["thinking"]?["type"]?.string == "disabled")
    }

    @Test("no temperature is sent for a default-only request")
    func noTemperature() async throws {
        let host = "default-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (200, [:], Self.ok) }
        _ = try await client(host).complete(ChatRequest(model: "m1", messages: [ChatMessage(role: "user", content: "Hi")]))
        let body = try #require(StubProtocol.requests(host).first?.1.flatMap(JSONValue.parse))
        #expect(body["temperature"] == nil)
    }

    @Test("reads content given as parts, reasoning beside it, and token log-probabilities")
    func lenient() throws {
        let json = try #require(JSONValue.parse(Data(#"""
        {"choices":[{"message":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Hmm."}]},{"type":"text","text":"Answer."}]},
          "logprobs":{"content":[{"token":"Answer","logprob":-0.5,"top_logprobs":[{"token":"Answer","logprob":-0.5}]},{"token":".","logprob":-0.1}]},
          "finish_reason":"stop"}]}
        """#.utf8)))
        let completion = try OpenAICompatibleClient.decodeCompletion(json)
        #expect(completion.content == "Answer.")
        #expect(completion.reasoning == "Hmm.")
        #expect(completion.logprobs?.map(\.token) == ["Answer", "."])
        let other = try OpenAICompatibleClient.decodeCompletion(
            try #require(JSONValue.parse(Data(#"{"choices":[{"message":{"content":"x","reasoning_content":"why"}}]}"#.utf8))))
        #expect(other.reasoning == "why" && other.usage == nil)
    }

    @Test("retries a 429, honouring Retry-After, then succeeds")
    func retries() async throws {
        let host = "retry-\(UUID().uuidString.lowercased()).test"
        let calls = SleepLog()
        StubProtocol.register(host) { _, _ in
            calls.record(0)
            return calls.all.count == 1 ? (429, ["Retry-After": "7"], Data(#"{"error":{"message":"slow down"}}"#.utf8)) : (200, [:], Self.ok)
        }
        let sleeps = SleepLog()
        let completion = try await client(host, sleeps: sleeps).complete(ChatRequest(model: "m1", messages: [ChatMessage(role: "user", content: "Hi")]))
        #expect(completion.content == "Hello there.")
        #expect(sleeps.all == [7])
    }

    @Test("a 400 fails at once with the host's message, and one about temperature is recognised")
    func rejection() async throws {
        let host = "reject-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in
            (400, [:], Data(#"{"error":{"message":"temperature is not supported with this model"}}"#.utf8))
        }
        let sleeps = SleepLog()
        do {
            _ = try await client(host, sleeps: sleeps).complete(ChatRequest(model: "m1", messages: [], temperature: 0.4))
            Issue.record("expected a failure")
        } catch let error as ChatError {
            #expect(error.rejectsTemperature)
            #expect(error.description.contains("temperature is not supported"))
        }
        #expect(sleeps.all.isEmpty)
        #expect(StubProtocol.requests(host).count == 1)
    }

    @Test("gives up after the last attempt on a host that keeps failing")
    func exhausted() async throws {
        let host = "down-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (503, [:], Data("busy".utf8)) }
        let sleeps = SleepLog()
        do {
            _ = try await client(host, sleeps: sleeps).complete(ChatRequest(model: "m1", messages: []))
            Issue.record("expected a failure")
        } catch let error as ChatError {
            guard case .exhausted(let attempts, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(attempts == 3)
        }
        #expect(sleeps.all == [1, 2])
    }

    @Test("lists models from data[].id or a bare array")
    func models() async throws {
        let host = "models-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (200, [:], Data(#"{"object":"list","data":[{"id":"b"},{"id":"a"}]}"#.utf8)) }
        #expect(try await client(host).listModels() == ["a", "b"])
        let bare = "bare-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(bare) { _, _ in (200, [:], Data(#"[{"id":"x"}]"#.utf8)) }
        #expect(try await client(bare).listModels() == ["x"])
    }

    @Test("Retry-After as seconds or an HTTP date")
    func retryAfter() {
        #expect(OpenAICompatibleClient.retryAfter("3") == 3)
        #expect(OpenAICompatibleClient.retryAfter(nil) == nil)
        #expect(OpenAICompatibleClient.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == 0)
    }
}
