//
//  PromptSet.swift
//  LeviathonCore
//
//  WHAT: The prompts Leviathon asks: prompts/<set-id>/<prompt-id>.md, one prompt per file, an
//        optional _system.md for the whole set, and an optional set.json.
//  PIN:  A prompt's hash covers the messages actually sent, system prompt included, so editing
//        either starts its samples afresh instead of mixing answers to two different questions.
//

import Foundation

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
    public var text: String
    /// The messages sent: the set's system prompt if any, then this prompt.
    public var messages: [ChatMessage]
    /// `sha256:` over the messages as one compact JSON line.
    public var sha: String

    public init(id: String, text: String, system: String?) {
        self.id = id
        self.text = text
        var messages: [ChatMessage] = []
        if let system, !system.isEmpty { messages.append(ChatMessage(role: "system", content: system)) }
        messages.append(ChatMessage(role: "user", content: text))
        self.messages = messages
        sha = Prompt.hash(messages)
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
            throw LeviathonFailure("no prompt '\(id)' in set '\(self.id)'", code: LeviathonFailure.ExitCode.noInput)
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
            throw LeviathonFailure("'\(id)' is not a prompt set id: ids take [A-Za-z0-9._-] and cannot start with _",
                                   code: LeviathonFailure.ExitCode.usage)
        }
        let directory = workspace.promptSetDirectory(id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LeviathonFailure("no prompt set '\(id)' (no \(workspace.relative(directory)))", hint: "leviathon prompts add --set \(id) …",
                                   code: LeviathonFailure.ExitCode.noInput)
        }
        let system = readText(directory.appendingPathComponent("_system.md"))
        var settings = PromptSetSettings()
        let settingsURL = directory.appendingPathComponent("set.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                settings = try JSONCoding.read(PromptSetSettings.self, from: settingsURL)
            } catch {
                throw LeviathonFailure("\(workspace.relative(settingsURL)) is malformed: \(error)", code: LeviathonFailure.ExitCode.data)
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let prompts = names.filter { $0.hasSuffix(".md") && !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted().compactMap { name -> Prompt? in
            guard let text = readText(directory.appendingPathComponent(name)) else { return nil }
            return Prompt(id: PathComponent.sanitize(String(name.dropLast(3))), text: text, system: system)
        }
        return PromptSet(id: id, system: system, settings: settings, prompts: prompts)
    }

    public static func all(in workspace: Workspace) -> [PromptSet] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.promptsDirectory.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }.compactMap { try? load($0, in: workspace) }
    }

    /// Writes one prompt, creating its set if needed.
    public static func add(set: String, id: String, text: String, in workspace: Workspace) throws -> URL {
        guard PathComponent.isPlain(set), PathComponent.isPlain(id) else {
            throw LeviathonFailure("set and prompt ids take [A-Za-z0-9._-] and cannot start with _", code: LeviathonFailure.ExitCode.usage)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LeviathonFailure("the prompt is empty", code: LeviathonFailure.ExitCode.usage) }
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
            throw LeviathonFailure("'\(settings.documentKind)' is not a RaoLM document kind", code: LeviathonFailure.ExitCode.usage)
        }
        try JSONCoding.write(settings, to: workspace.promptSetDirectory(set).appendingPathComponent("set.json"))
    }
}
