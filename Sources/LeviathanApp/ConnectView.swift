//
//  ConnectView.swift
//  LeviathanApp
//
//  WHAT: Connect a host in three steps: pick it, give it a key (OpenRouter signs in through the
//        browser; any host takes a pasted key), then pick models from what it serves.
//  PIN:  A key goes straight to the Keychain and is never shown, logged or written to a file.
//        The check that follows costs nothing. Models are added with prices and sampling filled
//        from the host's list, and terms left as the preset starts them: marking a model
//        permitted stays a deliberate step on its page.
//

import AppKit
import LeviathanCore
import SwiftUI

@MainActor
@Observable
final class ConnectFlow: Identifiable {
    enum Step { case host, key, models }

    let id = UUID()
    var step: Step = .host
    var preset: ProviderPreset?
    var provider: Provider?
    var keySource: APIKeySource = .none
    var pasted = ""
    var waiting: String?
    var check: ProviderCheck?
    var problem: String?
    var search = ""
    var openWeightsOnly = false
    var chosen: Set<String> = []
    private var task: Task<Void, Never>?

    /// The provider to give a key to, when it is not named after its preset.
    let providerID: String?

    init(preset: String? = nil, providerID: String? = nil) {
        self.preset = preset.flatMap(ProviderPresets.preset)
        self.providerID = providerID
    }

    var catalogue: [CatalogueModel] { check?.models ?? [] }

    var shown: [CatalogueModel] {
        catalogue.filter { (!openWeightsOnly || $0.openWeights) && (search.isEmpty || $0.matches(search)) }
    }

    /// Adds the host from its preset (keeping one already set up) and moves on to its key.
    func choose(_ preset: ProviderPreset, app: AppModel) {
        self.preset = preset
        let id = providerID ?? preset.id
        let provider = app.providers.first { $0.id == id } ?? preset.provider(id: id)
        app.perform { workspace in
            try ProviderStore.upsert(provider, in: workspace)
            return nil
        }
        self.provider = provider
        problem = nil
        check = nil
        step = .key
        Task { await refreshKeySource() }
        if preset.apiKeyEnv == nil { runCheck() }
    }

    func refreshKeySource() async {
        guard let provider else { return }
        keySource = await Task.detached { APIKeyResolver.resolve(provider, store: KeychainSecretStore()).source }.value
    }

