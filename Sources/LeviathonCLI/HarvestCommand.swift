//
//  HarvestCommand.swift
//  LeviathonCLI
//
//  WHAT: leviathon harvest — sample a prompt set on one model across the temperature plan.
//  PIN:  States its request count before sending anything, and refuses a plan larger than
//        --max-requests: requests to hosted models cost money. --dry-run stops after the count.
//        Sample points already in the transcript are skipped, so running again fills gaps.
//

import ArgumentParser
import Foundation
import LeviathonCore

struct HarvestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harvest", abstract: "Sample a prompt set on one model across temperatures, appending to its transcript.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var thread: ThreadOptions

    @Option(help: "Only these prompts (repeatable).")
    var prompt: [String] = []

    @Option(help: "Temperatures, comma-separated.")
    var temps: String = SamplingPlan.defaultTemperatures.map { String($0) }.joined(separator: ",")

    @Option(help: "Samples per temperature.")
    var samples = 3

    @Option(help: "Max tokens per response (default: the model's).")
    var maxTokens: Int?

    @Option(help: "top_p to send with every request.")
    var topP: Double?

    @Option(help: "A seed to send with every request.")
    var seed: Int?

    @Option(help: "Refuse a plan with more requests than this.")
    var maxRequests = 200

    @Flag(help: "Show the plan and send nothing.")
    var dryRun = false

    struct Plan: Codable {
        var model: String
        var set: String
        var pending: Int
        var skipped: Int
        var dropped: [Double]
        var defaultOnly: Bool
        var dryRun: Bool
    }

    func run() async throws {
        try await global.guarded {
            let workspace = try global.workspace()
            let ref = try thread.ref()
            let target = try ModelStore.load(ref, in: workspace)
            let provider = try ProviderStore.provider(target.providerID, in: workspace)
            let set = try PromptStore.load(thread.set, in: workspace)
            let prompts = try prompt.isEmpty ? set.prompts : prompt.map { try set.prompt($0) }
            guard !prompts.isEmpty else {
                throw LeviathonFailure("prompt set \(set.id) has no prompts", code: LeviathonFailure.ExitCode.noInput)
            }
            let temperatures = try temps.split(separator: ",").map { part -> Double in
                guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else {
                    throw LeviathonFailure("'\(part)' is not a temperature", code: LeviathonFailure.ExitCode.usage)
                }
                return value
            }
            guard samples > 0, !temperatures.isEmpty else {
                throw LeviathonFailure("the plan needs at least one temperature and one sample", code: LeviathonFailure.ExitCode.usage)
            }
            let sampling = SamplingPlan(temperatures: temperatures, samplesPerTemperature: samples, maxTokens: maxTokens, topP: topP, seed: seed)
            let store = TranscriptStore(url: workspace.transcriptsFile(ref))
            let contents = try store.read()
            let plan = HarvestPlan.make(target: target, prompts: prompts, plan: sampling, existing: Set(contents.records.map(\.key)))
            let description = Plan(model: ref.description, set: set.id, pending: plan.pending.count, skipped: plan.skipped, dropped: plan.dropped,
                                   defaultOnly: plan.defaultOnly, dryRun: dryRun)
            var lines = ["\(ref) on \(provider.id), set \(set.id): \(plan.pending.count) request\(plan.pending.count == 1 ? "" : "s") to send, "
                + "\(plan.skipped) already in the transcript"]
            if plan.defaultOnly { lines.append("  default-only model: every sample at the host's default temperature") }
            if !plan.dropped.isEmpty {
                lines.append("  dropped temperatures outside \(Output.temperature(target.sampling.minTemperature))–"
                    + "\(Output.temperature(target.sampling.maxTemperature)): \(plan.dropped.map { Output.temperature($0) }.joined(separator: ", "))")
            }
            if !contents.unreadable.isEmpty { lines.append("  warning: transcript lines \(contents.unreadable) do not decode") }
            if dryRun || plan.pending.isEmpty {
                try global.emit(description, lines.joined(separator: "\n"))
                return
            }
            guard plan.pending.count <= maxRequests else {
                throw LeviathonFailure("the plan sends \(plan.pending.count) requests, more than --max-requests \(maxRequests)",
                                       hint: "check the count with --dry-run, then raise --max-requests", code: LeviathonFailure.ExitCode.usage)
            }
            let (key, source) = APIKeyResolver.resolve(provider, store: KeychainSecretStore())
            if let variable = provider.apiKeyEnv, key == nil {
                throw LeviathonFailure("no API key for \(provider.id): $\(variable) is not set and none is saved",
                                       hint: "export \(variable)=… or: leviathon providers key \(provider.id) < keyfile",
                                       code: LeviathonFailure.ExitCode.config)
            }
            if !global.json { Output.progress(lines.joined(separator: "\n") + (key == nil ? "" : "\n  key from \(source.rawValue)")) }

            let client = OpenAICompatibleClient(provider: provider, apiKey: key)
            let harvester = Harvester(target: target, provider: provider, set: set, client: client, store: store)
            let total = plan.pending.count
            let counter = Counter()
            let summary = try await harvester.run(plan, sampling: sampling, runID: Harvester.newRunID()) { event in
                let done = counter.next()
                switch event {
                case .completed(let promptID, let temperature, let index, let tokens):
                    Output.progress("[\(done)/\(total)] \(promptID) T=\(Output.temperature(temperature)) #\(index) ok"
                        + (tokens.map { " (\($0) tokens)" } ?? ""))
                case .failed(let promptID, let temperature, let index, let message):
                    Output.progress("[\(done)/\(total)] \(promptID) T=\(Output.temperature(temperature)) #\(index) failed: \(Output.clip(message, 200))")
                }
            }
            try global.emit(summary, "harvested \(summary.completed) of \(summary.requested) sent (\(summary.failed) failed), "
                + "\(summary.promptTokens) prompt and \(summary.completionTokens) completion tokens, run \(summary.runID)"
                + (summary.stop.map { "\nstopped: \($0.message)" + ($0.hint.map { "\n  hint: \($0)" } ?? "") } ?? ""))
            if let stop = summary.stop { throw ExitCode(stop.code) }
        }
    }
}

/// Counts events from the harvester's callbacks.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
