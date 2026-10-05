//
//  Study.swift
//  LeviathanCore
//
//  WHAT: Turns a work's passages into a prompt set that asks models something about them.
//        continue  the request the story's app made for passage n, rebuilt: how would each
//                  model have written it? Your passage sits beside their answers.
//        revise    your passage, with a request to edit it lightly: which of your words does
//                  no model touch, and what do they change the rest to?
//        recall    the start of your passage, with a request to go on exactly as written:
//                  does a model reproduce the rest? If it does, it has seen your text.
//  OUT:  works/<id>/prompts/<kind>/p<nnn>.json, one per passage, with your text as the
//        prompt's reference: the baseline for revise and recall, a comparison for continue.
//  PIN:  continue rebuilds the request the way Gita's StoryPrompts.request does: the preamble,
//        the characters, the mark's directive (or the dream directive), the last six passages
//        as turns, the opening pinned when it has scrolled out, then the mark. What Gita adds
//        on a device (the reader's profile, a dream's catalogue entry) is not in the export,
//        so it is left out and the prompt's note says so.
//

import Foundation

public enum StudyKind: String, Codable, Sendable, CaseIterable {
    case `continue`, revise, recall

    public var summary: String {
        switch self {
        case .continue: return "How each model would have written the passage, from the same request your story's app sent."
        case .revise: return "Your passage, edited lightly by each model: which words they keep and what they change."
        case .recall: return "The start of your passage: does a model go on with your exact words?"
        }
    }
}

public struct StudySummary: Codable, Sendable {
    public var work: String
    public var kind: StudyKind
    public var set: String
    public var prompts: [String]
    public var skipped: [String]
}

public enum Study {
    public static let historyWindow = 6
    public static let openingPinLength = 1200
    public static let dreamUserTurn = "(dream) The reader is away. Let the story dream in the margin."
    static let fallbackPreamble = """
        You are the author of a serialized literary story told in short passages. Write warm, precise, sensory prose in third person, \
        present tense. Write ONLY story prose: no titles, headings, notes, or questions to the reader. Each reply is 2–4 paragraphs and \
        ends on a line that quietly invites the story onward. The story never concludes.
        """
    static let fallbackDreamDirective = """
        DREAM: The reader has been away, and the story has dreamt. Write a single short passage (1–2 paragraphs) of dream-marginalia: \
        an image, omen, or sideways memory that drifts from the story so far without advancing the plot. Keep it brief, strange, and \
        tender. It reads like a note found in the margin come morning.
        """

    /// Writes the study's prompt set; returns what it wrote.
    public static func make(_ kind: StudyKind, work id: String, from first: Int = 0, limit: Int = 12, origin: PassageOrigin? = nil,
                            in workspace: Workspace) throws -> StudySummary {
        let scoped = workspace.scoped(to: id)
        _ = try WorkStore.load(id, in: workspace)
        let passages = try WorkStore.passages(id, in: workspace)
        guard !passages.isEmpty else {
            throw LeviathanFailure("work \(id) has no passages yet", hint: "leviathan works import --work \(id) --season <file>",
                                   code: LeviathanFailure.ExitCode.noInput)
        }
        let narrative = WorkStore.narrative(id, in: workspace)
        if kind == .continue, narrative == nil {
            throw LeviathanFailure("the continue study rebuilds your app's requests, which needs the season's Narrative.json",
                                   hint: "leviathan works import --work \(id) --narrative <Narrative.json>", code: LeviathanFailure.ExitCode.noInput)
        }
        let chosen = passages.filter { $0.index >= first && (origin == nil || $0.origin == origin) }.prefix(max(0, limit))
        let set = kind.rawValue
        try FileManager.default.createDirectory(at: scoped.promptSetDirectory(set), withIntermediateDirectories: true)
        try PromptStore.saveSettings(PromptSetSettings(description: kind.summary), set: set, in: scoped)
        var written: [String] = []
        var skipped: [String] = []
        for passage in chosen {
            let promptID = String(format: "p%03d", passage.index)
            let file: PromptFile?
            switch kind {
            case .continue: file = continuePrompt(passage, passages: passages, narrative: narrative!)
            case .revise: file = revisePrompt(passage)
            case .recall: file = recallPrompt(passage)
            }
            guard let file else {
                skipped.append(promptID)
                continue
            }
            _ = try PromptStore.add(set: set, id: promptID, file: file, in: scoped)
            written.append(promptID)
        }
        return StudySummary(work: id, kind: kind, set: set, prompts: written, skipped: skipped)
    }

