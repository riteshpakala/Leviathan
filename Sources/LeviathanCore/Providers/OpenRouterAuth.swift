//
//  OpenRouterAuth.swift
//  LeviathanCore
//
//  WHAT: Sign in with OpenRouter: the browser asks the person to approve, OpenRouter redirects
//        to a one-time listener on this Mac with a code, and the code is exchanged for a key.
//  PIN:  PKCE with S256, and a random `state` that must come back unchanged, so a redirect from
//        anywhere else is refused. The auth page and the exchange are found from the provider's
//        base URL (https://openrouter.ai/api/v1 → https://openrouter.ai/auth and
//        …/api/v1/auth/keys), so a stand-in host can be tested the same way. The key is
//        returned to the caller to save; it is never logged.
//

import CryptoKit
import Foundation

public struct OpenRouterAuth: Sendable {
    public let provider: Provider
    public let session: URLSession

    public init(provider: Provider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    /// 32 random bytes, base64url: the PKCE verifier, and the `state`.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The site the API lives under: https://openrouter.ai for https://openrouter.ai/api/v1.
    func site() throws -> URL {
        let api = try provider.endpoint("x").deletingLastPathComponent()
        var path = api.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api/v1") { path.removeLast("/api/v1".count) }
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)
        components?.path = path
        guard let url = components?.url else {
            throw LeviathanFailure("provider \(provider.id) has an unusable base URL", code: LeviathanFailure.ExitCode.config)
        }
        return url
    }

    public func authorizationURL(callback: URL, challenge: String, state: String, label: String) throws -> URL {
        var components = URLComponents(url: try site().appendingPathComponent("auth"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "callback_url", value: callback.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "key_label", value: label),
        ]
        guard let url = components?.url else {
            throw LeviathanFailure("could not build the sign-in address", code: LeviathanFailure.ExitCode.software)
        }
        return url
    }

    /// Trades the code from the redirect for a key.
    public func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: try provider.endpoint("auth/keys"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.lineEncoder().encode([
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ChatError.http(status: status, message: OpenAICompatibleClient.errorMessage(data))
        }
        guard let key = JSONValue.parse(data)?["key"]?.string, !key.isEmpty else {
            throw ChatError.unreadable("the sign-in answer held no key")
        }
        return key
    }

    /// The whole flow: listen, open the approval page, wait for the redirect, exchange the code.
    public func signIn(label: String = "Leviathan", timeout: Double = 300, open: @Sendable (URL) async -> Void) async throws -> String {
        let listener = LoopbackListener(path: "/callback")
        let port = try await listener.start()
        defer { listener.stop() }
        let verifier = Self.randomToken()
        let state = Self.randomToken()
        guard let callback = URL(string: "http://localhost:\(port)/callback") else {
            throw LeviathanFailure("could not build the callback address", code: LeviathanFailure.ExitCode.software)
        }
        await open(try authorizationURL(callback: callback, challenge: Self.challenge(for: verifier), state: state, label: label))
        let query = try await listener.waitForCallback(timeout: timeout)
        if let error = query["error"] {
            throw LeviathanFailure("OpenRouter did not approve the sign-in: \(error)", code: LeviathanFailure.ExitCode.noPermission)
        }
        guard query["state"] == state else {
            throw LeviathanFailure("the answer did not come from this sign-in, so it was ignored", hint: "start the sign-in again",
                                   code: LeviathanFailure.ExitCode.noPermission)
        }
        guard let code = query["code"], !code.isEmpty else {
            throw LeviathanFailure("OpenRouter's answer held no code", hint: "start the sign-in again", code: LeviathanFailure.ExitCode.unavailable)
        }
        return try await exchange(code: code, verifier: verifier)
    }
}
