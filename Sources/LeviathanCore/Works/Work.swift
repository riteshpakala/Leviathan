//
//  Work.swift
//  LeviathanCore
//
//  WHAT: A body of your own writing, kept apart from everything else: works/<id>/ holds its
//        passages, the prompts made from them, every model's answers, and the reports.
//  OUT:  works/<id>/work.json            title, author, sources with hashes, terms per origin
//        works/<id>/source/passages.jsonl one passage per line, in reading order
//        works/<id>/source/narrative.json the season's narrative file, as given
//  PIN:  works/ is git-ignored: nothing here is committed. Each passage says whether you wrote
//        it (`authored`) or a model wrote it in your story (`generated`), and each origin
//        carries its own terms: authored text starts permitted, generated text unknown, so a
//        model-written passage is never exported until you say what its writer allows.
//

import Foundation

public enum PassageOrigin: String, Codable, Sendable, CaseIterable {
    /// You wrote it.
    case authored
    /// A model wrote it, in answer to your marks.
    case generated
}

public struct WorkPassage: Codable, Sendable, Hashable, Identifiable {
    /// Its place in reading order, from 0.
    public var index: Int
    /// The season passage's id, or `text-…` for imported text.
    public var id: String
    public var text: String
    public var origin: PassageOrigin
    /// pen, pencil or highlighter: the mark that asked for it.
    public var tool: String?
    /// The marked words it continues from.
    public var excerpt: String?
    /// "dream" for Night Ink marginalia.
    public var kind: String?
    public var createdAt: Date?
    /// The source it came from: "season", or "text:<file name>".
    public var source: String

    public init(index: Int, id: String, text: String, origin: PassageOrigin, tool: String? = nil, excerpt: String? = nil, kind: String? = nil,
                createdAt: Date? = nil, source: String) {
        self.index = index
        self.id = id
        self.text = text
        self.origin = origin
        self.tool = tool
        self.excerpt = excerpt
        self.kind = kind
        self.createdAt = createdAt
        self.source = source
    }

    public var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    public var isDream: Bool { kind == "dream" }
}

public struct WorkSource: Codable, Sendable, Hashable {
    /// season, narrative or text.
    public var kind: String
    /// The file's name as imported.
    public var file: String
    public var sha256: String
    public var importedAt: Date
    /// Passages it added on that import.
    public var added: Int
}

public struct OriginTerms: Codable, Sendable, Hashable {
    public var trainingUse: TrainingUse
    /// Who wrote text of this origin: you, or the model and host that generated it.
    public var writer: String?
    public var note: String?

    public init(trainingUse: TrainingUse, writer: String? = nil, note: String? = nil) {
        self.trainingUse = trainingUse
        self.writer = writer
        self.note = note
    }
}

public struct Work: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var author: String?
    /// Private text is sent only to hosts cleared for it.
    public var isPrivate: Bool
    public var sources: [WorkSource]
    public var origins: [String: OriginTerms]
    public var createdAt: Date

    public init(id: String, title: String, author: String? = nil, isPrivate: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.author = author
        self.isPrivate = isPrivate
        sources = []
        origins = [
            PassageOrigin.authored.rawValue: OriginTerms(trainingUse: .permitted, writer: author, note: "Your own words."),
            PassageOrigin.generated.rawValue: OriginTerms(
                trainingUse: .unknown, note: "Written by the story's model; record which model, and what its terms allow, before exporting."),
        ]
        self.createdAt = createdAt
    }

    public func terms(for origin: String?) -> OriginTerms {
        origin.flatMap { origins[$0] } ?? OriginTerms(trainingUse: .unknown)
    }
}

public enum WorkStore {
    public static func file(_ id: String, in workspace: Workspace) -> URL {
        workspace.workDirectory(id).appendingPathComponent("work.json")
    }

    public static func passagesFile(_ id: String, in workspace: Workspace) -> URL {
        workspace.workDirectory(id).appendingPathComponent("source/passages.jsonl")
    }

    public static func narrativeFile(_ id: String, in workspace: Workspace) -> URL {
        workspace.workDirectory(id).appendingPathComponent("source/narrative.json")
    }

    public static func exists(_ id: String, in workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: file(id, in: workspace).path)
    }

    public static func load(_ id: String, in workspace: Workspace) throws -> Work {
        let url = file(id, in: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LeviathanFailure("no work '\(id)' (no \(workspace.relative(url)))", hint: "leviathan works import --work \(id) --season <file>",
                                   code: LeviathanFailure.ExitCode.noInput)
        }
        do {
            return try JSONCoding.read(Work.self, from: url)
        } catch {
            throw LeviathanFailure("\(workspace.relative(url)) is malformed: \(error)", code: LeviathanFailure.ExitCode.data)
        }
    }

    public static func save(_ work: Work, in workspace: Workspace) throws {
        try JSONCoding.write(work, to: file(work.id, in: workspace))
    }

    public static func passages(_ id: String, in workspace: Workspace) throws -> [WorkPassage] {
        let url = passagesFile(id, in: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONCoding.readLines(WorkPassage.self, from: url).sorted { $0.index < $1.index }
    }

    public static func savePassages(_ passages: [WorkPassage], work id: String, in workspace: Workspace) throws {
        try JSONCoding.writeLines(passages.sorted { $0.index < $1.index }, to: passagesFile(id, in: workspace))
    }

    public static func narrative(_ id: String, in workspace: Workspace) -> Narrative? {
        try? JSONCoding.read(Narrative.self, from: narrativeFile(id, in: workspace))
    }

    /// Every work under works/, by id.
    public static func all(in workspace: Workspace) -> [Work] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.worksDirectory.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }.compactMap { try? load($0, in: workspace) }
    }
}
