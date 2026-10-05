//
//  PromptCommands.swift
//  LeviathonCLI
//
//  WHAT: leviathon prompts list | add — prompts/<set>/<id>.md, the set's system prompt and the
//        RaoLM document kind its Thread is written as.
//

import ArgumentParser
import Foundation
import LeviathonCore

struct PromptsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompts", abstract: "List and add prompts.", subcommands: [List.self, Add.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List prompt sets and their prompts.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "Only this set.")
        var set: String?

        struct Row: Codable {
            var set: String
            var documentKind: String
            var system: String?
            var prompts: [PromptRow]
        }

        struct PromptRow: Codable {
            var id: String
            var sha: String
            var text: String
        }

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                let sets = try set.map { [try PromptStore.load($0, in: workspace)] } ?? PromptStore.all(in: workspace)
                let rows = sets.map { set in
                    Row(set: set.id, documentKind: set.settings.documentKind, system: set.system,
                        prompts: set.prompts.map { PromptRow(id: $0.id, sha: $0.sha, text: $0.text) })
                }
                try global.emit(rows, rows.isEmpty ? "no prompt sets (leviathon prompts add --set <set> --id <id> --text …)" : rows.map { row in
                    "\(row.set) — \(row.prompts.count) prompt\(row.prompts.count == 1 ? "" : "s"), written as \(row.documentKind)"
                        + (row.system.map { "\n  system: \(Output.clip($0, 70))" } ?? "") + "\n"
                        + row.prompts.map { "  \($0.id.padding(toLength: 20, withPad: " ", startingAt: 0))  \(Output.clip($0.text, 70))" }
                        .joined(separator: "\n")
                }.joined(separator: "\n\n"))
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add or replace a prompt; optionally set the set's system prompt and kind.")
        @OptionGroup var global: GlobalOptions

        @Option(help: "The prompt set.")
        var set: String

        @Option(help: "The prompt's id (its file name).")
        var id: String?

        @Option(help: "The prompt's text.")
        var text: String?

        @Option(help: "Read the prompt's text from this file.")
        var file: String?

        @Option(help: "Set the set's system prompt (an empty string removes it).")
        var system: String?

        @Option(help: "The RaoLM document kind the set's Thread is written as (default transcript).")
        var kind: String?

        func run() async throws {
            try await global.guarded {
                let workspace = try global.workspace()
                var lines: [String] = []
                if let id {
                    let body: String
                    if let text {
                        body = text
                    } else if let file {
                        body = try String(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath), encoding: .utf8)
                    } else {
                        throw LeviathonFailure("give --text or --file", code: LeviathonFailure.ExitCode.usage)
                    }
                    let url = try PromptStore.add(set: set, id: id, text: body, in: workspace)
                    lines.append("saved \(workspace.relative(url))")
                }
                if let system {
                    try PromptStore.setSystem(set: set, text: system, in: workspace)
                    lines.append(system.isEmpty ? "removed \(set)'s system prompt" : "saved \(set)'s system prompt")
                }
                if let kind {
                    try PromptStore.saveSettings(PromptSetSettings(documentKind: kind), set: set, in: workspace)
                    lines.append("\(set) is written as \(kind)")
                }
                guard !lines.isEmpty else {
                    throw LeviathonFailure("nothing to do: give --id with --text or --file, --system or --kind", code: LeviathonFailure.ExitCode.usage)
                }
                let loaded = try PromptStore.load(set, in: workspace)
                try global.emit(["set": set, "prompts": String(loaded.prompts.count)], lines.joined(separator: "\n"))
            }
        }
    }
}
