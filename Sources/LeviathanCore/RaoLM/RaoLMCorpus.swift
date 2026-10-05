//
//  RaoLMCorpus.swift
//  LeviathanCore
//
//  WHAT: The records of a RaoLM corpus and snapshot, mirrored field for field so RaoLM decodes
//        what Leviathan writes: documents with their partitions and facts, the corpus manifest,
//        and the snapshot `raolm train --corpus` reads.
//  PIN:  Mirrors RaoLM `Sources/RaoLMCore/Corpus/CorpusModels.swift` and
//        `Sources/RaoLMCore/Snapshot/CorpusSnapshot.swift`. RaoLM's document and fact kinds are
//        closed enums there; here they are strings, checked against `DocumentKinds.raolm`.
//

import Foundation

public enum DocumentKinds {
    /// Every `DocumentKind` RaoLM decodes, as of RaoLM 37d9380.
    public static let raolm: Set<String> = [
        "landmark", "biography", "expedition", "council", "recipe",
        "reading", "conversation", "digest",
        "session", "release", "postmortem", "review",
        "catalogue", "attribution", "caption",
        "minutes", "notes", "newsletter", "journal", "column", "guide", "transcript", "letter",
        "runbook", "standup", "ticket", "decision", "audit", "report", "changelog",
        "lot", "script", "schedule", "announcement", "ledger",
    ]

    public static let harvested = "transcript"
}

/// A question about a fact and the stem it should rewrite to (RaoLM `FactQuestion`).
public struct FactQuestion: Codable, Sendable, Hashable {
    public var text: String
    public var stem: String
}

/// One fact a document states, located inside its partition (RaoLM `Fact`). Offsets are UTF-8
/// byte offsets into the partition text; `answer` begins with the space before the value.
public struct Fact: Codable, Sendable, Hashable {
    public var id: String
    public var kind: String
    public var documentID: String
    public var partitionIndex: Int
    public var subject: String
    public var prompt: String
    public var answer: String
    public var sentence: String
    public var sentenceStart: Int
    public var contextStart: Int
    public var answerStart: Int
    public var answerEnd: Int
    public var paraphrases: [String]
    public var negativePrompt: String
    public var questions: [FactQuestion]? = nil
    public var negativeQuestions: [FactQuestion]? = nil

    public init(id: String, kind: String, documentID: String, partitionIndex: Int, subject: String, prompt: String, answer: String,
                sentence: String, sentenceStart: Int, contextStart: Int, answerStart: Int, answerEnd: Int, paraphrases: [String] = [],
                negativePrompt: String = "", questions: [FactQuestion]? = nil, negativeQuestions: [FactQuestion]? = nil) {
        self.id = id
        self.kind = kind
        self.documentID = documentID
        self.partitionIndex = partitionIndex
        self.subject = subject
        self.prompt = prompt
        self.answer = answer
        self.sentence = sentence
        self.sentenceStart = sentenceStart
        self.contextStart = contextStart
        self.answerStart = answerStart
        self.answerEnd = answerEnd
        self.paraphrases = paraphrases
        self.negativePrompt = negativePrompt
        self.questions = questions
        self.negativeQuestions = negativeQuestions
    }
}

public struct CorpusPartition: Codable, Sendable, Equatable {
    public var index: Int
    public var text: String
    public var textSHA256: String
    public var url: String

    public init(index: Int, text: String, slug: String, documentID: String) {
        self.index = index
        self.text = text
        textSHA256 = ContentHash.sha256Hex(text)
        url = DocumentID.partitionURL(slug: slug, documentID: documentID, index: index)
    }
}

