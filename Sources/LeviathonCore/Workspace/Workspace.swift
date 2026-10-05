//
//  Workspace.swift
//  LeviathonCore
//
//  WHAT: The package root everything lives under, and every path Leviathon reads or writes.
//  IN:   The root resolves from an explicit path, then $LEVIATHON_ROOT, then a folder the app
//        saved, then the nearest ancestor of the working directory whose Package.swift names
//        Leviathon, then the checkout the binary was built from (a launch from Xcode runs in
//        DerivedData, so the working directory does not lead back here).
//

import Foundation

public struct Workspace: Sendable, Hashable {
    public let root: URL

    public static let environmentKey = "LEVIATHON_ROOT"

    public init(root: URL) {
        self.root = root.standardizedFileURL
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
        if let saved, isLeviathonRoot(saved) {
            return (Workspace(root: saved), .saved)
        }
        var directory = workingDirectory.standardizedFileURL
        while true {
            if isLeviathonRoot(directory) { return (Workspace(root: directory), .workingDirectory) }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        if let buildCheckout, isLeviathonRoot(buildCheckout) {
            return (Workspace(root: buildCheckout), .buildCheckout)
        }
        throw LeviathonFailure(
            "no Leviathon package root found from \(workingDirectory.path)",
            hint: "run inside the Leviathon checkout, pass --root, or set \(environmentKey)", code: LeviathonFailure.ExitCode.noInput)
    }

    /// The checkout this file was compiled from: Sources/LeviathonCore/Workspace/ is three
    /// levels below the root.
    public static let buildCheckout: URL? = {
        let file = URL(fileURLWithPath: #filePath)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) ? root : nil
    }()

    /// A directory whose Package.swift declares the Leviathon package.
    public static func isLeviathonRoot(_ directory: URL) -> Bool {
        let manifest = directory.appendingPathComponent("Package.swift")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return false }
        return text.contains("name: \"Leviathon\"")
    }

    static func url(_ path: String, relativeTo base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
    }

    // MARK: Paths

    public var providersFile: URL { root.appendingPathComponent("providers.json") }
    public var promptsDirectory: URL { root.appendingPathComponent("prompts", isDirectory: true) }
    public var datasetDirectory: URL { root.appendingPathComponent("dataset", isDirectory: true) }
    public var catalogueDirectory: URL { root.appendingPathComponent("catalogue", isDirectory: true) }

    public func promptSetDirectory(_ set: String) -> URL {
        promptsDirectory.appendingPathComponent(set, isDirectory: true)
    }

    public func modelDirectory(_ ref: ModelRef) -> URL {
        datasetDirectory.appendingPathComponent(ref.company, isDirectory: true).appendingPathComponent(ref.model, isDirectory: true)
    }

    public func modelFile(_ ref: ModelRef) -> URL { modelDirectory(ref).appendingPathComponent("model.json") }
    public func transcriptsFile(_ ref: ModelRef) -> URL { modelDirectory(ref).appendingPathComponent("transcripts.jsonl") }

    public func threadDirectory(_ ref: ModelRef, set: String) -> URL {
        modelDirectory(ref).appendingPathComponent("threads", isDirectory: true).appendingPathComponent(set, isDirectory: true)
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

    public func evidenceDirectory(slug: String) -> URL {
        catalogueDirectory.appendingPathComponent("evidence", isDirectory: true).appendingPathComponent(slug, isDirectory: true)
    }

    /// The path relative to the root, for messages and records.
    public func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
