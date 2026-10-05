//
//  PrivateText.swift
//  LeviathanCore
//
//  WHAT: The gate between a private work and a host: a work's text goes only to a provider
//        you cleared for it, after reading the host's data terms, and with the fields that keep
//        it out of the host's logging and retention.
//  PIN:  A runtime on this Mac is cleared from the start. A host whose terms allow training on
//        inputs (DeepSeek's own API) can never be cleared. Every other host starts uncleared,
//        and a harvest in a private work stops before sending anything to it (exit 77).
//

import Foundation

public enum PrivateText {
    /// Throws unless `provider` may receive this work's text.
    public static func check(_ provider: Provider, work: Work?) throws {
        guard let work, work.isPrivate else { return }
        if let refusal = provider.presetInfo?.privateRefusal {
            throw LeviathanFailure("\(provider.id) never receives a private work's text: \(refusal)", code: LeviathanFailure.ExitCode.noPermission)
        }
        guard provider.acceptsPrivateText else {
            throw LeviathanFailure(
                "\(provider.id) is not cleared for \(work.title)'s text, so nothing was sent",
                hint: "read the host's data terms\(provider.presetInfo?.dataTerms.map { " (\($0))" } ?? ""), then clear it on its page in the app, "
                    + "or: leviathan providers private \(provider.id) --allow --source <where you read them>",
                code: LeviathanFailure.ExitCode.noPermission)
        }
    }

    /// The provider as requests carrying the work's text use it: cleared, with its private fields
    /// merged over its extra fields.
    public static func prepare(_ provider: Provider, work: Work?) throws -> Provider {
        try check(provider, work: work)
        guard let work, work.isPrivate, !provider.privateExtraBody.isEmpty else { return provider }
        var prepared = provider
        prepared.extraBody = JSONValue.merge(provider.privateExtraBody, over: provider.extraBody)
        return prepared
    }

    /// Clears a provider for private text, or withdraws it.
    public static func clear(_ provider: Provider, allow: Bool, source: String?) throws -> Provider {
        var cleared = provider
        if allow {
            if let refusal = provider.presetInfo?.privateRefusal {
                throw LeviathanFailure("\(provider.id) cannot be cleared for private text: \(refusal)", code: LeviathanFailure.ExitCode.noPermission)
            }
            guard let source, !source.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LeviathanFailure("say where you read \(provider.id)'s data terms", hint: "--source <url>", code: LeviathanFailure.ExitCode.usage)
            }
            cleared.acceptsPrivateText = true
            cleared.privateSource = source
            if cleared.privateExtraBody.isEmpty, let fields = provider.presetInfo?.privateExtraBody { cleared.privateExtraBody = fields }
        } else {
            cleared.acceptsPrivateText = false
            cleared.privateSource = nil
        }
        return cleared
    }
}

extension JSONValue {
    /// `top` over `base`, objects merged key by key at every depth.
    public static func merge(_ top: [String: JSONValue], over base: [String: JSONValue]) -> [String: JSONValue] {
        var result = base
        for (key, value) in top {
            if case .object(let inner) = value, case .object(let existing) = base[key] ?? .null {
                result[key] = .object(merge(inner, over: existing))
            } else {
                result[key] = value
            }
        }
        return result
    }
}
