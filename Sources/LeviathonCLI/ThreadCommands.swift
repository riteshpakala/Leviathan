//
//  ThreadCommands.swift
//  LeviathonCLI
//
//  WHAT: leviathon derive | passage | edit | export | measure — everything made from one
//        model's samples on one prompt set.
//  PIN:  `edit` starts from the prompt's latest resolution and appends a new one; areas are
//        named by their number in `passage`. `export` refuses a model whose terms are not
//        `permitted`; `measure` runs on any model.
//

import ArgumentParser
import Foundation
import LeviathonCore

struct DeriveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "derive", abstract: "Build every prompt's passage: locked text, areas, variants and expectations.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var thread: ThreadOptions

    func run() async throws {
        try await global.guarded {
            let source = try ThreadSource.load(try global.workspace(), ref: try thread.ref(), set: thread.set)
            let summary = try PassageStore.derive(source)
            var text = Output.table(["prompt", "samples", "aligned", "alternates", "set aside", "areas", "expectations", "locked"],
                                    summary.passages.map {
                                        [$0.promptID, String($0.samples), String($0.aligned), String($0.divergent), String($0.setAside),
                                         String($0.areas), String($0.expectations), Output.number($0.lockedShare)]
                                    })
            if !summary.unharvested.isEmpty { text += "\nnot harvested: \(summary.unharvested.joined(separator: ", "))" }
            if !summary.unreadableLines.isEmpty { text += "\nwarning: transcript lines \(summary.unreadableLines) do not decode" }
            try global.emit(summary, text)
        }
    }
}

