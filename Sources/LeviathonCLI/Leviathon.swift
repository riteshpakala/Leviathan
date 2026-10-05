//
//  Leviathon.swift
//  LeviathonCLI
//
//  WHAT: The `leviathon` command: harvest how models answer and write Thread corpora for RaoLM.
//  PIN:  Made to be run by a person or an agent: no prompts, `--json` on every command, keys
//        never printed, and exit codes that say which kind of failure it was (sysexits, as in
//        LeviathonFailure.ExitCode). Progress goes to stderr, results to stdout.
//

import ArgumentParser
import Foundation
import LeviathonCore

@main
struct Leviathon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leviathon",
        abstract: "Harvest how models answer across temperatures, and write Thread corpora RaoLM can train on.",
        discussion: """
            A typical run:
              leviathon providers add --preset ollama
              leviathon models add --provider ollama --company qwen --model qwen2.5:7b --training-use permitted
              leviathon prompts add --set writing --id lighthouse --text "Tell me about the Hollow Lighthouse."
              leviathon harvest --set writing --model qwen/qwen2.5-7b
              leviathon derive  --set writing --model qwen/qwen2.5-7b
              leviathon export  --set writing --model qwen/qwen2.5-7b
              leviathon measure --set writing --model qwen/qwen2.5-7b
            Exit codes: 64 usage, 65 malformed file, 66 missing input, 69 host unavailable, 70 internal, 73 cannot write,
            75 retries ran out, 77 terms do not permit, 78 configuration.
            """,
        subcommands: [
            StatusCommand.self, ProvidersGroup.self, ModelsGroup.self, PromptsGroup.self, HarvestCommand.self, DeriveCommand.self,
            PassageCommand.self, EditCommand.self, ExportCommand.self, MeasureCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "The Leviathon package root (default: $LEVIATHON_ROOT, else found from the working directory).")
    var root: String?

    @Flag(help: "Print the result as JSON on stdout.")
    var json = false

    func workspace() throws -> Workspace {
        try Workspace.resolve(explicit: root).workspace
    }

    /// Runs a command body, turning every failure into a message and its exit code.
    func guarded(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let failure as LeviathonFailure {
            report(failure)
            throw ExitCode(failure.code)
        } catch let error as ChatError {
            let failure = LeviathonFailure(error.description, code: LeviathonFailure.ExitCode.unavailable)
            report(failure)
            throw ExitCode(failure.code)
        } catch let error as ExitCode {
            throw error
        } catch is CancellationError {
            throw ExitCode(130)
        } catch {
            let failure = LeviathonFailure("\(error)", code: LeviathonFailure.ExitCode.software)
            report(failure)
            throw ExitCode(failure.code)
        }
    }

    func report(_ failure: LeviathonFailure) {
        if json, let text = try? JSONCoding.pretty(["error": failure]) {
            print(text)
        }
        Output.error("leviathon: \(failure.message)" + (failure.hint.map { "\n  hint: \($0)" } ?? ""))
    }

    /// Prints a result: as JSON with --json, else as the text given.
    func emit<T: Encodable>(_ value: T, _ text: @autoclosure () -> String) throws {
        if json {
            print(try JSONCoding.pretty(value))
        } else {
            let rendered = text()
            if !rendered.isEmpty { print(rendered) }
        }
    }
}

struct ThreadOptions: ParsableArguments {
    @Option(help: "The prompt set.")
    var set: String

    @Option(help: "The model, as company/model (its folder under dataset/).")
    var model: String

    func ref() throws -> ModelRef { try ModelRef(parsing: model) }
}

enum Output {
    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func progress(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func table(_ headers: [String], _ rows: [[String]]) -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                i == cells.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return ([line(headers), line(widths.map { String(repeating: "─", count: $0) })] + rows.map(line)).joined(separator: "\n")
    }

    static func number(_ value: Double?, _ digits: Int = 2) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? "–"
    }

    static func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.2g", $0) } ?? "default"
    }

    static func clip(_ text: String, _ limit: Int = 80) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
