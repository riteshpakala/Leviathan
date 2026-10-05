//
//  PassagePanel.swift
//  LeviathanApp
//
//  WHAT: A prompt's passage as flowing text. Form is dimmed, locked content is plain, and each
//        area is a tinted run you click to see every variant the samples wrote, with the
//        temperatures that wrote it, and to choose one or write your own. A temperature scrubber
//        shows only the areas that had diverged at or below it. Saving writes the edit the next
//        export uses.
//  PIN:  An area's tint deepens with how open it is (the share of samples that did not keep the
//        baseline's wording); orange is the baseline's wording, blue is your choice.
//

import LeviathanCore
import SwiftUI

@MainActor
@Observable
final class PassageEditor {
    var source: ThreadSource?
    var promptID: String?
    var passage: Passage?
    var resolution: Resolution?
    var loading = false
    var problem: String?
    var choices: [IndexRange: Choice] = [:]
    var selectedArea: Int?
    var draft = ""
    var note = ""
    /// Index into `temperatures`; at the last one every area shows.
    var scrub: Double = 0

    var temperatures: [Double] {
        Array(Set(passage?.samples.compactMap(\.temperature) ?? [])).sorted()
    }

    var dirty: Bool {
        guard let passage else { return false }
        let saved = resolution?.baselineRecordID == passage.baselineRecordID ? Set(resolution?.choices ?? []) : []
        return Set(choices.values) != saved
    }

    func load(_ workspace: Workspace, ref: ModelRef, set: String) {
        do {
            source = try ThreadSource.load(workspace, ref: ref, set: set)
            problem = nil
            if promptID == nil {
                promptID = source?.set.prompts.first { !(source?.records(for: $0).isEmpty ?? true) }?.id
            }
        } catch {
            problem = AppModel.describe(error)
        }
    }

    func open() async {
        guard let source, let promptID, let prompt = source.set.prompts.first(where: { $0.id == promptID }) else {
            passage = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            let built = try await Task.detached { try source.passage(for: prompt) }.value
            passage = built
            resolution = source.resolution(for: prompt)
            choices = [:]
            if let resolution, let built, resolution.baselineRecordID == built.baselineRecordID {
                for choice in resolution.choices where built.areas.contains(where: { $0.tokens == choice.tokens }) {
                    choices[choice.tokens] = choice
                }
            }
            selectedArea = Snapshot.request?.area
            draft = ""
            scrub = Double(max(0, temperatures.count - 1))
            problem = nil
        } catch {
            passage = nil
            problem = AppModel.describe(error)
        }
    }

    func isShown(_ area: Area) -> Bool {
        guard let onset = area.onsetTemperature, !temperatures.isEmpty else { return true }
        let index = min(max(0, Int(scrub.rounded())), temperatures.count - 1)
        return onset <= temperatures[index] + 1e-9
    }

    func text(of area: Area) -> String {
        if let choice = choices[area.tokens] {
            if let typed = choice.text { return Resolver.wrap(typed, in: area.baselineText) }
            if let index = choice.variant, area.variants.indices.contains(index) { return area.variants[index].text }
        }
        return area.baselineText
    }

    func current(_ area: Area) -> Int? {
        guard let choice = choices[area.tokens] else { return area.variants.firstIndex(where: \.isBaseline) }
        return choice.variant
    }

    func choose(_ area: Area, variant: Int) {
        choices[area.tokens] = area.variants[variant].isBaseline ? nil : Choice(tokens: area.tokens, variant: variant)
    }

    func write(_ area: Area, _ text: String) {
        choices[area.tokens] = Choice(tokens: area.tokens, text: text)
    }

    func clear(_ area: Area) {
        choices[area.tokens] = nil
    }

    func save(_ workspace: Workspace) throws -> Resolution {
        guard let passage, let source else { throw LeviathanFailure("no passage is open") }
        let saved = try Resolver.resolve(passage, choices: Array(choices.values), note: note.isEmpty ? nil : note)
        try EditStore.append(saved, workspace: workspace, ref: source.ref)
        self.source = try ThreadSource.load(workspace, ref: source.ref, set: source.set.id)
        resolution = saved
        note = ""
        return saved
    }

