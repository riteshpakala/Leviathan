//
//  StatusCommand.swift
//  LeviathonCLI
//
//  WHAT: leviathon status — the root, the providers, the prompt sets, and for every model what
//        its transcript holds and which Threads have been derived and exported.
//

import ArgumentParser
import Foundation
import LeviathonCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show what the workspace holds.")

    @OptionGroup var global: GlobalOptions

    struct ThreadRow: Codable {
        var set: String
        var prompts: Int
        var harvested: Int
        var samples: Int
        var edits: Int
        var exported: Bool
    }

    struct ModelRow: Codable {
        var model: String
        var provider: String
        var requestModel: String
        var temperature: String
        var trainingUse: TrainingUse
        var samples: Int
        var unreadableLines: Int
        var threads: [ThreadRow]
    }

    struct Report: Codable {
        var root: String
        var rootSource: Workspace.Source
        var providers: [Provider]
        var promptSets: [String: Int]
        var models: [ModelRow]
        var evidenceFiles: Int
    }

    func run() async throws {
        try await global.guarded {
            let (workspace, source) = try Workspace.resolve(explicit: global.root)
            let sets = PromptStore.all(in: workspace)
            var models: [ModelRow] = []
            for target in ModelStore.all(in: workspace) {
                let contents = try TranscriptStore.read(workspace.transcriptsFile(target.ref))
                let threads = sets.compactMap { set -> ThreadRow? in
                    let records = contents.records.filter { $0.pack == set.id }
                    guard !records.isEmpty else { return nil }
                    let hashes = Set(records.map(\.task.promptSHA))
                    let edits = (try? EditStore.all(workspace, ref: target.ref, set: set.id).count) ?? 0
                    let exported = FileManager.default.fileExists(
                        atPath: workspace.exportDirectory(target.ref, set: set.id).appendingPathComponent("manifest.json").path)
                    return ThreadRow(set: set.id, prompts: set.prompts.count, harvested: set.prompts.filter { hashes.contains($0.sha) }.count,
                                     samples: records.count, edits: edits, exported: exported)
                }
                let limits = target.sampling
                models.append(ModelRow(
                    model: target.ref.description, provider: target.providerID, requestModel: target.requestModel,
                    temperature: limits.temperature == .defaultOnly ? "default only"
                        : "\(Output.temperature(limits.minTemperature))–\(Output.temperature(limits.maxTemperature))",
                    trainingUse: target.terms.trainingUse, samples: contents.records.count, unreadableLines: contents.unreadable.count,
                    threads: threads))
            }
            let evidence = FileManager.default.enumerator(atPath: workspace.catalogueDirectory.appendingPathComponent("evidence").path)?
                .compactMap { $0 as? String }.filter { $0.hasSuffix(".json") }.count ?? 0
            let report = Report(root: workspace.root.path, rootSource: source, providers: try ProviderStore.load(workspace),
                                promptSets: Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0.prompts.count) }), models: models,
                                evidenceFiles: evidence)
            try global.emit(report, text(report))
        }
    }

    func text(_ report: Report) -> String {
        var lines = ["root \(report.root) (\(report.rootSource.rawValue))", ""]
        lines.append(report.providers.isEmpty ? "providers: none (leviathon providers add --preset ollama)"
            : "providers:\n" + Output.table(["id", "base URL", "key"], report.providers.map {
                [$0.id, $0.baseURL, $0.apiKeyEnv.map { "$\($0)" } ?? "none"]
            }))
        lines.append("")
        lines.append(report.promptSets.isEmpty ? "prompt sets: none (leviathon prompts add …)"
            : "prompt sets: " + report.promptSets.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
        lines.append("")
        if report.models.isEmpty {
            lines.append("models: none (leviathon models add …)")
        } else {
            lines.append("models:")
            lines.append(Output.table(["model", "provider", "temperature", "terms", "samples"], report.models.map {
                [$0.model, $0.provider, $0.temperature, $0.trainingUse.rawValue, String($0.samples) + ($0.unreadableLines > 0 ? " (\($0.unreadableLines) unreadable)" : "")]
            }))
            let threads = report.models.flatMap { model in model.threads.map { (model.model, $0) } }
            if !threads.isEmpty {
                lines.append("")
                lines.append("threads:")
                lines.append(Output.table(["model", "set", "harvested", "samples", "edits", "exported"], threads.map { model, thread in
                    [model, thread.set, "\(thread.harvested)/\(thread.prompts)", String(thread.samples), String(thread.edits), thread.exported ? "yes" : "no"]
                }))
            }
        }
        lines.append("")
        lines.append("catalogue: \(report.evidenceFiles) evidence file\(report.evidenceFiles == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }
}
