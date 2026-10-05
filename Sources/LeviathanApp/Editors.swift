//
//  Editors.swift
//  LeviathanApp
//
//  WHAT: The pages for a provider, a model and a prompt set.
//  PIN:  A provider's key is saved to the Keychain, never to providers.json. A model starts from
//        its provider's preset; only you mark its terms `permitted`, after reading its licence.
//        Editing a prompt's text starts its samples afresh: they are keyed by the prompt's hash.
//

import LeviathanCore
import SwiftUI

// MARK: Provider

struct ProviderEditor: View {
    @Environment(AppModel.self) private var app
    let id: String?

    @State private var draft = Provider(id: "", name: "", baseURL: "http://localhost:11434/v1")
    @State private var preset = ""
    @State private var keyVariable = ""
    @State private var extraBody = ""
    @State private var key = ""
    @State private var keySource: APIKeySource?
    @State private var privateAllowed = false
    @State private var privateSource = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section(id == nil ? "New provider" : "Provider \(draft.id)") {
                if id == nil {
                    Picker("Preset", selection: $preset) {
                        Text("None").tag("")
                        ForEach(ProviderPresets.all) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: preset) { _, value in apply(preset: value) }
                    TextField("Id", text: $draft.id, prompt: Text("ollama"))
                }
                TextField("Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL, prompt: Text("http://localhost:11434/v1"))
                TextField("Key variable", text: $keyVariable, prompt: Text("none: the host needs no key"))
                Stepper("Requests in flight: \(draft.maxConcurrent)", value: $draft.maxConcurrent, in: 1...32)
                TextField("Timeout (seconds)", value: $draft.timeoutSeconds, format: .number)
                TextField("Extra request fields (JSON object)", text: $extraBody, axis: .vertical).lineLimit(1...4).font(.body.monospaced())
                if let note = ProviderPresets.preset(draft.preset ?? preset)?.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            if id != nil {
                Section("API key") {
                    LabeledContent("Found", value: keySource?.rawValue ?? "…")
                    SecureField("Paste a key to save it in the Keychain", text: $key)
                    HStack {
                        Button("Save Key") {
                            app.perform { _ in
                                try KeychainSecretStore().write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: draft.id)
                                key = ""
                                return "Saved a key for \(draft.id) to the Keychain."
                            }
                            Task { await loadKeySource() }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove Saved Key") {
                            app.perform { _ in
                                try KeychainSecretStore().delete(draft.id)
                                return "Removed the saved key for \(draft.id)."
                            }
                            Task { await loadKeySource() }
                        }
                        if let preset = draft.presetInfo {
                            Spacer()
                            Button(preset.signIn ? "Sign In or Choose Models…" : "Choose Models…") { app.connect(preset.id, provider: draft.id) }
                        }
                    }
                }
                Section("Your works") {
                    if let refusal = draft.presetInfo?.privateRefusal {
                        Label(refusal, systemImage: "hand.raised.fill").foregroundStyle(.orange)
                    } else {
                        Toggle("May receive your works' text", isOn: $privateAllowed)
                        TextField("Where you read its data terms", text: $privateSource, prompt: Text(draft.presetInfo?.dataTerms ?? "a link to them"))
                        HStack {
                            Button("Save") { savePrivate() }
                                .disabled(privateAllowed && privateSource.trimmingCharacters(in: .whitespaces).isEmpty)
                            if let terms = draft.presetInfo?.dataTerms.flatMap(URL.init(string:)) {
                                Link("Read \(draft.name)'s data terms", destination: terms)
                            }
                        }
                        if !draft.privateExtraBody.isEmpty {
                            Text("Requests carrying your text add \((try? JSONCoding.line(draft.privateExtraBody)) ?? ""), so the host neither keeps nor logs it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Until you clear it, a harvest of your work's studies sends this host nothing.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    Button("Save") { save() }.keyboardShortcut("s").disabled(draft.id.isEmpty || draft.baseURL.isEmpty)
                    if id != nil {
                        Button(testing ? "Testing…" : "Test Connection") { Task { await test() } }.disabled(testing)
                        Spacer()
                        Button("Delete", role: .destructive) {
                            app.perform { workspace in
                                try ProviderStore.remove(draft.id, in: workspace)
                                app.selection = nil
                                return "Removed provider \(draft.id)."
                            }
                        }
                    }
                }
                if let testResult { Text(testResult).font(.callout).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(id ?? "New Provider")
        .onAppear(perform: load)
        .task { await loadKeySource() }
    }

    func load() {
        guard let id, let found = app.providers.first(where: { $0.id == id }) else { return }
        draft = found
        keyVariable = found.apiKeyEnv ?? ""
        extraBody = found.extraBody.isEmpty ? "" : ((try? JSONCoding.line(found.extraBody)) ?? "")
        privateAllowed = found.acceptsPrivateText
        privateSource = found.privateSource ?? ""
    }

    func savePrivate() {
        app.perform { workspace in
            let provider = try PrivateText.clear(try ProviderStore.provider(draft.id, in: workspace), allow: privateAllowed, source: privateSource)
            try ProviderStore.upsert(provider, in: workspace)
            draft.acceptsPrivateText = provider.acceptsPrivateText
            draft.privateSource = provider.privateSource
            draft.privateExtraBody = provider.privateExtraBody
            return privateAllowed ? "\(draft.id) may now receive your works' text." : "\(draft.id) no longer receives your works' text."
        }
    }

    func loadKeySource() async {
        guard let id, let provider = app.providers.first(where: { $0.id == id }) else { return }
        keySource = await Task.detached { APIKeyResolver.resolve(provider, store: KeychainSecretStore()).source }.value
    }

    func apply(preset id: String) {
        guard let found = ProviderPresets.preset(id) else { return }
        draft = found.provider()
        keyVariable = found.apiKeyEnv ?? ""
        extraBody = found.extraBody.isEmpty ? "" : ((try? JSONCoding.line(found.extraBody)) ?? "")
    }

    func save() {
        var provider = draft
        provider.apiKeyEnv = keyVariable.trimmingCharacters(in: .whitespaces).isEmpty ? nil : keyVariable.trimmingCharacters(in: .whitespaces)
        if provider.name.isEmpty { provider.name = provider.id }
        app.perform { workspace in
            guard PathComponent.isPlain(provider.id) else {
                throw LeviathanFailure("provider ids take [A-Za-z0-9._-]")
            }
            if extraBody.trimmingCharacters(in: .whitespaces).isEmpty {
                provider.extraBody = [:]
            } else {
                guard case .object(let fields) = JSONValue.parse(Data(extraBody.utf8)) ?? .null else {
                    throw LeviathanFailure("extra request fields must be a JSON object")
                }
                provider.extraBody = fields
            }
            _ = try provider.endpoint("chat/completions")
            try ProviderStore.upsert(provider, in: workspace)
            app.selection = .provider(provider.id)
            return "Saved provider \(provider.id)."
        }
    }

    func test() async {
        testing = true
        defer { testing = false }
        let provider = draft
        let (key, source) = await Task.detached { APIKeyResolver.resolve(provider, store: KeychainSecretStore()) }.value
        do {
            let check = try await ProviderCheck.run(provider, key: key, source: source)
            testResult = check.summary + ": " + check.models.prefix(12).map(\.id).joined(separator: ", ") + (check.models.count > 12 ? ", …" : "")
        } catch {
            testResult = ConnectFlow.describe(error)
        }
    }
}

// MARK: Model

struct ModelEditor: View {
    @Environment(AppModel.self) private var app
    let ref: ModelRef?

    @State private var draft = ModelTarget(company: "", modelID: "", providerID: "")
    @State private var available: [String] = []
    @State private var fetching = false

    var body: some View {
        Form {
            Section(ref == nil ? "New model" : "Model") {
                Picker("Provider", selection: $draft.providerID) {
                    Text("Choose…").tag("")
                    ForEach(app.providers) { Text($0.id).tag($0.id) }
                }
                .onChange(of: draft.providerID) { _, id in if ref == nil { applyPreset(providerID: id) } }
                TextField("Company (the maker, not the host)", text: $draft.company, prompt: Text("qwen")).disabled(ref != nil)
                HStack {
                    TextField("Model id", text: $draft.modelID, prompt: Text("qwen2.5:7b")).disabled(ref != nil)
                    if !available.isEmpty {
                        Menu("Pick") {
                            ForEach(available, id: \.self) { id in
                                Button(id) {
                                    if ref == nil { draft.modelID = id }
                                    draft.requestModel = id
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Button(fetching ? "Fetching…" : "Fetch Models") { Task { await fetch() } }.disabled(draft.providerID.isEmpty || fetching)
                }
                TextField("Request model (sent on the wire)", text: $draft.requestModel, prompt: Text(draft.modelID))
                if !draft.company.isEmpty, !draft.modelID.isEmpty {
                    LabeledContent("Folder", value: "dataset/\(draft.ref.company)/\(draft.ref.model)")
                }
            }
            Section("Sampling") {
                Picker("Temperature", selection: $draft.sampling.temperature) {
                    Text("Takes a range").tag(TemperatureMode.range)
                    Text("Default only").tag(TemperatureMode.defaultOnly)
                }
                .pickerStyle(.segmented)
                if draft.sampling.temperature == .range {
                    HStack {
                        TextField("From", value: $draft.sampling.minTemperature, format: .number)
                        TextField("To", value: $draft.sampling.maxTemperature, format: .number)
                    }
                    Text("Temperatures outside this range are dropped from a plan, never sent.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No temperature is sent; samples repeat at the host's default.").font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Max tokens: \(draft.sampling.maxTokens)", value: $draft.sampling.maxTokens, in: 16...32_768, step: 128)
                Picker("Max-tokens field", selection: $draft.sampling.maxTokensField) {
                    ForEach(MaxTokensField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Ask for token log-probabilities", isOn: $draft.sampling.logprobs)
            }
            Section("Price") {
                HStack {
                    TextField("Input, $ per million tokens", value: price(\.inputPerMillion), format: .number)
                    TextField("Output, $ per million tokens", value: price(\.outputPerMillion), format: .number)
                }
                Text((draft.pricing?.source.map { "From \($0). " } ?? "")
                    + "A harvest states its cost from these before sending anything, and stops at the limit you set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terms") {
                Picker("Training use", selection: $draft.terms.trainingUse) {
                    Text("Permitted").tag(TrainingUse.permitted)
                    Text("Prohibited").tag(TrainingUse.prohibited)
                    Text("Unknown").tag(TrainingUse.unknown)
                }
                .pickerStyle(.segmented)
                Text("Only a permitted model's Threads are exported for RaoLM. Mark it permitted once you have read a licence that allows training on its outputs.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Licence", text: optional($draft.terms.licence))
                TextField("Where the terms were read", text: optional($draft.terms.source))
                TextField("Note", text: optional($draft.terms.note))
            }
            if let ref {
                Section("Threads") {
                    ForEach(app.sets) { set in
                        HStack {
                            Text(set.id)
                            Spacer()
                            Text("\(app.sampleCount(ref, set.id)) samples").foregroundStyle(.secondary)
                            Button("Open") { app.selection = .thread(ref, set.id) }
                        }
                    }
                }
            }
            Section {
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .disabled(draft.providerID.isEmpty || draft.company.isEmpty || draft.modelID.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(ref?.description ?? "New Model")
        .onAppear {
            if let ref, let found = app.models.first(where: { $0.ref == ref }) { draft = found }
        }
    }

    /// One of the model's prices; clearing both removes them.
    func price(_ key: WritableKeyPath<Pricing, Double?>) -> Binding<Double?> {
        Binding(get: { draft.pricing?[keyPath: key] }, set: { value in
            var pricing = draft.pricing ?? Pricing()
            pricing[keyPath: key] = value
            pricing.source = "given"
            draft.pricing = pricing.inputPerMillion == nil && pricing.outputPerMillion == nil ? nil : pricing
        })
    }

    func applyPreset(providerID: String) {
        guard let provider = app.providers.first(where: { $0.id == providerID }),
              let preset = provider.preset.flatMap(ProviderPresets.preset) else { return }
        draft.sampling = preset.sampling
        draft.terms.trainingUse = preset.trainingUse
    }

    func fetch() async {
        guard let provider = app.providers.first(where: { $0.id == draft.providerID }) else { return }
        fetching = true
        defer { fetching = false }
        do {
            let (key, _) = APIKeyResolver.resolve(provider, store: KeychainSecretStore())
            available = try await OpenAICompatibleClient(provider: provider, apiKey: key, retry: RetryPolicy(maxAttempts: 1)).listModels()
            if available.isEmpty { app.show("\(provider.id) lists no models.", error: false) }
        } catch {
            app.show(AppModel.describe(error), error: true)
        }
    }

    func save() {
        var target = draft
        if target.requestModel.isEmpty { target.requestModel = target.modelID }
        app.perform { workspace in
            guard target.sampling.minTemperature <= target.sampling.maxTemperature else {
                throw LeviathanFailure("the temperature range is empty")
            }
            try ModelStore.save(target, in: workspace)
            app.selection = .model(target.ref)
            return "Saved \(target.ref)."
        }
    }
}

// MARK: Prompt set

struct PromptSetEditor: View {
    @Environment(AppModel.self) private var app
    let setID: String?

    @State private var newSetID = ""
    @State private var system = ""
    @State private var kind = DocumentKinds.harvested
    @State private var selected: String?
    @State private var text = ""
    @State private var newPromptID = ""

    var set: PromptSet? { app.sets.first { $0.id == setID } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                if setID == nil {
                    TextField("Set id", text: $newSetID, prompt: Text("writing"))
                }
                List(selection: $selected) {
                    ForEach(set?.prompts ?? []) { prompt in
                        VStack(alignment: .leading) {
                            Text(prompt.id).font(.headline)
                            Text(prompt.text).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(prompt.id)
                    }
                }
                HStack {
                    TextField("New prompt id", text: $newPromptID)
                    Button("Add") {
                        selected = nil
                        text = ""
                    }
                    .disabled(newPromptID.isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)

            Form {
                Section("Prompt \(selected ?? newPromptID)") {
                    TextEditor(text: $text).font(.body).frame(minHeight: 180)
                    Text("Changing the text starts this prompt's samples afresh: samples are keyed by the prompt's hash.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save Prompt") { savePrompt() }
                        .keyboardShortcut("s")
                        .disabled((selected ?? newPromptID).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (setID ?? newSetID).isEmpty)
                }
                Section("Set") {
                    TextEditor(text: $system).font(.body).frame(minHeight: 80)
                    Text("The system prompt, sent before every prompt in the set.").font(.caption).foregroundStyle(.secondary)
                    Picker("Written to RaoLM as", selection: $kind) {
                        ForEach(DocumentKinds.raolm.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Button("Save Set") { saveSet() }.disabled((setID ?? newSetID).isEmpty)
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(setID ?? "New Prompt Set")
        .onAppear {
            system = set?.system ?? ""
            kind = set?.settings.documentKind ?? DocumentKinds.harvested
        }
        .onChange(of: selected) { _, id in
            text = set?.prompts.first { $0.id == id }?.text ?? ""
        }
    }

    func savePrompt() {
        let target = setID ?? newSetID
        let id = selected ?? newPromptID
        app.perform { workspace in
            let url = try PromptStore.add(set: target, id: id, text: text, in: workspace)
            if setID == nil { app.selection = .promptSet(target) }
            newPromptID = ""
            selected = id
            return "Saved \(workspace.relative(url))."
        }
    }

    func saveSet() {
        let target = setID ?? newSetID
        app.perform { workspace in
            try FileManager.default.createDirectory(at: workspace.promptSetDirectory(target), withIntermediateDirectories: true)
            try PromptStore.setSystem(set: target, text: system, in: workspace)
            try PromptStore.saveSettings(PromptSetSettings(documentKind: kind), set: target, in: workspace)
            if setID == nil { app.selection = .promptSet(target) }
            return "Saved set \(target)."
        }
    }
}

/// A text binding over an optional string: empty means nil.
func optional(_ binding: Binding<String?>) -> Binding<String> {
    Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
}
