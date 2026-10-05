//
//  ContentView.swift
//  LeviathonApp
//
//  WHAT: The window: models grouped by company (each with its Threads, one per prompt set),
//        prompt sets and providers in the sidebar; the selected one's page beside it.
//

import LeviathonCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            Group {
                if let problem = app.rootProblem {
                    ContentUnavailableView {
                        Label("No workspace", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(problem)
                    } actions: {
                        Button("Choose Folder…") { app.chooseRoot() }
                    }
                } else {
                    Detail(item: app.selection)
                        .id(app.selection)
                }
            }
        }
        .overlay(alignment: .bottom) { BannerView() }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section("Models") {
                if app.models.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(Dictionary(grouping: app.models, by: \.company).sorted { $0.key < $1.key }, id: \.key) { company, targets in
                    Text(company).font(.caption).foregroundStyle(.secondary)
                    ForEach(targets, id: \.ref) { target in
                        Label(target.modelID, systemImage: "cpu")
                            .badge(target.terms.trainingUse == .permitted ? nil : Text(target.terms.trainingUse.rawValue))
                            .tag(SidebarItem.model(target.ref))
                        // Each row's identity names its model too: a set's id repeats under every model.
                        ForEach(app.sets.map { SidebarItem.thread(target.ref, $0.id) }, id: \.self) { item in
                            if case .thread(let ref, let set) = item {
                                Label(set, systemImage: "text.quote")
                                    .badge(app.sampleCount(ref, set))
                                    .padding(.leading, 16)
                                    .tag(item)
                            }
                        }
                    }
                }
            }
            Section("Prompt sets") {
                ForEach(app.sets) { set in
                    Label(set.id, systemImage: "list.bullet.rectangle").badge(set.prompts.count).tag(SidebarItem.promptSet(set.id))
                }
            }
            Section("Providers") {
                ForEach(app.providers) { provider in
                    Label(provider.id, systemImage: "server.rack").tag(SidebarItem.provider(provider.id))
                }
            }
        }
        .toolbar {
            Menu {
                Button("New Provider") { app.selection = .newProvider }
                Button("New Model") { app.selection = .newModel }
                Button("New Prompt Set") { app.selection = .newPromptSet }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(app.workspace?.root.path ?? "No workspace").font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                HStack {
                    Button("Choose…") { app.chooseRoot() }
                    Button("Reload") { app.reload() }
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }
}

struct Detail: View {
    let item: SidebarItem?

    var body: some View {
        switch item {
        case .model(let ref): ModelEditor(ref: ref)
        case .newModel: ModelEditor(ref: nil)
        case .thread(let ref, let set): ThreadView(ref: ref, set: set)
        case .promptSet(let id): PromptSetEditor(setID: id)
        case .newPromptSet: PromptSetEditor(setID: nil)
        case .provider(let id): ProviderEditor(id: id)
        case .newProvider: ProviderEditor(id: nil)
        case nil:
            ContentUnavailableView {
                Label("Leviathon", systemImage: "water.waves")
            } description: {
                Text("Add a provider, a model and a prompt set, then open a Thread under the model to harvest and edit its passages.")
            }
        }
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let banner = app.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
                Text(banner.text).textSelection(.enabled).frame(maxWidth: 640, alignment: .leading)
                Button {
                    app.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 4)
            .padding()
            .task(id: banner.id) {
                guard !banner.isError else { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if app.banner?.id == banner.id { app.banner = nil }
            }
        }
    }
}
