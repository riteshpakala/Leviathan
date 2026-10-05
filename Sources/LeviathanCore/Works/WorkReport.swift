//
//  WorkReport.swift
//  LeviathanCore
//
//  WHAT: What the models' answers show about a work, written to works/<id>/reports/<date>.md.
//        revise    per passage and model: how much of your wording survives a light edit, and
//                  the words they change most, with what they change them to.
//        recall    per passage and model: how much of your passage's rest a model reproduces.
//        continue  per passage and model: how much of your passage's vocabulary a model's own
//                  version shares, and the phrases models reach for again and again.
//  PIN:  Built from the passages derive builds: nothing here is new measurement, only a reading
//        of it. The report quotes your text, so it stays in the work's git-ignored folder.
//

import Foundation

/// One model's answers to one study of a work.
public struct WorkThread: Sendable, Hashable, Identifiable {
    public var ref: ModelRef
    public var set: String
    public var samples: Int
    public var id: String { "\(ref)|\(set)" }
}

public enum WorkReport {
    /// Thresholds for recall's reading of content words reproduced.
    public static let reproduces = 0.6
    public static let partly = 0.25

    /// Every model and study with samples in the work.
    public static func threads(work id: String, in workspace: Workspace) -> [WorkThread] {
        let scoped = workspace.scoped(to: id)
        let dataset = scoped.dataRoot.appendingPathComponent("dataset", isDirectory: true)
        let manager = FileManager.default
        var threads: [WorkThread] = []
        for company in ((try? manager.contentsOfDirectory(atPath: dataset.path)) ?? []).sorted() where !company.hasPrefix(".") {
            let companyURL = dataset.appendingPathComponent(company, isDirectory: true)
            for model in ((try? manager.contentsOfDirectory(atPath: companyURL.path)) ?? []).sorted() where !model.hasPrefix(".") {
                let ref = ModelRef(company: company, model: model)
                let records = (try? TranscriptStore.read(scoped.transcriptsFile(ref)).records) ?? []
                for (set, rows) in Dictionary(grouping: records, by: \.pack).sorted(by: { $0.key < $1.key }) {
                    threads.append(WorkThread(ref: ref, set: set, samples: rows.count))
                }
            }
        }
        return threads
    }

