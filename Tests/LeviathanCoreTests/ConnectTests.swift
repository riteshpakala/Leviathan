import Foundation
import Testing
@testable import LeviathanCore

@Suite("Connecting a host")
struct ConnectTests {
    func openRouter(_ host: String) -> Provider {
        var provider = ProviderPresets.preset("openrouter")!.provider()
        provider.baseURL = "http://\(host)/api/v1"
        return provider
    }

    @Test("the PKCE challenge matches RFC 7636's example, and tokens are base64url")
    func challenge() {
        #expect(OpenRouterAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let token = OpenRouterAuth.randomToken()
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(token != OpenRouterAuth.randomToken())
    }

    @Test("the sign-in page sits under the site, not the API path")
    func authorizationURL() throws {
        let auth = OpenRouterAuth(provider: ProviderPresets.preset("openrouter")!.provider())
        let url = try auth.authorizationURL(callback: URL(string: "http://localhost:5123/callback")!, challenge: "abc", state: "s1", label: "Leviathan")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "openrouter.ai" && components.path == "/auth")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == ["callback_url": "http://localhost:5123/callback", "code_challenge": "abc", "code_challenge_method": "S256",
                          "state": "s1", "key_label": "Leviathan"])
    }

    @Test("the code is exchanged at /api/v1/auth/keys with its verifier")
    func exchange() async throws {
        let host = "exchange-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (200, [:], Data(#"{"key":"sk-or-v1-test","user_id":"u1"}"#.utf8)) }
        let key = try await OpenRouterAuth(provider: openRouter(host), session: StubProtocol.session()).exchange(code: "c1", verifier: "v1")
        #expect(key == "sk-or-v1-test")
        let (request, body) = try #require(StubProtocol.requests(host).first)
        #expect(request.httpMethod == "POST" && request.url?.path == "/api/v1/auth/keys")
        let json = try #require(body.flatMap(JSONValue.parse))
        #expect(json["code"]?.string == "c1" && json["code_verifier"]?.string == "v1" && json["code_challenge_method"]?.string == "S256")
    }

    @Test("a refused exchange is reported, not taken for a key")
    func refusedExchange() async throws {
        let host = "refused-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (403, [:], Data(#"{"error":{"message":"Invalid code"}}"#.utf8)) }
        await #expect(throws: ChatError.self) {
            _ = try await OpenRouterAuth(provider: openRouter(host), session: StubProtocol.session()).exchange(code: "c1", verifier: "v1")
        }
    }

    @Test("the listener answers on IPv4 and IPv6 loopback, ignores other paths, and hands back the query")
    func listener() async throws {
        let listener = LoopbackListener(path: "/callback")
        let port = try await listener.start()
        defer { listener.stop() }
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        let (page, found) = try await URLSession.shared.data(from: URL(string: "http://[::1]:\(port)/callback?code=c%201&state=s1")!)
        #expect((found as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("Leviathan is connected"))
        let query = try await listener.waitForCallback(timeout: 5)
        #expect(query == ["code": "c 1", "state": "s1"])
    }

    @Test("waiting gives up after the timeout")
    func listenerTimeout() async throws {
        let listener = LoopbackListener()
        _ = try await listener.start()
        defer { listener.stop() }
        await #expect(throws: LeviathanFailure.self) { _ = try await listener.waitForCallback(timeout: 0.2) }
    }

    /// Plays the browser: reads the callback and state from the approval page's address, then
    /// visits the callback the way OpenRouter's redirect would.
    static func approve(_ url: URL, state override: String? = nil) async {
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard var callback = query["callback_url"].flatMap(URLComponents.init(string:)) else { return }
        callback.queryItems = [URLQueryItem(name: "code", value: "c1"), URLQueryItem(name: "state", value: override ?? query["state"])]
        _ = try? await URLSession.shared.data(from: callback.url!)
    }

    @Test("sign-in runs end to end: approval, redirect, exchange")
    func signIn() async throws {
        let host = "signin-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { request, body in
            let json = body.flatMap(JSONValue.parse)
            guard request.url?.path == "/api/v1/auth/keys", json?["code"]?.string == "c1", json?["code_verifier"]?.string?.count == 43 else {
                return (400, [:], Data(#"{"error":{"message":"bad exchange"}}"#.utf8))
            }
            return (200, [:], Data(#"{"key":"sk-or-v1-signed"}"#.utf8))
        }
        let auth = OpenRouterAuth(provider: openRouter(host), session: StubProtocol.session())
        let key = try await auth.signIn(timeout: 10) { url in await Self.approve(url) }
        #expect(key == "sk-or-v1-signed")
    }

    @Test("a redirect carrying another state is refused before any exchange")
    func wrongState() async throws {
        let host = "state-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { _, _ in (200, [:], Data(#"{"key":"sk-should-not-be-used"}"#.utf8)) }
        let auth = OpenRouterAuth(provider: openRouter(host), session: StubProtocol.session())
        await #expect(throws: LeviathanFailure.self) {
            _ = try await auth.signIn(timeout: 10) { url in await Self.approve(url, state: "forged") }
        }
        #expect(StubProtocol.requests(host).isEmpty)
    }

    @Test("the catalogue reads OpenRouter's and Together's model lists, and ids alone")
    func catalogue() throws {
        let openRouter = try #require(JSONValue.parse(Data(#"""
        {"data":[{"id":"qwen/qwen3-32b","name":"Qwen: Qwen3 32B","context_length":40960,"hugging_face_id":"Qwen/Qwen3-32B",
          "pricing":{"prompt":"0.0000001","completion":"0.0000003"},"supported_parameters":["max_tokens","temperature","top_p"]},
         {"id":"anthropic/claude-x","name":"Claude X","pricing":{"prompt":"-1","completion":"0.00005"},"hugging_face_id":"",
          "supported_parameters":["max_tokens"]}]}
        """#.utf8)))
        let models = ModelCatalogue.parse(openRouter)
        let qwen = try #require(models.first { $0.id == "qwen/qwen3-32b" })
        #expect(qwen.openWeights && qwen.huggingFaceURL?.absoluteString == "https://huggingface.co/Qwen/Qwen3-32B")
        #expect(abs((qwen.inputPrice ?? 0) - 0.1) < 1e-9 && abs((qwen.outputPrice ?? 0) - 0.3) < 1e-9)
        #expect(qwen.takesTemperature == true && qwen.returnsLogprobs == false && qwen.contextLength == 40960)
        #expect(qwen.company(fallback: "x") == "qwen" && qwen.modelName == "qwen3-32b")
        let claude = try #require(models.first { $0.id == "anthropic/claude-x" })
        #expect(!claude.openWeights && claude.inputPrice == nil && claude.takesTemperature == false)

        let together = try #require(JSONValue.parse(Data(#"""
        [{"id":"meta-llama/Llama-3.3-70B-Instruct-Turbo","display_name":"Llama 3.3 70B","organization":"Meta","license":"llama3.3",
          "context_length":131072,"pricing":{"input":0.88,"output":0.88,"hourly":0}}]
        """#.utf8)))
        let llama = try #require(ModelCatalogue.parse(together).first)
        #expect(llama.inputPrice == 0.88 && llama.licence == "llama3.3" && llama.name == "Llama 3.3 70B" && llama.supportedParameters == nil)
        #expect(ModelCatalogue.parse(.object(["data": .array([.object(["id": .string("deepseek-chat")])])])).map(\.id) == ["deepseek-chat"])
    }

    @Test("a catalogue entry becomes a target with prices and sampling filled, and terms left alone")
    func target() {
        let provider = ProviderPresets.preset("openrouter")!.provider()
        let entry = CatalogueModel(id: "mistralai/mistral-small-3.2", inputPrice: 0.1, outputPrice: 0.3, supportedParameters: ["max_tokens"],
                                   licence: "apache-2.0")
        let target = entry.target(on: provider)
        #expect(target.company == "mistralai" && target.modelID == "mistral-small-3.2" && target.requestModel == "mistralai/mistral-small-3.2")
        #expect(target.sampling.temperature == .defaultOnly)
        #expect(target.terms.trainingUse == .unknown && target.terms.licence == nil)
        #expect(target.pricing?.cost(input: 1_000_000, output: 1_000_000) == 0.4)
        let deepseek = CatalogueModel(id: "deepseek-chat").target(on: ProviderPresets.preset("deepseek")!.provider())
        #expect(deepseek.company == "deepseek" && deepseek.sampling.temperature == .range && deepseek.pricing == nil)
        let closed = CatalogueModel(id: "anthropic/claude-fable-5.1", huggingFaceID: "").target(on: provider)
        #expect(closed.terms.trainingUse == .prohibited)
        let gemma = CatalogueModel(id: "google/gemma-3-27b-it", huggingFaceID: "google/gemma-3-27b-it").target(on: provider)
        #expect(gemma.terms.trainingUse == .unknown)
    }

    @Test("prices read as people write them")
    func prices() {
        #expect(KeyStatus.price(0.1) == "$0.10" && KeyStatus.price(0.05) == "$0.05" && KeyStatus.price(0.025) == "$0.025")
        #expect(KeyStatus.price(10) == "$10.00" && KeyStatus.price(0) == "free" && KeyStatus.price(nil) == "–")
        #expect(KeyStatus.dollars(0.63) == "$0.63" && KeyStatus.dollars(0.0042) == "$0.0042")
        let parsed = ModelCatalogue.parse(.object(["data": .array([.object([
            "id": .string("a/b"), "pricing": .object(["prompt": .string("0.0000001"), "completion": .string("0.0000003")])])])]))
        #expect(parsed.first?.inputPrice == 0.1 && parsed.first?.outputPrice == 0.3)
    }

    @Test("checking OpenRouter reads the key's credit and the model list, and a turned-down key is said plainly")
    func check() async throws {
        let host = "check-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host) { request, _ in
            switch request.url?.path {
            case "/api/v1/key": return (200, [:], Data(#"{"data":{"label":"Leviathan","limit":10,"limit_remaining":4.2,"usage":5.8,"is_free_tier":false}}"#.utf8))
            case "/api/v1/models": return (200, [:], Data(#"{"data":[{"id":"a/b"},{"id":"c/d"}]}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        let check = try await ProviderCheck.run(openRouter(host), key: "k", source: .keychain, session: StubProtocol.session())
        #expect(check.models.count == 2)
        #expect(check.keyStatus?.limitRemaining == 4.2)
        #expect(check.summary == "openrouter answered with 2 models (key: keychain); $4.20 left of $10.00 · $5.80 used")

        let refused = "refused-key-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(refused) { _, _ in (401, [:], Data(#"{"error":{"message":"No auth credentials found"}}"#.utf8)) }
        do {
            _ = try await ProviderCheck.run(openRouter(refused), key: nil, source: .none, session: StubProtocol.session())
            Issue.record("expected a failure")
        } catch let error as ChatError {
            #expect(error.rejectsKey && error.plain.hasPrefix("The host turned the key down"))
        }
    }

    @Test("the key goes to security as hex, so no character in it can break the command")
    func addCommand() {
        let line = KeychainSecretStore.addCommand(service: "svc", account: "openrouter", secret: "a b\"c")
        #expect(line == "add-generic-password -U -s svc -a openrouter -l svc.openrouter -X 6120622263\n")
        #expect(!line.contains("a b"))
    }

    @Test("a saved key is read back, replaced, and removed through the Keychain")
    func keychain() throws {
        let store = KeychainSecretStore(service: "nyc.rao.leviathan.test-\(UUID().uuidString.lowercased())")
        defer { try? store.delete("probe") }
        #expect(store.read("probe") == nil)
        try store.write("first value", account: "probe")
        #expect(store.read("probe") == "first value")
        try store.write("second", account: "probe")
        #expect(store.read("probe") == "second")
        try store.delete("probe")
        #expect(store.read("probe") == nil)
        try store.delete("probe")
    }
}
