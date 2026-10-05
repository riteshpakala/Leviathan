//
//  Workspace.swift
//  LeviathanCore
//
//  WHAT: The package root everything lives under, and every path Leviathan reads or writes.
//  IN:   The root resolves from an explicit path, then $LEVIATHAN_ROOT, then a folder the app
//        saved, then the nearest ancestor of the working directory whose Package.swift names
//        Leviathan, then the checkout the binary was built from (a launch from Xcode runs in
//        DerivedData, so the working directory does not lead back here).
//  PIN:  Scoped to a work, the paths that hold its text (prompts, transcripts, threads, evidence,
//        reports) move under works/<id>/, which git ignores. Providers, model definitions and
//        catalogue/PROPERTIES.md stay shared at the root, so a model set up once serves both.
//

import Foundation

public struct Workspace: Sendable, Hashable {
    public let root: URL
    /// The work these paths are scoped to, if any.
    public let work: String?

    public static let environmentKey = "LEVIATHAN_ROOT"

    public init(root: URL, work: String? = nil) {
        self.root = root.standardizedFileURL
        self.work = work
    }

    /// The same root, scoped to a work (or to none).
    public func scoped(to work: String?) -> Workspace {
        Workspace(root: root, work: work)
    }

    public enum Source: String, Sendable, Codable {
        case explicit, environment, saved, workingDirectory, buildCheckout
    }

    public static func resolve(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        saved: URL? = nil,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        buildCheckout: URL? = Workspace.buildCheckout
    ) throws -> (workspace: Workspace, source: Source) {
        if let explicit, !explicit.isEmpty {
            return (Workspace(root: url(explicit, relativeTo: workingDirectory)), .explicit)
        }
        if let value = environment[environmentKey], !value.isEmpty {
            return (Workspace(root: url(value, relativeTo: workingDirectory)), .environment)
        }
        if let saved, isLeviathanRoot(saved) {
            return (Workspace(root: saved), .saved)
        }
        var directory = workingDirectory.standardizedFileURL
        while true {
            if isLeviathanRoot(directory) { return (Workspace(root: directory), .workingDirectory) }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        if let buildCheckout, isLeviathanRoot(buildCheckout) {
            return (Workspace(root: buildCheckout), .buildCheckout)
        }
        throw LeviathanFailure(
            "no Leviathan package root found from \(workingDirectory.path)",
            hint: "run inside the Leviathan checkout, pass --root, or set \(environmentKey)", code: LeviathanFailure.ExitCode.noInput)
    }

    /// The checkout this file was compiled from: Sources/LeviathanCore/Workspace/ is three
    /// levels below the root.
    public static let buildCheckout: URL? = {
        let file = URL(fileURLWithPath: #filePath)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) ? root : nil
    }()

    /// A directory whose Package.swift declares the Leviathan package.
    public static func isLeviathanRoot(_ directory: URL) -> Bool {
        let manifest = directory.appendingPathComponent("Package.swift")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return false }
        return text.contains("name: \"Leviathan\"")
    }

    static func url(_ path: String, relativeTo base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
    }

    // MARK: Paths

    public var providersFile: URL { root.appendingPathComponent("providers.json") }
    public var worksDirectory: URL { root.appendingPathComponent("works", isDirectory: true) }

    public func workDirectory(_ id: String) -> URL {
        worksDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// Where scoped data lives: works/<id>/ inside a work, else the root.
    public var dataRoot: URL { work.map(workDirectory) ?? root }

    public var promptsDirectory: URL { dataRoot.appendingPathComponent("prompts", isDirectory: true) }
    /// Model definitions: shared at the root.
    public var datasetDirectory: URL { root.appendingPathComponent("dataset", isDirectory: true) }
    public var catalogueDirectory: URL { root.appendingPathComponent("catalogue", isDirectory: true) }
    public var reportsDirectory: URL { dataRoot.appendingPathComponent("reports", isDirectory: true) }

    public func promptSetDirectory(_ set: String) -> URL {
        promptsDirectory.appendingPathComponent(set, isDirectory: true)
    }

    /// Where a model's definition lives: dataset/<company>/<model>/ at the root.
    public func modelDirectory(_ ref: ModelRef) -> URL {
        datasetDirectory.appendingPathComponent(ref.company, isDirectory: true).appendingPathComponent(ref.model, isDirectory: true)
    }

    /// Where a model's samples and Threads live: under the work when scoped.
    public func dataDirectory(_ ref: ModelRef) -> URL {
        dataRoot.appendingPathComponent("dataset", isDirectory: true).appendingPathComponent(ref.company, isDirectory: true)
            .appendingPathComponent(ref.model, isDirectory: true)
    }

    public func modelFile(_ ref: ModelRef) -> URL { modelDirectory(ref).appendingPathComponent("model.json") }
    public func transcriptsFile(_ ref: ModelRef) -> URL { dataDirectory(ref).appendingPathComponent("transcripts.jsonl") }

    public func threadDirectory(_ ref: ModelRef, set: String) -> URL {
        dataDirectory(ref).appendingPathComponent("threads", isDirectory: true).appendingPathComponent(set, isDirectory: true)
    }

    public func passagesDirectory(_ ref: ModelRef, set: String) -> URL {
        threadDirectory(ref, set: set).appendingPathComponent("passages", isDirectory: true)
    }

    public func passageFile(_ ref: ModelRef, set: String, prompt: String) -> URL {
        passagesDirectory(ref, set: set).appendingPathComponent("\(prompt).json")
    }

    public func editsFile(_ ref: ModelRef, set: String) -> URL {
        threadDirectory(ref, set: set).appendingPathComponent("edits.jsonl")
    }

    public func exportDirectory(_ ref: ModelRef, set: String) -> URL {
        threadDirectory(ref, set: set).appendingPathComponent("thread", isDirectory: true)
    }

    public var propertiesFile: URL { catalogueDirectory.appendingPathComponent("PROPERTIES.md") }

    /// catalogue/evidence/<slug> at the root; works/<id>/evidence/<slug> inside a work, so no
    /// measurement of private text lands in the committable catalogue.
    public func evidenceDirectory(slug: String) -> URL {
        (work == nil ? catalogueDirectory : dataRoot).appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    /// The path relative to the root, for messages and records.
    public func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
