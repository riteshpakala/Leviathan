//
//  SeasonImport.swift
//  LeviathanCore
//
//  WHAT: Brings writing into a work: a Gita's Ballad season export (Timeline → Export), the
//        season's Narrative.json, or any plain text file.
//  IN:   A season is JSON with `format: "gita.season"`, version 1 or 2, as Gita's
//        SeasonExport.swift writes it. Passages carry their id, text, the tool whose mark asked
//        for them, the marked excerpt, `kind: "dream"` for marginalia, and when they were made.
//  PIN:  Importing again adds only passages whose id is new, so a later export of the same
//        season extends the work. A version newer than 2 is refused, as Gita itself refuses
//        it, rather than half-read. The opening counts as authored only when it matches the
//        narrative's openingPassage; every other season passage was written by the story's
//        model and counts as generated. Text files count as authored.
//

import Foundation

/// The parts of Gita's Narrative.json the studies use.
public struct Narrative: Codable, Sendable, Hashable {
    public struct Character: Codable, Sendable, Hashable {
        public var id: String?
        public var name: String
        public var role: String
        public var essence: String
    }

    public var title: String?
    public var authorPreamble: String
    public var openingPassage: String?
    public var openingUserTurn: String?
    public var toolDirectives: [String: String]?
    public var dreamDirective: String?
    public var characters: [Character]?
}

struct SeasonFile: Decodable {
    struct Meta: Decodable {
        var id: String?
        var number: Int?
    }

    struct Passage: Decodable {
        var id: String
        var text: String
        var tool: String?
        var excerpt: String?
        var kind: String?
        var createdAt: String?
    }

    var format: String
    var version: Int
    var title: String?
    var passages: [Passage]
    var season: Meta?
}

public struct ImportSummary: Codable, Sendable {
    public var work: String
    public var added: Int
    public var alreadyPresent: Int
    public var authored: Int
    public var generated: Int
    public var total: Int

    public init(work: String, added: Int, alreadyPresent: Int, authored: Int, generated: Int, total: Int) {
        self.work = work
        self.added = added
        self.alreadyPresent = alreadyPresent
        self.authored = authored
        self.generated = generated
        self.total = total
    }
}

public enum WorkImport {
    public static let seasonFormat = "gita.season"
    public static let newestSeasonVersion = 2

    /// Creates the work when it is new; returns it.
    public static func ensure(_ id: String, title: String?, author: String?, in workspace: Workspace) throws -> Work {
        guard PathComponent.isPlain(id) else {
            throw LeviathanFailure("'\(id)' is not a work id: ids take [A-Za-z0-9._-] and cannot start with _", code: LeviathanFailure.ExitCode.usage)
        }
        var work = WorkStore.exists(id, in: workspace) ? try WorkStore.load(id, in: workspace) : Work(id: id, title: title ?? id, author: author)
        if let title { work.title = title }
        if let author {
            work.author = author
            work.origins[PassageOrigin.authored.rawValue]?.writer = author
        }
        try WorkStore.save(work, in: workspace)
        return work
    }

    /// Keeps the season's narrative file beside the passages, as given.
    public static func narrative(_ data: Data, name: String, work id: String, in workspace: Workspace) throws -> Narrative {
        let narrative: Narrative
        do {
            narrative = try JSONDecoder().decode(Narrative.self, from: data)
        } catch {
            throw LeviathanFailure("\(name) is not a Gita narrative file: \(error)", code: LeviathanFailure.ExitCode.data)
        }
        let url = WorkStore.narrativeFile(id, in: workspace)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        var work = try WorkStore.load(id, in: workspace)
        work.sources.append(WorkSource(kind: "narrative", file: name, sha256: Hashing.sha256Hex(data), importedAt: Date(), added: 0))
        try WorkStore.save(work, in: workspace)
        // A season imported before its narrative: its opening can be recognised now.
        var passages = try WorkStore.passages(id, in: workspace)
        if let opening = narrative.openingPassage.map(Self.squashed),
           let first = passages.firstIndex(where: { $0.source == "season" }), passages[first].tool == nil, passages[first].kind == nil,
           passages[first].origin == .generated, Self.squashed(passages[first].text) == opening {
            passages[first].origin = .authored
            try WorkStore.savePassages(passages, work: id, in: workspace)
        }
        return narrative
    }