    // MARK: continue

    static func userTurn(_ passage: WorkPassage, narrative: Narrative) -> String {
        if passage.isDream { return dreamUserTurn }
        if let tool = passage.tool, let excerpt = passage.excerpt { return "(\(tool)) Continue from the marked passage: \"\(excerpt)\"" }
        return narrative.openingUserTurn ?? "Begin Season 1."
    }

    static func continuePrompt(_ passage: WorkPassage, passages: [WorkPassage], narrative: Narrative) -> PromptFile {
        var system = narrative.authorPreamble.isEmpty ? fallbackPreamble : narrative.authorPreamble
        if let characters = narrative.characters, !characters.isEmpty {
            system += "\n\nCHARACTERS:\n" + characters.map { "- \($0.name) (\($0.role)): \($0.essence)" }.joined(separator: "\n")
        }
        if passage.isDream {
            let directive = narrative.dreamDirective ?? ""
            system += "\n\n" + (directive.isEmpty ? fallbackDreamDirective : directive)
        } else if let tool = passage.tool, let directive = narrative.toolDirectives?[tool], !directive.isEmpty {
            system += "\n\n" + directive
        }
        let history = passages.filter { $0.source == passage.source && $0.index < passage.index && !$0.text.isEmpty }
        let window = history.suffix(historyWindow)
        if let opening = history.first, !window.contains(where: { $0.id == opening.id }) {
            system += "\n\nSTORY OPENING (for continuity): \(opening.text.prefix(openingPinLength))"
        }
        var messages = [ChatMessage(role: "system", content: system)]
        for earlier in window {
            messages.append(ChatMessage(role: "user", content: userTurn(earlier, narrative: narrative)))
            messages.append(ChatMessage(role: "assistant", content: earlier.text))
        }
        messages.append(ChatMessage(role: "user", content: userTurn(passage, narrative: narrative)))
        return PromptFile(messages: messages,
                          reference: PromptReference(text: passage.text, role: .comparison, passageID: passage.id, origin: passage.origin.rawValue),
                          note: "Passage \(passage.index) as your app asked for it" + (passage.isDream ? "; a dream's catalogue entry is not in the export" : "")
                              + "; the reader's profile is left out.")
    }

    // MARK: revise

    static func revisePrompt(_ passage: WorkPassage) -> PromptFile {
        PromptFile(messages: [
            ChatMessage(role: "system", content: "You are a careful line editor of literary fiction."),
            ChatMessage(role: "user", content: """
                Edit this passage lightly. Fix only what needs fixing, and keep the author's voice, wording and paragraph breaks wherever \
                they already work. Reply with the edited passage only, with no notes or headings.

                PASSAGE:
                \(passage.text)
                """),
        ], reference: PromptReference(text: passage.text, role: .baseline, passageID: passage.id, origin: passage.origin.rawValue),
        note: "Passage \(passage.index), edited lightly.")
    }

    // MARK: recall

    /// The passage cut near 40% of its length at a sentence end; nil when it is too short to cut.
    static func split(_ text: String) -> (start: String, rest: String)? {
        let target = Double(text.count) * 0.4
        var ends: [String.Index] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]) {
                var after = next
                while after < text.endIndex, "\"'”’)".contains(text[after]) { after = text.index(after: after) }
                if after < text.endIndex, text[after].isWhitespace { ends.append(after) }
            }
            index = next
        }
        let candidates = ends.filter { text.distance(from: text.startIndex, to: $0) > 20 && text.distance(from: $0, to: text.endIndex) > 20 }
        guard let cut = candidates.min(by: {
            abs(Double(text.distance(from: text.startIndex, to: $0)) - target) < abs(Double(text.distance(from: text.startIndex, to: $1)) - target)
        }) else { return nil }
        let start = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.split(whereSeparator: \.isWhitespace).count < 8 ? nil : (start, rest)
    }

    static func recallPrompt(_ passage: WorkPassage) -> PromptFile? {
        guard let (start, rest) = split(passage.text) else { return nil }
        return PromptFile(messages: [
            ChatMessage(role: "user", content: """
                Here is the beginning of a passage from a serialized story. Continue it exactly as it was originally written, word for \
                word. Reply with the continuation only.

                BEGINNING:
                \(start)
                """),
        ], reference: PromptReference(text: rest, role: .baseline, passageID: passage.id, origin: passage.origin.rawValue),
        note: "Passage \(passage.index): its first sentences given, the rest to recall.")
    }
}
