//
//  Failure.swift
//  LeviathanCore
//
//  WHAT: An error a person or an agent can act on: what went wrong, what to do about it, and an
//        exit code that says which kind of failure it was.
//  PIN:  The codes follow sysexits, as RaoLM's do, so a script can tell a missing input from a
//        host that is down from a model whose terms forbid the export.
//

import Foundation

public struct LeviathanFailure: Error, CustomStringConvertible, Sendable, Codable {
    public var message: String
    public var hint: String?
    public var code: Int32

    public init(_ message: String, hint: String? = nil, code: Int32 = ExitCode.software) {
        self.message = message
        self.hint = hint
        self.code = code
    }

    public var description: String {
        hint.map { "\(message)\n  hint: \($0)" } ?? message
    }

    public enum ExitCode {
        /// The command was used wrongly.
        public static let usage: Int32 = 64
        /// A file Leviathan reads is malformed.
        public static let data: Int32 = 65
        /// A model, prompt set, prompt or provider that was named does not exist.
        public static let noInput: Int32 = 66
        /// The host could not be reached, or refused the request.
        public static let unavailable: Int32 = 69
        /// A bug: something Leviathan guarantees did not hold.
        public static let software: Int32 = 70
        /// An output could not be written.
        public static let cantCreate: Int32 = 73
        /// Retries ran out; running again may succeed.
        public static let tempFail: Int32 = 75
        /// The model's terms do not permit what was asked.
        public static let noPermission: Int32 = 77
        /// A model or provider is configured wrongly for what was asked.
        public static let config: Int32 = 78
    }
}