    public static func write(work id: String, in workspace: Workspace, now: Date = Date()) throws -> URL {
        let text = try render(work: id, in: workspace, now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = workspace.scoped(to: id).reportsDirectory.appendingPathComponent("\(formatter.string(from: now)).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    struct Loaded {
        var thread: WorkThread
        var source: ThreadSource
        var passages: [(prompt: Prompt, passage: Passage)]
    }

    public static func render(work id: String, in workspace: Workspace, now: Date = Date()) throws -> String {
        let work = try WorkStore.load(id, in: workspace)
        let scoped = workspace.scoped(to: id)
        var loaded: [Loaded] = []
        for thread in threads(work: id, in: workspace) {
            guard (try? ModelStore.load(thread.ref, in: scoped)) != nil, let source = try? ThreadSource.load(scoped, ref: thread.ref, set: thread.set) else { continue }
            let passages = source.set.prompts.compactMap { prompt in (try? source.passage(for: prompt)).flatMap { $0 }.map { (prompt, $0) } }
            loaded.append(Loaded(thread: thread, source: source, passages: passages))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var lines = ["# \(work.title): what the models show", "",
                     "\(formatter.string(from: now)). Models: \(Set(loaded.map(\.thread.ref.description)).sorted().joined(separator: ", ")). "
                         + "This report quotes your text; it stays in works/\(id)/, which git ignores.", ""]
        if loaded.isEmpty {
            lines.append("No study has samples yet. Make one (leviathan works study --work \(id) --kind revise), then harvest it on a cleared host.")
        }
        let byKind = Dictionary(grouping: loaded) { StudyKind(rawValue: $0.thread.set) }
        if let rows = byKind[.revise] { lines += revise(rows) }
        if let rows = byKind[.recall] { lines += recall(rows) }
        if let rows = byKind[.continue] { lines += continuation(rows) }
        for (kind, rows) in byKind where kind == nil {
            lines += ["## Other sets", ""] + rows.map { "- \($0.thread.ref) on \($0.thread.set): \($0.thread.samples) samples" } + [""]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Readings

    /// Mean share of your content words each answer kept; an answer too different to align keeps none.
    static func contentKept(_ passage: Passage) -> (mean: Double?, samples: Int) {
        let shares = passage.samples.compactMap { sample -> Double? in
            switch sample.status {
            case .aligned: return Measurements.kept(passage, sample).content
            case .divergent: return 0
            case .baseline, .setAside: return nil
            }
        }
        return (shares.isEmpty ? nil : shares.reduce(0, +) / Double(shares.count), shares.count)
    }

    static func revise(_ rows: [Loaded]) -> [String] {
        var lines = ["## Revise: what a light edit keeps", "",
                     "Your passage is the baseline. *Kept* is the mean share of your content words an edit left as they were; *locked* is the share of your words every edit kept.", "",
                     "| Passage | Model | Edits | Kept | Locked |", "| --- | --- | --- | --- | --- |"]
        var changes: [String] = []
        for row in rows {
            for (prompt, passage) in row.passages {
                let kept = contentKept(passage)
                lines.append("| \(prompt.id) | \(row.thread.ref) | \(kept.samples) | \(percent(kept.mean)) | \(percent(passage.measures.lockedShare)) |")
                let changed = passage.areas.filter(\.holdsContent).compactMap { area -> (Double, String)? in
                    let changedShare = 1 - (area.baselineVariant?.share ?? 0)
                    let others = area.variants.filter { !$0.isBaseline }.sorted { $0.share > $1.share }
                    guard !others.isEmpty, changedShare > 0 else { return nil }
                    let to = others.prefix(3).map { "\"\(cell($0.text))\"" }.joined(separator: ", ") + (others.count > 3 ? ", …" : "")
                    return (changedShare, "\"\(cell(area.baselineText))\" changed in \(percent(changedShare)) of edits, to \(to)")
                }.sorted { $0.0 > $1.0 }.prefix(5)
                if !changed.isEmpty {
                    changes.append("- **\(prompt.id), \(row.thread.ref)**: " + changed.map(\.1).joined(separator: "; "))
                }
            }
        }
        if !changes.isEmpty { lines += ["", "The wording edits change most often, and what they change it to (commonest first):", ""] + changes }
        return lines + [""]
    }

    static func recall(_ rows: [Loaded]) -> [String] {
        var lines = ["## Recall: does a model know your text?", "",
                     "Each model was given the start of a passage and asked to go on as written. *Reproduced* is the mean share of the rest's content words it wrote as you did. "
                         + "At \(percent(reproduces)) or more it reproduces your text, which means it has seen it; under \(percent(partly)) there is no sign it has.", "",
                     "| Passage | Model | Answers | Reproduced | Reading |", "| --- | --- | --- | --- | --- |"]
        for row in rows {
            for (prompt, passage) in row.passages {
                let kept = contentKept(passage)
                let reading = kept.mean.map { $0 >= reproduces ? "reproduces it" : $0 >= partly ? "partly" : "no sign" } ?? "–"
                lines.append("| \(prompt.id) | \(row.thread.ref) | \(kept.samples) | \(percent(kept.mean)) | \(reading) |")
            }
        }
        return lines + [""]
    }

    static func continuation(_ rows: [Loaded]) -> [String] {
        var lines = ["## Continue: how the models would have written it", "",
                     "Each model got the request your app sent for the passage. *Shared* is the share of your passage's content words its own version also uses; "
                         + "*locked* is the share of its own wording that held across its samples.", "",
                     "| Passage | Model | Samples | Shared | Locked |", "| --- | --- | --- | --- | --- |"]
        var grams: [String: (models: Set<String>, prompts: Set<String>)] = [:]
        var yours = Set<String>()
        for row in rows {
            for (prompt, passage) in row.passages {
                let reference = prompt.reference?.text ?? ""
                let mine = Set(contentWords(reference))
                let theirs = Set(contentWords(passage.text))
                let shared = mine.isEmpty ? nil : Double(mine.intersection(theirs).count) / Double(mine.count)
                lines.append("| \(prompt.id) | \(row.thread.ref) | \(passage.samples.count) | \(percent(shared)) | \(percent(passage.measures.lockedShare)) |")
                for gram in fourGrams(passage.text) {
                    grams[gram, default: ([], [])].models.insert(row.thread.ref.description)
                    grams[gram, default: ([], [])].prompts.insert(prompt.id)
                }
                yours.formUnion(fourGrams(reference))
            }
        }
        let stock = grams.filter { $0.value.models.count >= 2 || $0.value.prompts.count >= 3 }
            .sorted { ($0.value.models.count, $0.value.prompts.count, $1.key) > ($1.value.models.count, $1.value.prompts.count, $0.key) }.prefix(15)
        if !stock.isEmpty {
            lines += ["", "Phrases the models reach for again and again (in two or more models, or three or more passages):", "",
                      "| Phrase | Models | Passages | Also in your text |", "| --- | --- | --- | --- |"]
            lines += stock.map { "| \(cell($0.key)) | \($0.value.models.count) | \($0.value.prompts.count) | \(yours.contains($0.key) ? "yes" : "") |" }
        }
        return lines + [""]
    }

    // MARK: Words

    static func words(_ text: String) -> [Token] {
        Tokenizer.tokenize(text).tokens.filter(\.isWord)
    }

    static func contentWords(_ text: String) -> [String] {
        words(text).filter { $0.role == .content }.map { $0.text.lowercased() }
    }

    /// Four-word runs holding at least two content words.
    static func fourGrams(_ text: String) -> Set<String> {
        let list = words(text)
        guard list.count >= 4 else { return [] }
        var grams = Set<String>()
        for i in 0...(list.count - 4) {
            let window = list[i..<(i + 4)]
            guard window.filter({ $0.role == .content }).count >= 2 else { continue }
            grams.insert(window.map { $0.text.lowercased() }.joined(separator: " "))
        }
        return grams
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
    }

    static func cell(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
