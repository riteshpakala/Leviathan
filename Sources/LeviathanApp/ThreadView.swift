//
//  ThreadView.swift
//  LeviathanApp
//
//  WHAT: One Thread: a model on a prompt set. Harvest it, then read and edit its passages, then
//        export it for RaoLM or measure it for the catalogue.
//

import LeviathanCore
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var app
    let ref: ModelRef
    let set: String
    /// The work this Thread belongs to, if any.
    var work: String? = nil

    enum Tab: String, CaseIterable { case harvest = "Harvest", passages = "Passages" }
    @State private var tab = Tab.passages

    var target: ModelTarget? { app.models.first { $0.ref == ref } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Text("\(app.sampleCount(ref, set, work: work)) samples").foregroundStyle(.secondary)
                if let target {
                    Text("terms: \(target.terms.trainingUse.rawValue)")
                        .foregroundStyle(target.terms.trainingUse == .permitted ? Color.secondary : Color.orange)
                }
                Spacer()
                Button("Derive") { derive() }
                    .help("Write every prompt's passage to threads/\(set)/passages/")
                Button("Export for RaoLM") { export() }
                    .help("Write the Thread as a RaoLM corpus (permitted models only)")
                Button("Measure") { measure() }
                    .help(work == nil ? "Write this Thread's evidence to catalogue/evidence/" : "Write this Thread's evidence inside the work")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .harvest: HarvestPanel(ref: ref, set: set, work: work)
            case .passages: PassagePanel(ref: ref, set: set, work: work)
            }
        }
        .navigationTitle("\(work.map { "\($0) · " } ?? "")\(ref.description) · \(set)")
        .onAppear { if app.sampleCount(ref, set, work: work) == 0 { tab = .harvest } }
    }

    func derive() {
        app.perform(in: work) { workspace in
            let summary = try PassageStore.derive(try ThreadSource.load(workspace, ref: ref, set: set))
            return "Derived \(summary.passages.count) passage\(summary.passages.count == 1 ? "" : "s")"
                + (summary.unharvested.isEmpty ? "." : "; not harvested: \(summary.unharvested.joined(separator: ", ")).")
        }
    }

    func export() {
        app.perform(in: work) { workspace in
            let summary = try ThreadExporter.export(try ThreadSource.load(workspace, ref: ref, set: set))
            return "Exported \(summary.documents) documents to \(summary.directory): \(summary.expectations) expectations, "
                + "\(summary.candidates) candidates, sampling weight \(Format.share(summary.samplingWeight))."
                + (summary.skipped.isEmpty ? "" : " Skipped " + summary.skipped.map { "\($0.promptID) (\($0.reason))" }.joined(separator: ", ") + ".")
        }
    }

    func measure() {
        app.perform(in: work) { workspace in
            let evidence = try Measurements.measure(try ThreadSource.load(workspace, ref: ref, set: set))
            let url = try Measurements.write(evidence, workspace: workspace)
            return "Wrote \(workspace.relative(url))."
        }
    }
}

// MARK: Harvest

struct HarvestPanel: View {
    @Environment(AppModel.self) private var app
    let ref: ModelRef
    let set: String
    var work: String? = nil

    @State private var temperatures = SamplingPlan.defaultTemperatures.map { String($0) }.joined(separator: ", ")
    @State private var samples = 3
    @State private var maxTokens = ""
    @State private var excluded = Set<String>()
    /// Sample points already in the transcript, read once and again after each harvest.
    @State private var existing = Set<SampleKey>()
    /// This model's answers so far, for the typical cost.
    @State private var history: [TranscriptRecord] = []
    @State private var maxCost = 25.0

    var promptSet: PromptSet? { app.promptSet(set, work: work) }
    var provider: Provider? { target.flatMap { target in app.providers.first { $0.id == target.providerID } } }

    /// Why this host may not receive the work's text, when it may not.
    var blocked: String? {
        guard let work, let provider, let workspace = app.workspace(for: work) else { return nil }
        do {
            try PrivateText.check(provider, work: try WorkStore.load(work, in: workspace))
            return nil
        } catch {
            return (error as? LeviathanFailure)?.message ?? "\(error)"
        }
    }
    var target: ModelTarget? { app.models.first { $0.ref == ref } }

