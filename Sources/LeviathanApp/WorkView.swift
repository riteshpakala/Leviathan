//
//  WorkView.swift
//  LeviathanApp
//
//  WHAT: One of your works: bring writing in (a Gita's Ballad season export, its
//        Narrative.json, or a text file, by button or by dropping it here), see each passage
//        and who wrote it, set the terms for each origin, make studies, open a model's answers
//        to a study, and write the report.
//  PIN:  Everything lives in works/<id>/, which git ignores. The work's text is sent only to
//        hosts cleared for it on their page.
//

import AppKit
import LeviathanCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkView: View {
    @Environment(AppModel.self) private var app
    let id: String?

    @State private var newID = ""
    @State private var newTitle = ""
    @State private var passages: [WorkPassage] = []
    @State private var origins: [String: OriginTerms] = [:]
    @State private var dropping = false
    @State private var studyModel: ModelRef?
    @State private var studySet = StudyKind.revise.rawValue
    @State private var reportURL: URL?

    var work: Work? { app.works.first { $0.id == id } }

    var body: some View {
        Form {
            if let work {
                Section {
                    LabeledContent("Title", value: work.title)
                    if let author = work.author { LabeledContent("Author", value: author) }
                    LabeledContent("Passages", value: "\(passages.count): \(passages.filter { $0.origin == .authored }.count) yours, "
                        + "\(passages.filter { $0.origin == .generated }.count) by the story's model")
                    Label("Private: its text goes only to hosts you cleared, and stays in works/\(work.id)/, which git ignores.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                bringIn
                passageList
                originTerms
                studies(work)
                Section("Report") {
                    HStack {
                        Button("Write Report") { writeReport(work) }
                        if let reportURL {
                            Button("Open") { NSWorkspace.shared.open(reportURL) }
                            Text(reportURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("What a light edit keeps, whether a model can recall your text, and how models would have written each passage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Bring in your writing") {
                    TextField("Id", text: $newID, prompt: Text("gita-ballad"))
                    TextField("Title", text: $newTitle, prompt: Text("Gita's Wish"))
                    Button("Create Work") { create() }.disabled(!PathComponent.isPlain(newID))
                    Text("A work keeps your writing apart from everything else. Then bring in a season export, its Narrative.json, or a text file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(work?.title ?? "New Work")
        .onAppear(perform: load)
        .onChange(of: app.works) { _, _ in load() }
    }

    // MARK: Sections

    var bringIn: some View {
        Section("Bring writing in") {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(.secondary)
                Text("Drop a season export, its Narrative.json, or a text file here").font(.callout)
                Text("In Gita's Ballad: Timeline → Export. Importing a later export adds only its new passages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 10).fill(dropping ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                bring(urls)
                return true
            } isTargeted: { dropping = $0 }
            Button("Choose Files…") { choose([.json, .plainText, UTType(filenameExtension: "md") ?? .plainText]) }
        }
    }

    var passageList: some View {
        Section("Passages") {
            if passages.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
            ForEach(passages) { passage in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(passage.index)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Tag(text: passage.origin == .authored ? "Yours" : "Model", tint: passage.origin == .authored ? .teal : .purple)
                            if let mark = passage.kind ?? passage.tool { Tag(text: mark, tint: .secondary) }
                            Text("\(passage.words) words").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(passage.text).lineLimit(2).font(.callout)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    var originTerms: some View {
        Section("Who wrote what") {
            ForEach(PassageOrigin.allCases, id: \.self) { origin in
                let key = origin.rawValue
                VStack(alignment: .leading, spacing: 6) {
                    Picker(origin == .authored ? "Your passages" : "The story model's passages", selection: Binding(
                        get: { origins[key]?.trainingUse ?? .unknown },
                        set: { origins[key, default: OriginTerms(trainingUse: .unknown)].trainingUse = $0 })) {
                        Text("Permitted").tag(TrainingUse.permitted)
                        Text("Prohibited").tag(TrainingUse.prohibited)
                        Text("Unknown").tag(TrainingUse.unknown)
                    }
                    .pickerStyle(.segmented)
                    TextField("Written by", text: Binding(
                        get: { origins[key]?.writer ?? "" },
                        set: { origins[key, default: OriginTerms(trainingUse: .unknown)].writer = $0.isEmpty ? nil : $0 }),
                              prompt: Text(origin == .authored ? "you" : "the model and host that wrote them"))
                }
            }
            Button("Save Terms") { saveTerms() }
            Text("A Thread built on your text is exported for RaoLM only when both the model's terms and the text's origin are permitted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func studies(_ work: Work) -> some View {
        Section("Studies") {
            ForEach(StudyKind.allCases, id: \.self) { kind in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.rawValue.capitalized).font(.headline)
                        Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let count = app.promptSet(kind.rawValue, work: work.id)?.prompts.count ?? 0
                    if count > 0 { Text("\(count) prompts").font(.caption).foregroundStyle(.secondary) }
                    Button(count > 0 ? "Remake" : "Make") { make(kind, work: work) }
                        .disabled(passages.isEmpty)
                }
            }
            HStack {
                Picker("Ask", selection: $studyModel) {
                    Text("Choose a model").tag(ModelRef?.none)
                    ForEach(app.models, id: \.ref) { Text($0.ref.description).tag(ModelRef?.some($0.ref)) }
                }
                Picker("about", selection: $studySet) {
                    ForEach(StudyKind.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .fixedSize()
                Button("Open") { if let studyModel { app.selection = .workThread(work.id, studyModel, studySet) } }
                    .disabled(studyModel == nil || app.promptSet(studySet, work: work.id) == nil)
            }
            ForEach(app.workThreads[work.id] ?? []) { thread in
                HStack {
                    Text("\(thread.set) · \(thread.ref.description)")
                    Spacer()
                    Text("\(thread.samples) samples").foregroundStyle(.secondary)
                    Button("Open") { app.selection = .workThread(work.id, thread.ref, thread.set) }
                }
            }
        }
    }

    // MARK: Actions

    func load() {
        guard let id, let workspace = app.workspace else { return }
        passages = (try? WorkStore.passages(id, in: workspace)) ?? []
        origins = work?.origins ?? [:]
    }

    func create() {
        let id = newID
        app.perform { workspace in
            _ = try WorkImport.ensure(id, title: newTitle.isEmpty ? nil : newTitle, author: nil, in: workspace)
            app.selection = .work(id)
            return "Made the work \(id). Bring in a season export, its Narrative.json, or a text file."
        }
    }

    func choose(_ types: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        bring(panel.urls)
    }

    /// Imports files by what they hold: a season export, a narrative file, or plain text.
    func bring(_ urls: [URL]) {
        guard let id else { return }
        app.perform { workspace in
            var notes: [String] = []
            let files = try urls.map { url -> (URL, Data, JSONValue?) in
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    throw LeviathanFailure("cannot read \(url.lastPathComponent)")
                }
                return (url, data, url.pathExtension.lowercased() == "json" ? JSONValue.parse(data) : nil)
            }
            // The narrative first, so the season's opening can be recognised as yours.
            for (url, data, json) in files where json?["authorPreamble"] != nil {
                _ = try WorkImport.narrative(data, name: url.lastPathComponent, work: id, in: workspace)
                notes.append("\(url.lastPathComponent): the narrative")
            }
            for (url, data, json) in files where json?["authorPreamble"] == nil {
                let summary: ImportSummary
                if let json {
                    guard json["format"]?.string == WorkImport.seasonFormat else {
                        throw LeviathanFailure("\(url.lastPathComponent) is neither a Gita season export nor a Narrative.json")
                    }
                    summary = try WorkImport.season(data, name: url.lastPathComponent, work: id, in: workspace)
                } else {
                    summary = try WorkImport.text(String(decoding: data, as: UTF8.self), name: url.lastPathComponent, work: id, in: workspace)
                }
                notes.append("\(url.lastPathComponent): \(summary.added) new passage\(summary.added == 1 ? "" : "s")")
            }
            return "Brought in " + notes.joined(separator: "; ") + "."
        }
        load()
    }

    func saveTerms() {
        guard let id else { return }
        app.perform { workspace in
            var work = try WorkStore.load(id, in: workspace)
            work.origins = origins
            try WorkStore.save(work, in: workspace)
            return "Saved the terms for \(work.title)."
        }
    }

    func make(_ kind: StudyKind, work: Work) {
        app.perform { workspace in
            let summary = try Study.make(kind, work: work.id, in: workspace)
            studySet = kind.rawValue
            return "Made the \(kind.rawValue) study: \(summary.prompts.count) prompts"
                + (summary.skipped.isEmpty ? "." : "; \(summary.skipped.count) too short to split.")
        }
    }

    func writeReport(_ work: Work) {
        app.perform { workspace in
            let url = try WorkReport.write(work: work.id, in: workspace)
            reportURL = url
            return "Wrote \(workspace.relative(url))."
        }
    }
}
