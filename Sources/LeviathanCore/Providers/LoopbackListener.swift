//
//  LoopbackListener.swift
//  LeviathanCore
//
//  WHAT: Waits for one browser redirect to http://localhost:<port><path>, answers it with a
//        short page the person can close, and hands back the redirect's query.
//  PIN:  Listens on the loopback interface only, IPv4 and IPv6, on a port the system picks, so
//        nothing off this Mac can reach it. Other paths (a favicon) get a 404 and the wait goes
//        on. Single use: once it has an answer, a timeout, or a stop, it is done.
//

import Foundation
import Network

public final class LoopbackListener: @unchecked Sendable {
    public let path: String
    private let queue = DispatchQueue(label: "nyc.rao.leviathan.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?
    private var failure: Error?

    public init(path: String = "/callback") {
        self.path = path
    }

    /// Starts listening; returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        lock.withLock { self.listener = listener }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { ready = continuation }
            listener.stateUpdateHandler = { [self] state in update(state) }
            listener.newConnectionHandler = { [self] connection in accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// The query of the first request to `path`. Throws when `timeout` seconds pass first.
    public func waitForCallback(timeout: Double) async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            fail(LeviathanFailure("no answer from the browser within \(Int(timeout)) seconds", hint: "start the sign-in again",
                                  code: LeviathanFailure.ExitCode.tempFail))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let received {
                    lock.unlock()
                    continuation.resume(returning: received)
                } else if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    public func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        fail(CancellationError())
    }

    // MARK: Listener

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = lock.withLock { listener?.port?.rawValue }
            let continuation = lock.withLock { () -> CheckedContinuation<UInt16, Error>? in
                defer { ready = nil }
                return ready
            }
            if let port {
                continuation?.resume(returning: port)
            } else {
                continuation?.resume(throwing: LeviathanFailure("the listener has no port", code: LeviathanFailure.ExitCode.software))
            }
        case .failed(let error):
            let continuation = lock.withLock { () -> CheckedContinuation<UInt16, Error>? in
                defer { ready = nil }
                return ready
            }
            let failure = LeviathanFailure("could not listen on localhost: \(error)", code: LeviathanFailure.ExitCode.unavailable)
            continuation?.resume(throwing: failure)
            fail(failure)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, !complete, error == nil, buffer.count < 65_536 {
                receive(connection, buffer: buffer)
                return
            }
            respond(connection, request: String(decoding: buffer, as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let target = request.split(separator: "\r\n", maxSplits: 1).first.map { line in
            line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        } ?? ""
        let components = URLComponents(string: "http://localhost" + target)
        let status: String
        let page: String
        if components?.path == path {
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            status = "200 OK"
            page = query["error"] == nil
                ? Self.page("Leviathan is connected", "You can close this tab and go back to Leviathan.")
                : Self.page("Sign-in did not finish", "The host said: \(query["error"] ?? ""). Go back to Leviathan to try again.")
            deliver(query)
        } else {
            status = "404 Not Found"
            page = Self.page("Not here", "This address only takes Leviathan's sign-in.")
        }
        let body = Data(page.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func deliver(_ query: [String: String]) {
        lock.lock()
        guard received == nil, failure == nil else {
            lock.unlock()
            return
        }
        received = query
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(returning: query)
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard received == nil, failure == nil else {
            lock.unlock()
            return
        }
        failure = error
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    static func page(_ title: String, _ text: String) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><meta charset="utf-8"><title>\(escape(title))</title>
        <body style="font: 16px -apple-system, sans-serif; max-width: 32em; margin: 18vh auto; padding: 0 16px; line-height: 1.5">
        <h1 style="font-weight: 600; font-size: 22px">\(escape(title))</h1><p>\(escape(text))</p></body>
        """
    }
}