    func signIn() {
        guard let provider else { return }
        problem = nil
        waiting = "Waiting for you to approve Leviathan in the browser…"
        task = Task {
            do {
                let key = try await OpenRouterAuth(provider: provider).signIn { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                try await Task.detached { try KeychainSecretStore().write(key, account: provider.id) }.value
                waiting = nil
                await refreshKeySource()
                runCheck()
            } catch is CancellationError {
                waiting = nil
            } catch {
                waiting = nil
                problem = Self.describe(error)
            }
        }
    }

    func savePasted() {
        guard let provider else { return }
        let key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        pasted = ""
        problem = nil
        Task {
            do {
                try await Task.detached { try KeychainSecretStore().write(key, account: provider.id) }.value
                await refreshKeySource()
                runCheck()
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    func runCheck() {
        guard let provider else { return }
        problem = nil
        check = nil
        waiting = "Checking \(provider.name)…"
        task = Task {
            let (key, source) = await Task.detached { APIKeyResolver.resolve(provider, store: KeychainSecretStore()) }.value
            do {
                check = try await ProviderCheck.run(provider, key: key, source: source)
            } catch {
                problem = Self.describe(error) + (key == nil && provider.apiKeyEnv != nil ? " No key is saved for \(provider.name) yet." : "")
            }
            waiting = nil
        }
    }

    func cancel() {
        task?.cancel()
        waiting = nil
    }

    /// Creates a target for each chosen model not already set up; returns the first one's ref.
    func addChosen(app: AppModel) -> ModelRef? {
        guard let provider else { return nil }
        var first: ModelRef?
        app.perform { workspace in
            var added = 0
            for entry in catalogue where chosen.contains(entry.id) {
                let target = entry.target(on: provider)
                if first == nil { first = target.ref }
                guard app.models.first(where: { $0.ref == target.ref }) == nil else { continue }
                try ModelStore.save(target, in: workspace)
                added += 1
            }
            return added == 0 ? "Those models were already set up." : "Added \(added) model\(added == 1 ? "" : "s") from \(provider.name)."
        }
        return first
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ChatError { return error.plain }
        return AppModel.describe(error)
    }
}

struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var flow: ConnectFlow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch flow.step {
                case .host: HostStep(flow: flow)
                case .key: KeyStep(flow: flow)
                case .models: ModelStep(flow: flow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 760, height: 580)
        .onDisappear { flow.cancel() }
    }

    var header: some View {
        HStack(spacing: 14) {
            ForEach(Array(["Host", "Key", "Models"].enumerated()), id: \.offset) { index, title in
                let current = [ConnectFlow.Step.host, .key, .models].firstIndex(of: flow.step) ?? 0
                HStack(spacing: 6) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : "\(index + 1).circle\(index == current ? ".fill" : "")")
                        .foregroundStyle(index <= current ? Color.accentColor : .secondary)
                    Text(title).foregroundStyle(index == current ? .primary : .secondary)
                }
            }
            Spacer()
            Text(flow.preset.map { "Connect \($0.name)" } ?? "Connect a host").font(.headline)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    var footer: some View {
        HStack {
            if flow.step != .host {
                Button("Back") {
                    flow.cancel()
                    flow.step = flow.step == .models ? .key : .host
                }
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            switch flow.step {
            case .host:
                EmptyView()
            case .key:
                Button("Choose Models") { flow.step = .models }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.check == nil)
            case .models:
                Button(flow.chosen.isEmpty ? "Add Models" : "Add \(flow.chosen.count) Model\(flow.chosen.count == 1 ? "" : "s")") {
                    if let ref = flow.addChosen(app: app) { app.selection = .model(ref) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(flow.chosen.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: Host

struct HostStep: View {
    @Environment(AppModel.self) private var app
    let flow: ConnectFlow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where should Leviathan send prompts? Hosted models need a key from the host; models on this Mac need none.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(ProviderPresets.all) { preset in
                        Button { flow.choose(preset, app: app) } label: { card(preset) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }

    func card(_ preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(preset.name).font(.headline)
                Spacer()
                if app.providers.contains(where: { $0.id == preset.id }) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Already set up")
                }
            }
            Text(preset.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if preset.signIn { Tag(text: "Sign in", tint: .accentColor) }
                if preset.local { Tag(text: "On this Mac", tint: .teal) }
                if preset.trainingUse == .prohibited { Tag(text: "Measure only", tint: .orange) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
    }
}

// MARK: Key

struct KeyStep: View {
    @Bindable var flow: ConnectFlow

    var body: some View {
        Form {
            if let preset = flow.preset {
                if preset.apiKeyEnv == nil {
                    Section {
                        Text("\(preset.name) runs on this Mac and needs no key. Start it, then check that it answers.")
                        Button("Check Again") { flow.runCheck() }.disabled(flow.waiting != nil)
                    }
                } else {
                    if preset.signIn {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Button { flow.signIn() } label: {
                                    Label("Sign in with \(preset.name)", systemImage: "person.badge.key").frame(minWidth: 220)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(flow.waiting != nil)
                                Text("Your browser opens. Approve Leviathan there and come back: the key comes straight to the Keychain and is never shown.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(preset.signIn ? "Or paste a key" : "Paste a key") {
                        SecureField("API key", text: $flow.pasted, prompt: Text("Paste the key from \(preset.name)"))
                            .onSubmit { if !flow.pasted.isEmpty { flow.savePasted() } }
                        HStack {
                            Button("Save Key") { flow.savePasted() }
                                .disabled(flow.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.waiting != nil)
                            if let keys = preset.keysURL.flatMap(URL.init(string:)) {
                                Link("Get a key from \(preset.name)", destination: keys)
                            }
                            Spacer()
                            if flow.keySource != .none {
                                Text("A key is saved (\(flow.keySource.rawValue))").font(.caption).foregroundStyle(.secondary)
                                Button("Check It") { flow.runCheck() }.disabled(flow.waiting != nil)
                            }
                        }
                        Text("Saved to your Keychain. Leviathan never writes keys to its files, and never prints them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Status") { status }
                Section { Text(preset.note).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var status: some View {
        if let waiting = flow.waiting {
            HStack {
                ProgressView().controlSize(.small)
                Text(waiting)
                Spacer()
                Button("Cancel") { flow.cancel() }
            }
        } else if let problem = flow.problem {
            Label { Text(problem).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        } else if let check = flow.check {
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected. \(check.models.count) models available.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let status = check.keyStatus {
                    Text("Credit on this key: \(status.summary)").font(.callout)
                }
            }
        } else {
            Text("Not checked yet.").foregroundStyle(.secondary)
        }
    }
}

// MARK: Models

struct ModelStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ConnectFlow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search models", text: $flow.search).textFieldStyle(.roundedBorder)
                Toggle("Open weights only", isOn: $flow.openWeightsOnly)
                    .disabled(!flow.catalogue.contains(where: \.openWeights))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            List(flow.shown) { model in
                ModelRow(model: model, chosen: Binding(
                    get: { flow.chosen.contains(model.id) },
                    set: { if $0 { flow.chosen.insert(model.id) } else { flow.chosen.remove(model.id) } }),
                         added: app.models.contains { $0.providerID == flow.provider?.id && $0.requestModel == model.id })
            }
            .listStyle(.inset)
            Text("New models start with terms \(flow.preset?.trainingUse.rawValue ?? "unknown"). A model's Threads are exported for RaoLM only once you mark it permitted on its page, after reading its licence.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ModelRow: View {
    let model: CatalogueModel
    @Binding var chosen: Bool
    let added: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $chosen).labelsHidden().disabled(added)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name ?? model.modelName).font(.body.weight(.medium))
                    if added { Tag(text: "Added", tint: .green) }
                }
                Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let url = model.huggingFaceURL {
                        Link(destination: url) { Tag(text: "Open weights", tint: .teal) }.help(model.huggingFaceID ?? "")
                    }
                    if let licence = model.licence { Tag(text: licence, tint: .secondary) }
                    if model.takesTemperature == false { Tag(text: "No temperature", tint: .orange) }
                    if model.returnsLogprobs == true { Tag(text: "Log-probabilities", tint: .purple) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.price(model)).font(.callout.monospacedDigit())
                if let context = model.contextLength {
                    Text("\(context >= 1000 ? "\(context / 1000)k" : "\(context)") context").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if !added { chosen.toggle() } }
    }

    static func price(_ model: CatalogueModel) -> String {
        guard model.inputPrice != nil || model.outputPrice != nil else { return "price not listed" }
        return "\(KeyStatus.price(model.inputPrice)) in · \(KeyStatus.price(model.outputPrice)) out /M"
    }
}