public struct CorpusDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var subject: String
    public var partitions: [CorpusPartition]
    public var facts: [Fact]
    /// SHA-256 of the canonical text the id is derived from.
    public var textSHA256: String

    /// The partitions joined by a blank line.
    public var text: String { partitions.map(\.text).joined(separator: "\n\n") }

    /// A document from its text: canonical form, stable partitions, and the id and hashes RaoLM
    /// derives from them.
    public static func make(slug: String, name: String, kind: String, subject: String, text: String) -> CorpusDocument {
        let partitionTexts = TextChunker.stablePartitions(ContentHash.canonical(text))
        let documentText = partitionTexts.joined(separator: "\n\n")
        let canonical = ContentHash.canonical(documentText)
        let id = DocumentID.make(slug: slug, canonicalText: canonical)
        let partitions = partitionTexts.enumerated().map { CorpusPartition(index: $0.offset, text: $0.element, slug: slug, documentID: id) }
        return CorpusDocument(id: id, name: name, kind: kind, subject: subject, partitions: partitions, facts: [],
                              textSHA256: ContentHash.sha256Hex(canonical))
    }
}

public struct CorpusManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var slug: String
    public var generator: String
    public var generatorVersion: Int
    public var seed: UInt64
    public var documentCount: Int
    public var partitionCount: Int
    public var factCount: Int
    public var chunkMaxChars: Int
    public var chunkMinChars: Int
    public var documentIDs: [String]
    public var corpusHash: String

    public init(slug: String, generator: String, generatorVersion: Int, documents: [CorpusDocument]) {
        schemaVersion = 1
        self.slug = slug
        self.generator = generator
        self.generatorVersion = generatorVersion
        seed = 0
        documentCount = documents.count
        partitionCount = documents.reduce(0) { $0 + $1.partitions.count }
        factCount = documents.reduce(0) { $0 + $1.facts.count }
        chunkMaxChars = TextChunker.maxChars
        chunkMinChars = TextChunker.minChars
        documentIDs = documents.map(\.id)
        corpusHash = ContentHash.corpusHash(documents.flatMap { document in
            document.partitions.map { ContentHash.CorpusEntry(documentID: document.id, partitionIndex: $0.index, textSHA256: $0.textSHA256) }
        })
    }
}

public struct SnapshotPartition: Codable, Sendable, Equatable {
    public var index: Int
    public var text: String
    public var textSHA256: String
    public var url: String?
    public var threadPartitionID: String?
}

public struct SnapshotDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var ownerID: String
    public var groupID: String
    public var groupLabel: String
    /// Milliseconds since 1970.
    public var createdAt: Int64
    public var mediaType: String
    public var partitions: [SnapshotPartition]
}

/// The corpus as `raolm train --corpus` reads it.
public struct CorpusSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var corpusHash: String
    public var slug: String?
    public var source: String
    public var threadID: String?
    public var threadHost: String?
    public var threadGRPCPort: Int?
    public var owner: String
    public var group: String
    public var documentIDPrefix: String
    public var exportedAt: Date
    public var documentCount: Int
    public var partitionCount: Int
    /// Sorted by document id, as a Thread exports them.
    public var documents: [SnapshotDocument]

    public static let fileName = "snapshot.json"

    /// An offline snapshot of a corpus, as RaoLM's `CorpusSnapshot.offline` builds one.
    public init(corpus documents: [CorpusDocument], slug: String, owner: String, createdAt: [String: Int64], exportedAt: Date) {
        let group = "raolm-\(slug)"
        let sorted = documents.sorted { $0.id < $1.id }.map { document in
            SnapshotDocument(
                id: document.id, name: document.name, ownerID: owner, groupID: group, groupLabel: "Leviathan · \(slug)",
                createdAt: createdAt[document.id] ?? 0, mediaType: "text",
                partitions: document.partitions.map {
                    SnapshotPartition(index: $0.index, text: $0.text, textSHA256: $0.textSHA256, url: $0.url, threadPartitionID: nil)
                })
        }
        schemaVersion = 1
        self.documents = sorted
        self.slug = slug
        source = "offline"
        threadID = nil
        threadHost = nil
        threadGRPCPort = nil
        self.owner = owner
        self.group = group
        documentIDPrefix = DocumentID.prefix(slug: slug)
        self.exportedAt = exportedAt
        documentCount = sorted.count
        partitionCount = sorted.reduce(0) { $0 + $1.partitions.count }
        corpusHash = ContentHash.corpusHash(sorted.flatMap { document in
            document.partitions.map { ContentHash.CorpusEntry(documentID: document.id, partitionIndex: $0.index, textSHA256: $0.textSHA256) }
        })
    }
}
