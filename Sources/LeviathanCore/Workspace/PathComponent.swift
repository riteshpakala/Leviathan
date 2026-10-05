//
//  PathComponent.swift
//  LeviathanCore
//
//  WHAT: The names Leviathan puts on disk and in RaoLM handles.
//  PIN:  Folder names keep `[A-Za-z0-9._-]`; anything else becomes `-` (`qwen2.5:14b` →
//        `qwen2.5-14b`). A Thread slug is `[a-z0-9-]`, at most 48 characters, so `raolm-<slug>`
//        is a valid RaoLM group handle and `raolm-<slug>-<hash>` a valid document id. A slug cut
//        to length ends in eight hex of the full name's hash, so two long names stay distinct.
//

import Foundation

public enum PathComponent {
    public static let slugLimit = 48

    /// A folder name: `[A-Za-z0-9._-]`, runs of anything else collapsed to one `-`, no leading
    /// or trailing `-` or `.`.
    public static func sanitize(_ raw: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in raw.unicodeScalars {
            let allowed = (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"))
            if allowed {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "unnamed" : trimmed
    }

    /// A RaoLM slug from several names: lowercase `[a-z0-9-]`, joined by `-`.
    public static func slug(_ parts: [String]) -> String {
        let full = parts.joined(separator: "-")
        var out = ""
        var pendingDash = false
        for scalar in full.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if out.isEmpty { out = "thread" }
        guard out.count > slugLimit else { return out }
        let suffix = String(Hashing.sha256Hex(full).prefix(8))
        let head = String(out.prefix(slugLimit - suffix.count - 1)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return head + "-" + suffix
    }

    /// Whether a name can be used as given for a prompt set or prompt id.
    public static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && sanitize(name) == name && !name.hasPrefix("_")
    }
}