    /// The passage as styled text with each shown area a link to itself.
    func attributed(_ passage: Passage) -> AttributedString {
        var out = AttributedString()
        let text = passage.text
        let tokens = passage.baseline.tokens
        var offset = 0
        for segment in passage.segments {
            let end = offset + segment.text.utf8.count
            switch segment.kind {
            case .locked:
                var cursor = offset
                for i in segment.tokens.range {
                    var piece = AttributedString(Tokenizer.slice(text, cursor, tokens[i].end))
                    if tokens[i].role == .form { piece.foregroundColor = .secondary }
                    out += piece
                    cursor = tokens[i].end
                }
                if cursor < end { out += AttributedString(Tokenizer.slice(text, cursor, end)) }
            case .area:
                guard let id = segment.area, let area = passage.area(id) else { break }
                var piece = AttributedString(self.text(of: area))
                if isShown(area) {
                    let openness = 1 - (area.baselineVariant?.share ?? 1)
                    let color: Color = choices[area.tokens] == nil ? .orange : .blue
                    piece.backgroundColor = color.opacity(0.16 + 0.5 * openness)
                    piece.foregroundColor = .primary
                    piece.link = URL(string: "leviathan-area://\(id)")
                    if selectedArea == id { piece.underlineStyle = .single }
                }
                out += piece
            }
            offset = end
        }
        return out
    }
}

struct PassagePanel: View {
    @Environment(AppModel.self) private var app
    let ref: ModelRef
    let set: String
    var work: String? = nil

    @State private var editor = PassageEditor()