    var sampling: SamplingPlan? {
        let values = temperatures.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }), samples > 0 else { return nil }
        return SamplingPlan(temperatures: values.compactMap { $0 }, samplesPerTemperature: samples, maxTokens: Int(maxTokens))
    }

    var plan: HarvestPlan? {
        guard let target, let promptSet, let sampling else { return nil }
        return HarvestPlan.make(target: target, prompts: promptSet.prompts.filter { !excluded.contains($0.id) }, plan: sampling, existing: existing)
    }

    func readExisting() {
        guard let workspace = app.workspace(for: work) else { return }
        let records = (try? TranscriptStore.read(workspace.transcriptsFile(ref)))?.records ?? []
        existing = Set(records.map(\.key))
        history = records
    }

    var body: some View {
        let run = app.harvest(ref, set, work: work)
        HSplitView {
            Form {
                Section("Plan") {
                    TextField("Temperatures", text: $temperatures)
                    Stepper("Samples per temperature: \(samples)", value: $samples, in: 1...20)
                    TextField("Max tokens", text: $maxTokens, prompt: Text("the model's: \(target?.sampling.maxTokens ?? 0)"))
                    if let plan {
                        Text("\(plan.pending.count) requests to send, \(plan.skipped) already in the transcript")
                            .font(.headline)
                        if let target, let sampling, !plan.pending.isEmpty {
                            let cost = CostEstimate.make(plan: plan, target: target, sampling: sampling, history: history)
                            Text("Cost: \(cost.summary)").foregroundStyle(cost.worst.map { $0 > maxCost } ?? false ? Color.orange : Color.primary)
                        }
                        if plan.defaultOnly { Text("Default-only model: every sample at the host's default.").font(.caption) }
                        if !plan.dropped.isEmpty {
                            Text("Dropped, outside the model's range: " + plan.dropped.map { Format.temperature($0) }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("Temperatures are numbers separated by commas.").foregroundStyle(.orange)
                    }
                }
                Section("Prompts") {
                    ForEach(promptSet?.prompts ?? []) { prompt in
                        Toggle(isOn: Binding(get: { !excluded.contains(prompt.id) },
                                             set: { if $0 { excluded.remove(prompt.id) } else { excluded.insert(prompt.id) } })) {
                            VStack(alignment: .leading) {
                                Text(prompt.id)
                                Text(prompt.text).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    TextField("Stop at (dollars)", value: $maxCost, format: .number)
                    if let blocked {
                        Label(blocked, systemImage: "lock.fill").foregroundStyle(.orange)
                        Text("Clear the host on its page, after reading its data terms, to send it this work's text.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Run Harvest") { start(run) }
                            .disabled(run.running || (plan?.pending.isEmpty ?? true) || blocked != nil || overBudget)
                        Button("Cancel") { run.cancel() }.disabled(!run.running)
                    }
                    Text("Requests to hosted models cost money. The count and cost above are what will be sent; the run stops if the spend the host reports reaches the limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 340, idealWidth: 380)

            VStack(alignment: .leading, spacing: 8) {
                if run.total > 0 {
                    ProgressView(value: Double(run.done), total: Double(max(run.total, 1))) {
                        Text("\(run.done) of \(run.total)" + (run.failed > 0 ? ", \(run.failed) failed" : ""))
                    }
                }
                if let summary = run.summary {
                    Text("Harvested \(summary.completed) of \(summary.requested) sent; \(summary.promptTokens) prompt and \(summary.completionTokens) completion tokens.")
                }
                if let problem = run.problem {
                    Text(problem).foregroundStyle(.orange).textSelection(.enabled)
                }
                List(Array(run.log.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .padding()
            .frame(minWidth: 360)
        }
        .onAppear(perform: readExisting)
    }

    var overBudget: Bool {
        guard let plan, let target, let sampling else { return false }
        return CostEstimate.make(plan: plan, target: target, sampling: sampling, history: history).worst.map { $0 > maxCost } ?? false
    }

    func start(_ run: HarvestRun) {
        guard let workspace = app.workspace(for: work), let target, let promptSet, let sampling,
              let provider = app.providers.first(where: { $0.id == target.providerID }) else {
            app.show("The model's provider \(target?.providerID ?? "") is not in providers.json.", error: true)
            return
        }
        run.start(workspace: workspace, target: target, provider: provider, set: promptSet,
                  prompts: promptSet.prompts.filter { !excluded.contains($0.id) }, sampling: sampling, maxSpend: target.pricing == nil ? nil : maxCost) {
            app.reload()
            readExisting()
        }
    }
}