    public static func season(_ data: Data, name: String, work id: String, in workspace: Workspace) throws -> ImportSummary {
        let file: SeasonFile
        do {
            file = try JSONDecoder().decode(SeasonFile.self, from: data)
        } catch {
            throw LeviathanFailure("\(name) is not a Gita season export: \(error)", code: LeviathanFailure.ExitCode.data)
        }
        guard file.format == seasonFormat else {
            throw LeviathanFailure("\(name) is not a Gita season (format '\(file.format)')", code: LeviathanFailure.ExitCode.data)
        }
        guard file.version <= newestSeasonVersion else {
            throw LeviathanFailure("\(name) was exported by a newer Gita (format v\(file.version)); this Leviathan reads up to v\(newestSeasonVersion)",
                                   code: LeviathanFailure.ExitCode.data)
        }
        let opening = WorkStore.narrative(id, in: workspace)?.openingPassage.map(Self.squashed)
        let dates = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let incoming = file.passages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.enumerated().map { offset, passage in
            let isOpening = offset == 0 && passage.tool == nil && passage.kind == nil
            let authored = isOpening && opening != nil && Self.squashed(passage.text) == opening
            return WorkPassage(index: 0, id: passage.id, text: passage.text, origin: authored ? .authored : .generated, tool: passage.tool,
                               excerpt: passage.excerpt, kind: passage.kind,
                               createdAt: passage.createdAt.flatMap { dates.date(from: $0) ?? fractional.date(from: $0) }, source: "season")
        }
        return try merge(incoming, source: WorkSource(kind: "season", file: name, sha256: Hashing.sha256Hex(data), importedAt: Date(), added: 0),
                         work: id, in: workspace)
    }

    /// Plain text: one passage per paragraph, short paragraphs folded into the next.
    public static func text(_ text: String, name: String, work id: String, in workspace: Workspace) throws -> ImportSummary {
        let chunks = TextChunker.chunk(text, maxChars: 2_400, minChars: 300)
        guard !chunks.isEmpty else { throw LeviathanFailure("\(name) holds no text", code: LeviathanFailure.ExitCode.data) }
        let incoming = chunks.map { chunk in
            WorkPassage(index: 0, id: "text-" + String(Hashing.sha256Hex(chunk).prefix(16)), text: chunk, origin: .authored, source: "text:\(name)")
        }
        return try merge(incoming, source: WorkSource(kind: "text", file: name, sha256: Hashing.sha256Hex(Data(text.utf8)), importedAt: Date(), added: 0),
                         work: id, in: workspace)
    }

    static func merge(_ incoming: [WorkPassage], source: WorkSource, work id: String, in workspace: Workspace) throws -> ImportSummary {
        var work = try WorkStore.load(id, in: workspace)
        var passages = try WorkStore.passages(id, in: workspace)
        let known = Set(passages.map(\.id))
        var next = (passages.map(\.index).max() ?? -1) + 1
        var added = 0
        for var passage in incoming where !known.contains(passage.id) {
            passage.index = next
            next += 1
            passages.append(passage)
            added += 1
        }
        try WorkStore.savePassages(passages, work: id, in: workspace)
        var record = source
        record.added = added
        work.sources.append(record)
        try WorkStore.save(work, in: workspace)
        return ImportSummary(work: id, added: added, alreadyPresent: incoming.count - added,
                             authored: passages.filter { $0.origin == .authored }.count,
                             generated: passages.filter { $0.origin == .generated }.count, total: passages.count)
    }

    /// Whitespace runs as single spaces, so a re-flowed copy still matches.
    static func squashed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
