//
//  WorkCommands.swift
//  LeviathanCLI
//
//  WHAT: leviathan works list | import | show | study | origin | report — your own writing, kept
//        in works/<id>/, and what models show about it.
//  PIN:  Every other command runs inside a work with --work <id>: harvest, derive, passage, edit,
//        export and measure then read and write under works/<id>/. A private work's text goes
//        only to hosts cleared for it (leviathan providers private).
//

import ArgumentParser
import Foundation
import LeviathanCore

extension StudyKind: ExpressibleByArgument {}
extension PassageOrigin: ExpressibleByArgument {}

struct WorksGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "works", abstract: "Bring in your own writing and study what models show about it.",
        discussion: """
            A run:
              leviathan works import --work gita-ballad --narrative Narrative.json --season season.json
              leviathan works study  --work gita-ballad --kind revise
              leviathan harvest      --work gita-ballad --set revise --model qwen/qwen3-32b --dry-run
              leviathan derive       --work gita-ballad --set revise --model qwen/qwen3-32b
              leviathan works report --work gita-ballad
            """,
        subcommands: [List.self, Import.self, Show.self, MakeStudy.self, Origin.self, Report.self])

    static func workID(_ global: GlobalOptions) throws -> String {
        guard let work = global.work else { throw LeviathanFailure("name the work with --work <id>", code: LeviathanFailure.ExitCode.usage) }
        return work
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your works.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await global.guarded {
                let workspace = try global.rootWorkspace()
                let works = WorkStore.all(in: workspace)
                let rows = try works.map { work -> [String] in
                    let passages = try WorkStore.passages(work.id, in: workspace)
                    return [work.id, work.title, String(passages.filter { $0.origin == .authored }.count),
                            String(passages.filter { $0.origin == .generated }.count), work.isPrivate ? "private" : "shared"]
                }
                try global.emit(works, works.isEmpty ? "no works (leviathan works import --work <id> --season <file>)"
                    : Output.table(["work", "title", "authored", "generated", "text goes to"], rows.map { $0[0..<4] + [$0[4] == "private" ? "cleared hosts only" : "any host"] }))
            }
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Bring writing into a work: a Gita's Ballad season export, its Narrative.json, or plain text.",
            discussion: "Importing a later export of the same season adds only its new passages.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "A season exported from Gita's Ballad (Timeline → Export).")
        var season: String?

        @Option(help: "The season's Narrative.json: its preamble, opening and directives.")
        var narrative: String?

        @Option(help: "A text file of your own writing; one passage per paragraph (repeatable).")
        var text: [String] = []

        @Option(help: "The work's title (default: its id).")
        var title: String?

        @Option(help: "Your name, as the author of its authored passages.")
        var author: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.rootWorkspace()
                let id = try WorksGroup.workID(global)
                guard season != nil || narrative != nil || !text.isEmpty || title != nil || author != nil else {
                    throw LeviathanFailure("give --season, --narrative or --text", code: LeviathanFailure.ExitCode.usage)
                }
                _ = try WorkImport.ensure(id, title: title, author: author, in: workspace)
                func read(_ path: String) throws -> (Data, String) {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    guard let data = FileManager.default.contents(atPath: url.path) else {
                        throw LeviathanFailure("cannot read \(path)", code: LeviathanFailure.ExitCode.noInput)
                    }
                    return (data, url.lastPathComponent)
                }
                var lines: [String] = []
                if let narrative {
                    let (data, name) = try read(narrative)
                    let found = try WorkImport.narrative(data, name: name, work: id, in: workspace)
                    lines.append("narrative \(name): \(found.characters?.count ?? 0) characters, \(found.toolDirectives?.count ?? 0) mark directives")
                }
                var last: ImportSummary?
                if let season {
                    let (data, name) = try read(season)
                    last = try WorkImport.season(data, name: name, work: id, in: workspace)
                    lines.append("season \(name): \(last!.added) passages added, \(last!.alreadyPresent) already here")
                }
                for path in text {
                    let (data, name) = try read(path)
                    last = try WorkImport.text(String(decoding: data, as: UTF8.self), name: name, work: id, in: workspace)
                    lines.append("text \(name): \(last!.added) passages added, \(last!.alreadyPresent) already here")
                }
                let passages = try WorkStore.passages(id, in: workspace)
                lines.append("\(id): \(passages.count) passages, \(passages.filter { $0.origin == .authored }.count) authored by you, "
                    + "\(passages.filter { $0.origin == .generated }.count) generated by the story's model; kept in works/\(id)/, which git ignores")
                try global.emit(last ?? ImportSummary(work: id, added: 0, alreadyPresent: 0,
                                                      authored: passages.filter { $0.origin == .authored }.count,
                                                      generated: passages.filter { $0.origin == .generated }.count, total: passages.count),
                                lines.joined(separator: "\n"))
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a work's passages, its terms per origin, and its studies.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await global.guarded {
                let workspace = try global.rootWorkspace()
                let id = try WorksGroup.workID(global)
                let work = try WorkStore.load(id, in: workspace)
                let passages = try WorkStore.passages(id, in: workspace)
                var text = "\(work.title) (\(work.id))" + (work.author.map { " by \($0)" } ?? "") + "\n"
                for origin in PassageOrigin.allCases {
                    let terms = work.terms(for: origin.rawValue)
                    text += "  \(origin.rawValue): \(terms.trainingUse.rawValue)" + (terms.writer.map { ", written by \($0)" } ?? "") + "\n"
                }
                text += "\n" + Output.table(["#", "origin", "mark", "words", "begins"], passages.map { passage in
                    [String(passage.index), passage.origin.rawValue, passage.kind ?? passage.tool ?? "–", String(passage.words),
                     Output.clip(passage.text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ") + "…", 40)]
                })
                let threads = WorkReport.threads(work: id, in: workspace)
                if !threads.isEmpty {
                    text += "\n\nstudies with samples:\n" + threads.map { "  \($0.set) on \($0.ref): \($0.samples) samples" }.joined(separator: "\n")
                }
                try global.emit(passages.map { ["index": String($0.index), "id": $0.id, "origin": $0.origin.rawValue, "words": String($0.words)] }, text)
            }
        }
    }

    struct MakeStudy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "study", abstract: "Make a prompt set from a work's passages: continue, revise or recall.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "continue, revise or recall.")
        var kind: StudyKind

        @Option(help: "The first passage, by its number in `works show`.")
        var from = 0

        @Option(help: "How many passages.")
        var limit = 12

        @Option(help: "Only passages of this origin: authored or generated.")
        var origin: PassageOrigin?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.rootWorkspace()
                let id = try WorksGroup.workID(global)
                let summary = try Study.make(kind, work: id, from: from, limit: limit, origin: origin, in: workspace)
                try global.emit(summary, "wrote \(summary.prompts.count) prompts to works/\(id)/prompts/\(summary.set)/"
                    + (summary.skipped.isEmpty ? "" : "; skipped \(summary.skipped.joined(separator: ", ")) (too short to split)")
                    + "\n  \(kind.summary)\n  next: leviathan harvest --work \(id) --set \(summary.set) --model <company/model> --dry-run")
            }
        }
    }

    struct Origin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the terms for one origin of a work's text: who wrote it, and whether a Thread built on it may train RaoLM.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "authored or generated.")
        var origin: PassageOrigin

        @Option(help: "permitted, prohibited or unknown.")
        var trainingUse: TrainingUse

        @Option(help: "Who wrote it: you, or the model and host that generated it.")
        var writer: String?

        @Option(help: "A note on the terms, such as where you read them.")
        var note: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.rootWorkspace()
                let id = try WorksGroup.workID(global)
                var work = try WorkStore.load(id, in: workspace)
                var terms = work.terms(for: origin.rawValue)
                terms.trainingUse = trainingUse
                if let writer { terms.writer = writer }
                if let note { terms.note = note }
                work.origins[origin.rawValue] = terms
                try WorkStore.save(work, in: workspace)
                try global.emit(terms, "\(id): \(origin.rawValue) text is \(trainingUse.rawValue)" + (terms.writer.map { ", written by \($0)" } ?? ""))
            }
        }
    }

    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write what the models' answers show about a work to works/<id>/reports/<date>.md.")
        @OptionGroup var global: GlobalOptions

        @Flag(help: "Print the report too.")
        var print = false

        func run() async throws {
            try await global.guarded {
                let workspace = try global.rootWorkspace()
                let id = try WorksGroup.workID(global)
                let url = try WorkReport.write(work: id, in: workspace)
                let text = print ? (try String(contentsOf: url, encoding: .utf8)) : ""
                try global.emit(["report": workspace.relative(url)], "wrote \(workspace.relative(url))" + (print ? "\n\n" + text : ""))
            }
        }
    }
}