struct PassageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "passage", abstract: "Show one prompt's passage: the baseline with its areas numbered, their variants, and expectations.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var thread: ThreadOptions

    @Option(help: "The prompt.")
    var prompt: String

    @Option(help: "Expectations to list, most confident first.")
    var expectations = 15

    func run() async throws {
        try await global.guarded {
            let source = try ThreadSource.load(try global.workspace(), ref: try thread.ref(), set: thread.set)
            let prompt = try source.set.prompt(self.prompt)
            guard let passage = try source.passage(for: prompt) else {
                throw LeviathonFailure("\(prompt.id) has no samples", hint: "leviathon harvest --set \(thread.set) --model \(thread.model) --prompt \(prompt.id)",
                                       code: LeviathonFailure.ExitCode.noInput)
            }
            try global.emit(passage, render(passage, resolution: source.resolution(for: prompt)))
        }
    }

    func render(_ passage: Passage, resolution: Resolution?) -> String {
        var lines: [String] = []
        let m = passage.measures
        lines.append("\(passage.promptID) — \(m.samples) samples: \(m.aligned) aligned, \(m.divergent) alternates, \(m.setAside) set aside; "
            + "\(Output.number(m.lockedShare * 100, 0))% of words locked; baseline T=\(Output.temperature(passage.baselineTemperature))"
            + (resolution.map { " (pinned by edit \($0.id.prefix(8)))" } ?? ""))
        lines.append("")
        lines.append(passage.segments.map { segment in
            segment.kind == .locked ? segment.text : "⟦\(segment.area ?? 0):\(segment.text)⟧"
        }.joined())
        if !passage.areas.isEmpty {
            lines.append("")
            lines.append("areas:")
            for area in passage.areas {
                lines.append("  [\(area.id)] onset \(area.onsetKey ?? "–") · entropy \(Output.number(area.entropy)) bits"
                    + (area.holdsContent ? "" : " · form only") + (area.tokens.isEmpty ? " · insertion" : ""))
                for (index, variant) in area.variants.enumerated() {
                    let temperatures = Set(variant.samples.map { Output.temperature($0.temperature) }).sorted().joined(separator: " ")
                    lines.append("      \(index)\(variant.isBaseline ? "*" : " ") \(Output.number(variant.share)) “\(Output.clip(variant.text, 60))”  T \(temperatures)")
                }
            }
        }
        let ranked = passage.expectations.filter { $0.support > 0 }.sorted {
            ($0.confidence ?? 0, $0.support) > ($1.confidence ?? 0, $1.support)
        }
        if !ranked.isEmpty {
            lines.append("")
            lines.append("expectations (\(passage.expectations.count), confidence · support):")
            for expectation in ranked.prefix(expectations) {
                lines.append("  \(Output.number(expectation.confidence)) · \(expectation.support)  "
                    + "\(Output.clip(expectation.stemText, 60)) ▸\(expectation.answerText)"
                    + (expectation.onsetTemperature.map { "  breaks at T=\(Output.temperature($0))" } ?? ""))
            }
        }
        let alternates = passage.samples.filter { $0.status == .divergent || $0.status == .setAside }
        if !alternates.isEmpty {
            lines.append("")
            lines.append("not aligned: " + alternates.map {
                "T=\(Output.temperature($0.temperature)) #\($0.sampleIndex) \($0.status == .divergent ? "alternate (overlap \(Output.number($0.overlap)))" : $0.reason ?? "set aside")"
            }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

struct EditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit", abstract: "Choose variants or write your own words for a prompt's areas, saving a new resolution.",
        discussion: "Areas are numbered as `leviathon passage` shows them. Choices carry over from the prompt's latest edit.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var thread: ThreadOptions

    @Option(help: "The prompt.")
    var prompt: String

    @Option(help: "Choose a variant, as AREA=VARIANT (repeatable).")
    var choose: [String] = []

    @Option(help: "Write your own words for an area, as AREA=TEXT (repeatable).")
    var write: [String] = []

    @Option(help: "Return an area to the baseline's wording (repeatable).")
    var clear: [Int] = []

    @Flag(help: "Drop every earlier choice first.")
    var reset = false

    @Option(help: "Build on this record instead (its id), dropping earlier choices.")
    var baseline: String?

    @Option(help: "A note kept with the edit.")
    var note: String?

    func run() async throws {
        try await global.guarded {
            let workspace = try global.workspace()
            let source = try ThreadSource.load(workspace, ref: try thread.ref(), set: thread.set)
            let prompt = try source.set.prompt(self.prompt)
            guard let passage = try source.passage(for: prompt, baseline: baseline) else {
                throw LeviathonFailure("\(prompt.id) has no samples", code: LeviathonFailure.ExitCode.noInput)
            }
            if let baseline, passage.baselineRecordID != baseline {
                throw LeviathonFailure("no usable record \(baseline) for \(prompt.id)", code: LeviathonFailure.ExitCode.noInput)
            }
            var choices: [IndexRange: Choice] = [:]
            if !reset, baseline == nil, let latest = source.resolution(for: prompt), latest.baselineRecordID == passage.baselineRecordID {
                for choice in latest.choices where passage.areas.contains(where: { $0.tokens == choice.tokens }) { choices[choice.tokens] = choice }
            }
            func area(_ id: Int) throws -> Area {
                guard let area = passage.area(id) else {
                    throw LeviathonFailure("no area \(id); this passage has \(passage.areas.count)", code: LeviathonFailure.ExitCode.usage)
                }
                return area
            }
            func split(_ entry: String, _ flag: String) throws -> (Int, String) {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let id = Int(parts[0]) else {
                    throw LeviathonFailure("--\(flag) takes AREA=…", code: LeviathonFailure.ExitCode.usage)
                }
                return (id, parts[1])
            }
            for id in clear { choices[try area(id).tokens] = nil }
            for entry in choose {
                let (id, value) = try split(entry, "choose")
                let chosen = try area(id)
                guard let index = Int(value), chosen.variants.indices.contains(index) else {
                    throw LeviathonFailure("area \(id) has variants 0–\(chosen.variants.count - 1)", code: LeviathonFailure.ExitCode.usage)
                }
                choices[chosen.tokens] = chosen.variants[index].isBaseline ? nil : Choice(tokens: chosen.tokens, variant: index)
            }
            for entry in write {
                let (id, value) = try split(entry, "write")
                let chosen = try area(id)
                choices[chosen.tokens] = Choice(tokens: chosen.tokens, text: value)
            }
            let resolution = try Resolver.resolve(passage, choices: Array(choices.values), note: note)
            try EditStore.append(resolution, workspace: workspace, ref: source.ref)
            try global.emit(resolution, "saved edit \(resolution.id.prefix(8)) for \(prompt.id): \(resolution.choices.count) choice"
                + "\(resolution.choices.count == 1 ? "" : "s")\(resolution.edited ? "" : " (the text is the baseline's)")\n\n\(resolution.text)")
        }
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Write the Thread as a RaoLM corpus, with its weights and expectations.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var thread: ThreadOptions

    @Option(help: "Also write confident expectations as RaoLM facts of this kind (RaoLM must know it).")
    var factKind: String?

    @Option(help: "Loss weight of form: whitespace, punctuation and function words.")
    var formWeight = 0.5

    @Option(help: "Confidence an expectation needs to be a candidate fact.")
    var minConfidence = 0.8

    @Option(help: "Supporting samples an expectation needs to be a candidate fact.")
    var minSupport = 3

    func run() async throws {
        try await global.guarded {
            let source = try ThreadSource.load(try global.workspace(), ref: try thread.ref(), set: thread.set)
            let summary = try ThreadExporter.export(source, options: ExportOptions(
                factKind: factKind, formWeight: formWeight, minConfidence: minConfidence, minSupport: minSupport))
            var lines = ["exported Thread \(summary.slug) to \(summary.directory)",
                         "  \(summary.documents) documents, \(summary.partitions) partitions, corpus hash \(summary.corpusHash.prefix(12))",
                         "  \(summary.expectations) expectations, \(summary.candidates) candidates, \(summary.facts) facts, sampling weight \(Output.number(summary.samplingWeight, 3))",
                         "  train: raolm train --corpus \(summary.directory)/snapshot.json"]
            lines += summary.skipped.map { "  skipped \($0.promptID): \($0.reason)" }
            lines += summary.staleEdits.map { "  \($0): its edit names areas that changed; the edit's own text was used" }
            lines += summary.warnings.map { "  warning: \($0)" }
            try global.emit(summary, lines.joined(separator: "\n"))
        }
    }
}

struct MeasureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure", abstract: "Write the Thread's evidence for the catalogue: by temperature, cut word and onset.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var thread: ThreadOptions

    func run() async throws {
        try await global.guarded {
            let workspace = try global.workspace()
            let source = try ThreadSource.load(workspace, ref: try thread.ref(), set: thread.set)
            let evidence = try Measurements.measure(source)
            let url = try Measurements.write(evidence, workspace: workspace)
            var lines = ["\(evidence.model) on \(evidence.set): \(evidence.harvested)/\(evidence.prompts) prompts, \(evidence.samples) samples, "
                + "terms \(evidence.trainingUse.rawValue)", ""]
            lines.append(Output.table(["T", "samples", "alternates", "overlap", "form kept", "content kept", "bits/form", "bits/content"],
                                      evidence.byTemperature.map {
                                          [Output.temperature($0.temperature), String($0.samples), String($0.divergent), Output.number($0.meanOverlap),
                                           Output.number($0.formKept), Output.number($0.contentKept), Output.number($0.bitsPerFormWord),
                                           Output.number($0.bitsPerContentWord)]
                                      }))
            if !evidence.cutWords.isEmpty {
                lines.append("")
                lines.append("expectation confidence by cut word: " + evidence.cutWords.prefix(12).map {
                    "\($0.word) \(Output.number($0.meanConfidence)) (\($0.expectations))"
                }.joined(separator: " · "))
            }
            lines.append("onsets (areas/broken expectations): " + evidence.onsets.map { "\($0.temperature) \($0.areas)/\($0.expectations)" }
                .joined(separator: " · "))
            lines.append("")
            lines.append("wrote \(workspace.relative(url))")
            try global.emit(evidence, lines.joined(separator: "\n"))
        }
    }
}