    var body: some View {
        @Bindable var editor = editor
        HSplitView {
            List(selection: $editor.promptID) {
                ForEach(editor.source?.set.prompts ?? []) { prompt in
                    let count = editor.source?.records(for: prompt).count ?? 0
                    HStack {
                        Text(prompt.id)
                        Spacer()
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                    .tag(prompt.id)
                }
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)

            center
                .frame(minWidth: 420, idealWidth: 620)

            inspector
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
        }
        .onAppear {
            if let workspace = app.workspace(for: work) { editor.load(workspace, ref: ref, set: set) }
        }
        .task(id: editor.promptID) { await editor.open() }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "leviathan-area", let id = Int(url.host ?? "") else { return .systemAction }
            editor.selectedArea = id
            editor.draft = ""
            return .handled
        })
    }

    @ViewBuilder var center: some View {
        if let problem = editor.problem {
            ContentUnavailableView("Cannot build the passage", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if editor.loading {
            ProgressView("Aligning samples…")
        } else if let passage = editor.passage {
            VStack(alignment: .leading, spacing: 10) {
                let m = passage.measures
                Text("\(m.samples) samples · \(m.aligned) aligned · \(m.divergent) alternates · \(m.setAside) set aside · "
                    + "\(Format.percent(m.lockedShare)) of words locked · "
                    + (passage.builtOnReference ? "baseline: your text" : "baseline T \(Format.temperature(passage.baselineTemperature))"))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(editor.attributed(passage))
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                if editor.temperatures.count > 1 {
                    HStack {
                        Text("Diverged at or below")
                        Slider(value: $editor.scrub, in: 0...Double(editor.temperatures.count - 1), step: 1)
                        Text("T \(Format.temperature(editor.temperatures[min(Int(editor.scrub.rounded()), editor.temperatures.count - 1)]))")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
                HStack {
                    TextField("Note for this edit", text: $editor.note)
                    Button("Save Edit") {
                        app.perform(in: work) { workspace in
                            let saved = try editor.save(workspace)
                            return saved.edited ? "Saved edit \(saved.id.prefix(8)): the next export uses it." : "Saved: the text is the baseline's."
                        }
                    }
                    .keyboardShortcut("s")
                    .disabled(!editor.dirty)
                }
                Divider()
                expectations(passage)
                    .frame(minHeight: 140)
            }
            .padding()
        } else {
            ContentUnavailableView("No samples yet", systemImage: "text.quote",
                                   description: Text("Harvest this prompt first, then its passage appears here."))
        }
    }

    func expectations(_ passage: Passage) -> some View {
        let area = editor.selectedArea.flatMap(passage.area)
        let rows = passage.expectations.filter { expectation in
            guard let area else { return expectation.support > 0 }
            let span = IndexRange(expectation.stem.lower, expectation.answer.upper)
            return span.lower <= area.tokens.upper && area.tokens.lower <= span.upper
        }.sorted { ($0.confidence ?? -1, $0.support) > ($1.confidence ?? -1, $1.support) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(area == nil ? "Expectations (\(rows.count) with support)" : "Expectations touching area \(area!.id)").font(.headline)
            List(rows) { expectation in
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.share(expectation.confidence)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    Text("\(expectation.support)").foregroundStyle(.secondary).monospacedDigit().frame(width: 24, alignment: .trailing)
                    Text(expectation.stemText).foregroundStyle(.secondary) + Text(" ▸") + Text(expectation.answerText).bold()
                    Spacer()
                    if let onset = expectation.onsetTemperature {
                        Text("breaks at T \(Format.temperature(onset))").font(.caption).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder var inspector: some View {
        @Bindable var editor = editor
        if let passage = editor.passage, let id = editor.selectedArea, let area = passage.area(id) {
            Form {
                Section("Area \(id)") {
                    Button("All Areas") { editor.selectedArea = nil }
                    LabeledContent("First diverged", value: area.onsetKey.map { $0 == "default" ? "at the default" : "at T \(Format.temperature(area.onsetTemperature))" } ?? "–")
                    LabeledContent("Entropy", value: String(format: "%.2f bits", area.entropy))
                    if !area.holdsContent { Text("Form only: punctuation or function words.").font(.caption) }
                    if area.tokens.isEmpty { Text("An insertion: the baseline has nothing here.").font(.caption) }
                }
                Section("Variants") {
                    ForEach(Array(area.variants.enumerated()), id: \.offset) { index, variant in
                        Button {
                            editor.choose(area, variant: index)
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: editor.current(area) == index && editor.choices[area.tokens]?.text == nil
                                      ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("“\(variant.text.trimmingCharacters(in: .whitespaces))”"
                                        + (variant.isBaseline ? (passage.builtOnReference ? "  your text" : "  baseline") : ""))
                                    Text("\(Format.share(variant.share)) of samples · T "
                                        + Set(variant.samples.filter { !$0.isReference }.map { Format.temperature($0.temperature) }).sorted()
                                            .joined(separator: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Your own words") {
                    TextField("Replace this area with…", text: $editor.draft, axis: .vertical).lineLimit(1...5)
                    HStack {
                        Button("Use These Words") { editor.write(area, editor.draft) }
                        Button("Back to Baseline") { editor.clear(area) }
                    }
                    if let typed = editor.choices[area.tokens]?.text {
                        Text("Using: “\(typed)”").font(.caption)
                    }
                }
                Section("By temperature") {
                    ForEach(area.byTemperature, id: \.self) { row in
                        LabeledContent("T \(Format.temperature(row.temperature))",
                                       value: "\(Format.percent(row.keptBaseline)) kept the baseline (\(row.samples))")
                    }
                }
            }
            .formStyle(.grouped)
        } else if let passage = editor.passage {
            Form {
                if !passage.areas.isEmpty {
                    Section("Areas") {
                        ForEach(passage.areas) { area in
                            Button {
                                editor.selectedArea = area.id
                                editor.draft = ""
                            } label: {
                                HStack {
                                    Text("[\(area.id)]").monospacedDigit().foregroundStyle(.secondary)
                                    Text(editor.text(of: area).trimmingCharacters(in: .whitespaces)).lineLimit(1)
                                    Spacer()
                                    Text("\(area.variants.count) variants").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Area \(area.id)")
                        }
                    }
                }
                Section("Samples") {
                    ForEach(passage.samples, id: \.recordID) { sample in
                        LabeledContent("T \(Format.temperature(sample.temperature)) #\(sample.sampleIndex)") {
                            switch sample.status {
                            case .baseline: Text("baseline").bold()
                            case .aligned: Text("aligned · \(Format.share(sample.overlap))")
                            case .divergent: Text("alternate · \(Format.share(sample.overlap))").foregroundStyle(.orange)
                            case .setAside: Text(sample.reason ?? "set aside").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("Click a tinted area, or pick one above, to see its variants.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            Color.clear
        }
    }
}
