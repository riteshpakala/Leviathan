//
//  Resolution.swift
//  LeviathanCore
//
//  WHAT: Your choice for each area of a passage (a variant a sample wrote, or your own words),
//        and the document it resolves to, piece by piece with the weight of each piece's
//        content words.
//  PIN:  An area left alone keeps the baseline's wording. A piece's weight is 1 for locked text
//        and for your own words, and the share of aligned samples that wrote the chosen wording
//        for an area. A resolution names the baseline record it was made on; later passages for
//        the prompt are built on that record, so the areas you chose among stay put as samples
//        are added. A resolution with no choices just pins a baseline.
//

import Foundation

public enum PieceBasis: String, Codable, Sendable {
    /// Text every aligned sample kept.
    case locked
    /// An area, at the wording chosen for it (the baseline's unless you chose another).
    case area
    /// Your own words.
    case edit
}

public struct Piece: Codable, Sendable, Hashable {
    public var text: String
    public var basis: PieceBasis
    /// The weight of the content words in this piece.
    public var weight: Double
    /// The baseline tokens this piece reproduces verbatim, if it does.
    public var baseline: IndexRange?
    public var area: Int?
}

public struct Choice: Codable, Sendable, Hashable {
    /// The area's baseline tokens, which identify it across rebuilds.
    public var tokens: IndexRange
    /// An index into the area's variants.
    public var variant: Int?
    /// Your own words; the area's edge whitespace is kept around them.
    public var text: String?

    public init(tokens: IndexRange, variant: Int? = nil, text: String? = nil) {
        self.tokens = tokens
        self.variant = variant
        self.text = text
    }
}

public struct Resolution: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var set: String
    public var model: String
    public var promptID: String
    public var promptSHA: String
    public var baselineRecordID: String
    public var passageVersion: Int
    public var choices: [Choice]
    public var pieces: [Piece]
    /// The resolved document.
    public var text: String
    /// The baseline response it was resolved from.
    public var original: String
    public var messages: [ChatMessage]
    public var note: String?

    public var edited: Bool { text != original }
}

public enum Resolver {

    /// The pieces of a passage under a set of choices. Choices naming no current area are
    /// returned as unmatched and left out.
    public static func pieces(_ passage: Passage, choices: [Choice]) throws -> (pieces: [Piece], unmatched: [Choice]) {
        var byRange: [IndexRange: Choice] = [:]
        for choice in choices { byRange[choice.tokens] = choice }
        var used = Set<IndexRange>()
        var pieces: [Piece] = []
        for segment in passage.segments {
            switch segment.kind {
            case .locked:
                pieces.append(Piece(text: segment.text, basis: .locked, weight: 1, baseline: segment.tokens, area: nil))
            case .area:
                guard let id = segment.area, let area = passage.area(id) else { continue }
                let choice = byRange[area.tokens]
                if choice != nil { used.insert(area.tokens) }
                if let typed = choice?.text {
                    pieces.append(Piece(text: wrap(typed, in: area.baselineText), basis: .edit, weight: 1, baseline: nil, area: id))
                } else if let index = choice?.variant {
                    guard area.variants.indices.contains(index) else {
                        throw LeviathanFailure("area \(id) has no variant \(index) (it has \(area.variants.count))", code: LeviathanFailure.ExitCode.usage)
                    }
                    let variant = area.variants[index]
                    pieces.append(Piece(text: variant.text, basis: .area, weight: variant.share,
                                        baseline: variant.isBaseline ? area.tokens : nil, area: id))
                } else {
                    let variant = area.baselineVariant
                    pieces.append(Piece(text: area.baselineText, basis: .area, weight: variant?.share ?? 1, baseline: area.tokens, area: id))
                }
            }
        }
        trimEnds(&pieces)
        return (pieces, choices.filter { !used.contains($0.tokens) })
    }

    public static func resolve(_ passage: Passage, choices: [Choice], note: String? = nil, now: Date = Date()) throws -> Resolution {
        let (pieces, unmatched) = try self.pieces(passage, choices: choices)
        guard unmatched.isEmpty else {
            throw LeviathanFailure("no area at tokens \(unmatched.map { "\($0.tokens.lower)..<\($0.tokens.upper)" }.joined(separator: ", "))",
                                   hint: "derive again and pick from the current areas", code: LeviathanFailure.ExitCode.usage)
        }
        let text = pieces.map(\.text).joined()
        guard ContentHash.canonical(text) == text else {
            throw LeviathanFailure("the edited text is not in canonical form", hint: "check the whitespace around your own words",
                                   code: LeviathanFailure.ExitCode.usage)
        }
        guard !text.isEmpty else { throw LeviathanFailure("the edit leaves the document empty", code: LeviathanFailure.ExitCode.usage) }
        return Resolution(
            id: UUID().uuidString.lowercased(), createdAt: now, set: passage.set, model: passage.model, promptID: passage.promptID,
            promptSHA: passage.promptSHA, baselineRecordID: passage.baselineRecordID, passageVersion: passage.version,
            choices: choices.sorted { $0.tokens < $1.tokens }, pieces: pieces, text: text, original: passage.text,
            messages: passage.messages, note: note)
    }

    /// Your words with the area's edge whitespace around them. Empty words close the gap to a
    /// single space.
    public static func wrap(_ typed: String, in wording: String) -> String {
        let inline: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let leading = String(wording.prefix(while: inline))
        let trailing = String(wording.reversed().prefix(while: inline).reversed())
        let words = clean(typed)
        if words.isEmpty { return leading.isEmpty || trailing.isEmpty ? leading + trailing : " " }
        return leading + words + trailing
    }

    /// NFC, `\n` line ends, no trailing whitespace on any line, none at either end.
    static func clean(_ text: String) -> String {
        ContentHash.canonical(text)
    }

    /// Whitespace at the very start or end of the document is dropped, as canonical form does.
    static func trimEnds(_ pieces: inout [Piece]) {
        if let first = pieces.indices.first {
            let trimmed = String(pieces[first].text.drop(while: \.isWhitespace))
            if trimmed != pieces[first].text, pieces[first].basis == .edit { pieces[first].text = trimmed }
        }
        if let last = pieces.indices.last {
            var text = pieces[last].text
            while text.last?.isWhitespace == true { text.removeLast() }
            if text != pieces[last].text, pieces[last].basis == .edit { pieces[last].text = text }
        }
        pieces.removeAll { $0.text.isEmpty && $0.basis == .edit }
    }
}

public enum EditStore {
    public static func all(_ workspace: Workspace, ref: ModelRef, set: String) throws -> [Resolution] {
        let url = workspace.editsFile(ref, set: set)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONCoding.readLines(Resolution.self, from: url)
        } catch {
            throw LeviathanFailure("\(workspace.relative(url)) is malformed: \(error)", code: LeviathanFailure.ExitCode.data)
        }
    }

    /// The latest resolution for a prompt as it is now (its hash must match).
    public static func latest(_ resolutions: [Resolution], promptID: String, promptSHA: String) -> Resolution? {
        resolutions.last { $0.promptID == promptID && $0.promptSHA == promptSHA }
    }

    public static func append(_ resolution: Resolution, workspace: Workspace, ref: ModelRef) throws {
        let writer = try JSONLWriter(url: workspace.editsFile(ref, set: resolution.set))
        defer { writer.close() }
        try writer.append(resolution)
    }
}
