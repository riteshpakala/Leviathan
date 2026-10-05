//
//  AppModel.swift
//  LeviathonApp
//
//  WHAT: What the app shows and changes: the workspace, its providers, models and prompt sets,
//        the selection, and a banner for the last outcome.
//  PIN:  Every change goes through LeviathonCore and is followed by a reload from disk, so the
//        app never holds state the CLI would not see.
//

import AppKit
import Foundation
import LeviathonCore
import Observation

enum SidebarItem: Hashable {
    case model(ModelRef)
    case thread(ModelRef, String)
    case promptSet(String)
    case provider(String)
    case newModel, newPromptSet, newProvider
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

@MainActor
@Observable
final class AppModel {
    static let rootKey = "workspaceRoot"

    var workspace: Workspace?
    var rootProblem: String?
    var providers: [Provider] = []
    var models: [ModelTarget] = []
    var sets: [PromptSet] = []
    /// Samples per model and set, keyed "<company>/<model>|<set>".
    var samples: [String: Int] = [:]
    var selection: SidebarItem?
    var banner: Banner?
    /// Harvests keep running when you look elsewhere.
    var harvests: [String: HarvestRun] = [:]

    init() {
        locate()
        reload()
    }

    func locate() {
        let saved = UserDefaults.standard.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0) }
        do {
            workspace = try Workspace.resolve(saved: saved).workspace
            rootProblem = nil
        } catch {
            workspace = nil
            rootProblem = Self.describe(error)
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Workspace"
        panel.message = "Choose the Leviathon package folder (the one holding Package.swift)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Workspace.isLeviathonRoot(url) else {
            show("\(url.path) has no Leviathon Package.swift", error: true)
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        workspace = Workspace(root: url)
        rootProblem = nil
        selection = nil
        reload()
    }

    func reload() {
        guard let workspace else { return }
        do {
            providers = try ProviderStore.load(workspace)
        } catch {
            providers = []
            show(Self.describe(error), error: true)
        }
        models = ModelStore.all(in: workspace)
        sets = PromptStore.all(in: workspace)
        var counts: [String: Int] = [:]
        for target in models {
            let records = (try? TranscriptStore.read(workspace.transcriptsFile(target.ref)).records) ?? []
            for record in records { counts["\(target.ref)|\(record.pack)", default: 0] += 1 }
        }
        samples = counts
    }

    func sampleCount(_ ref: ModelRef, _ set: String) -> Int { samples["\(ref)|\(set)"] ?? 0 }

    func harvest(_ ref: ModelRef, _ set: String) -> HarvestRun {
        let key = "\(ref)|\(set)"
        if let run = harvests[key] { return run }
        let run = HarvestRun()
        harvests[key] = run
        return run
    }

    /// Runs a change, reloads, and shows its outcome.
    func perform(_ body: (Workspace) throws -> String?) {
        guard let workspace else { return }
        do {
            if let message = try body(workspace) { show(message, error: false) }
        } catch {
            show(Self.describe(error), error: true)
        }
        reload()
    }

    func show(_ text: String, error: Bool) {
        banner = Banner(text: text, isError: error)
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? LeviathonFailure { return failure.description }
        if let error = error as? ChatError { return error.description }
        return "\(error)"
    }
}

/// One harvest in progress or finished, for one model and prompt set.
@MainActor
@Observable
final class HarvestRun {
    var running = false
    var total = 0
    var done = 0
    var failed = 0
    var log: [String] = []
    var summary: HarvestSummary?
    var problem: String?
    private var task: Task<Void, Never>?

    func start(workspace: Workspace, target: ModelTarget, provider: Provider, set: PromptSet, prompts: [Prompt], sampling: SamplingPlan,
               onFinish: @escaping @MainActor () -> Void) {
        guard !running else { return }
        let store = TranscriptStore(url: workspace.transcriptsFile(target.ref))
        let existing = Set(((try? store.read())?.records ?? []).map(\.key))
        let plan = HarvestPlan.make(target: target, prompts: prompts, plan: sampling, existing: existing)
        let (key, _) = APIKeyResolver.resolve(provider, store: KeychainSecretStore())
        if provider.apiKeyEnv != nil, key == nil {
            problem = "No API key for \(provider.id): set $\(provider.apiKeyEnv ?? "") or save one on the provider's page."
            return
        }
        total = plan.pending.count
        done = 0
        failed = 0
        log = []
        summary = nil
        problem = nil
        running = true
        let harvester = Harvester(target: target, provider: provider, set: set, client: OpenAICompatibleClient(provider: provider, apiKey: key),
                                  store: store)
        // The run lives in AppModel.harvests for the whole session, so holding it strongly here is safe.
        let sink: @Sendable (HarvestEvent) -> Void = { [self] event in
            Task { @MainActor in self.apply(event) }
        }
        task = Task {
            do {
                let summary = try await harvester.run(plan, sampling: sampling, runID: Harvester.newRunID(), onEvent: sink)
                self.summary = summary
                done = summary.completed + summary.failed
                if let stop = summary.stop { problem = stop.message + (stop.hint.map { "\n\($0)" } ?? "") }
            } catch is CancellationError {
                problem = "Cancelled. What completed is kept; run again to fill the gaps."
            } catch {
                problem = AppModel.describe(error)
            }
            running = false
            onFinish()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func apply(_ event: HarvestEvent) {
        done += 1
        switch event {
        case .completed(let prompt, let temperature, let index, let tokens):
            log.append("\(prompt) · T \(Format.temperature(temperature)) · #\(index) · \(tokens.map { "\($0) tokens" } ?? "ok")")
        case .failed(let prompt, let temperature, let index, let message):
            failed += 1
            log.append("\(prompt) · T \(Format.temperature(temperature)) · #\(index) · failed: \(message)")
        }
    }
}

enum Format {
    static func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.2g", $0) } ?? "default"
    }

    static func share(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "–"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
