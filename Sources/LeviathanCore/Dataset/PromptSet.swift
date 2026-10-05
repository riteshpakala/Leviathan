//
//  PromptSet.swift
//  LeviathanCore
//
//  WHAT: The prompts Leviathan asks: prompts/<set-id>/<prompt-id>.md, one prompt per file, an
//        optional _system.md for the whole set, and an optional set.json. A prompt may instead
//        be <prompt-id>.json: its own messages (a whole conversation), and optionally a
//        reference text to compare the answers with, such as the author's own passage.
//  PIN:  A prompt's hash covers the messages actually sent, system prompt included, so editing
//        either starts its samples afresh instead of mixing answers to two different questions.
//        The reference is never sent, so it is not in the hash.
//

import Foundation

/// A text the answers are measured against, kept beside a prompt and never sent.
public struct PromptReference: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        /// The passage is built on this text: areas show where the samples changed it.
        case baseline
        /// Shown beside the samples' passage, outside its measurements.
        case comparison
    }

    public var text: String
    public var role: Role
    /// The work passage it came from.
    public var passageID: String?
    /// authored or generated, in the work's own terms.
    public var origin: String?

    public init(text: String, role: Role, passageID: String? = nil, origin: String? = nil) {
        self.text = text
        self.role = role
        self.passageID = passageID
        self.origin = origin
    }
}

/// A prompt file in JSON: prompts/<set>/<id>.json.
public struct PromptFile: Codable, Sendable, Hashable {
    public var messages: [ChatMessage]
    public var reference: PromptReference?
    public var note: String?

    public init(messages: [ChatMessage], reference: PromptReference? = nil, note: String? = nil) {
        self.messages = messages
        self.reference = reference
        self.note = note
    }
}

public struct PromptSetSettings: Codable, Sendable, Hashable {
    /// The RaoLM document kind its Thread's documents are written as.
    public var documentKind: String
    public var description: String?

    public init(documentKind: String = DocumentKinds.harvested, description: String? = nil) {
        self.documentKind = documentKind
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case documentKind, description }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentKind = try c.decodeIfPresent(String.self, forKey: .documentKind) ?? DocumentKinds.harvested
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct Prompt: Sendable, Hashable, Identifiable {
    public var id: String
    /// The last thing asked: the prompt file's text, or a conversation's last user message.
    public var text: String
    /// The messages sent: the set's system prompt if any, then this prompt.
    public var messages: [ChatMessage]
    /// `sha256:` over the messages as one compact JSON line.
    public var sha: String
    public var reference: PromptReference?
    public var note: String?

    public init(id: String, text: String, system: String?) {
        self.id = id
        self.text = text
        var messages: [ChatMessage] = []
        if let system, !system.isEmpty { messages.append(ChatMessage(role: "system", content: system)) }
        messages.append(ChatMessage(role: "user", content: text))
        self.messages = messages
        sha = Prompt.hash(messages)
    }

    /// A conversation given whole; the set's system prompt leads it only when it has none of its own.
    public init(id: String, file: PromptFile, system: String?) {
        self.id = id
        var messages = file.messages
        if let system, !system.isEmpty, !messages.contains(where: { $0.role == "system" }) {
            messages.insert(ChatMessage(role: "system", content: system), at: 0)
        }
        self.messages = messages
        text = messages.last { $0.role == "user" }?.content ?? ""
        sha = Prompt.hash(messages)
        reference = file.reference
        note = file.note
    }

    public static func hash(_ messages: [ChatMessage]) -> String {
        "sha256:" + Hashing.sha256Hex((try? JSONCoding.line(messages)) ?? "")
    }
}

public struct PromptSet: Sendable, Hashable, Identifiable {
    public var id: String
    public var system: String?
    public var settings: PromptSetSettings
    public var prompts: [Prompt]

    public func prompt(_ id: String) throws -> Prompt {
        guard let prompt = prompts.first(where: { $0.id == id }) else {
            throw LeviathanFailure("no prompt '\(id)' in set '\(self.id)'", code: LeviathanFailure.ExitCode.noInput)
        }
        return prompt
    }
}

public enum PromptStore {
    static func readText(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func load(_ id: String, in workspace: Workspace) throws -> PromptSet {
        guard PathComponent.isPlain(id) else {
            throw LeviathanFailure("'\(id)' is not a prompt set id: ids take [A-Za-z0-9._-] and cannot start with _",
                                   code: LeviathanFailure.ExitCode.usage)
        }
        let directory = workspace.promptSetDirectory(id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LeviathanFailure("no prompt set '\(id)' (no \(workspace.relative(directory)))", hint: "leviathan prompts add --set \(id) …",
                                   code: LeviathanFailure.ExitCode.noInput)
        }
        let system = readText(directory.appendingPathComponent("_system.md"))
        var settings = PromptSetSettings()
        let settingsURL = directory.appendingPathComponent("set.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                settings = try JSONCoding.read(PromptSetSettings.self, from: settingsURL)
            } catch {
                throw LeviathanFailure("\(workspace.relative(settingsURL)) is malformed: \(error)", code: LeviathanFailure.ExitCode.data)
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var prompts: [Prompt] = []
        for name in names.sorted() where !name.hasPrefix("_") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".md") {
                guard let text = readText(url) else { continue }
                prompts.append(Prompt(id: PathComponent.sanitize(String(name.dropLast(3))), text: text, system: system))
            } else if name.hasSuffix(".json"), name != "set.json" {
                let file: PromptFile
                do {
                    file = try JSONCoding.read(PromptFile.self, from: url)
                } catch {
                    throw LeviathanFailure("\(workspace.relative(url)) is malformed: \(error)", code: LeviathanFailure.ExitCode.data)
                }
                guard file.messages.contains(where: { $0.role == "user" }) else { continue }
                prompts.append(Prompt(id: PathComponent.sanitize(String(name.dropLast(5))), file: file, system: system))
            }
        }
        return PromptSet(id: id, system: system, settings: settings, prompts: prompts)
    }

    public static func all(in workspace: Workspace) -> [PromptSet] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.promptsDirectory.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }.compactMap { try? load($0, in: workspace) }
    }

    /// Writes one conversation prompt, creating its set if needed.
    public static func add(set: String, id: String, file: PromptFile, in workspace: Workspace) throws -> URL {
        guard PathComponent.isPlain(set), PathComponent.isPlain(id) else {
            throw LeviathanFailure("set and prompt ids take [A-Za-z0-9._-] and cannot start with _", code: LeviathanFailure.ExitCode.usage)
        }
        let url = workspace.promptSetDirectory(set).appendingPathComponent("\(id).json")
        try JSONCoding.write(file, to: url)
        return url
    }

    /// Writes one prompt, creating its set if needed.
    public static func add(set: String, id: String, text: String, in workspace: Workspace) throws -> URL {
        guard PathComponent.isPlain(set), PathComponent.isPlain(id) else {
            throw LeviathanFailure("set and prompt ids take [A-Za-z0-9._-] and cannot start with _", code: LeviathanFailure.ExitCode.usage)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LeviathanFailure("the prompt is empty", code: LeviathanFailure.ExitCode.usage) }
        let url = workspace.promptSetDirectory(set).appendingPathComponent("\(id).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((trimmed + "\n").utf8).write(to: url, options: .atomic)
        return url
    }

    public static func setSystem(set: String, text: String?, in workspace: Workspace) throws {
        let url = workspace.promptSetDirectory(set).appendingPathComponent("_system.md")
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func saveSettings(_ settings: PromptSetSettings, set: String, in workspace: Workspace) throws {
        guard DocumentKinds.raolm.contains(settings.documentKind) else {
            throw LeviathanFailure("'\(settings.documentKind)' is not a RaoLM document kind", code: LeviathanFailure.ExitCode.usage)
        }
        try JSONCoding.write(settings, to: workspace.promptSetDirectory(set).appendingPathComponent("set.json"))
    }
}
