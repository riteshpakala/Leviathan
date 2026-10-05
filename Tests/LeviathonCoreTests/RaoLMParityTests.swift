import Foundation
import Testing
@testable import LeviathonCore

@Suite("RaoLM parity: what Leviathon writes is what RaoLM would")
struct RaoLMParityTests {
    @Test("sha256, canonical form and the corpus hash match RaoLM's own test vectors")
    func vectors() {
        #expect(ContentHash.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHash.canonical("  a  \r\nb\t\n\n") == "a\nb")
        #expect(ContentHash.canonical("x") == "x")
        let entries = [
            ContentHash.CorpusEntry(documentID: "b", partitionIndex: 0, textSHA256: "1"),
            ContentHash.CorpusEntry(documentID: "a", partitionIndex: 1, textSHA256: "2"),
            ContentHash.CorpusEntry(documentID: "a", partitionIndex: 0, textSHA256: "3"),
        ]
        #expect(ContentHash.corpusHash(entries) == ContentHash.corpusHash(entries.reversed()))
        #expect(ContentHash.corpusHash(entries) == ContentHash.sha256Hex("a\t0\t3\na\t1\t2\nb\t0\t1\n"))
    }

    @Test("document ids, partition urls and handles follow RaoLM's rules")
    func ids() {
        let id = DocumentID.make(slug: "veldmar", canonicalText: "hello")
        #expect(DocumentID.isValid(id))
        #expect(!id.contains("/"))
        let url = DocumentID.partitionURL(slug: "veldmar", documentID: id, index: 3)
        #expect(URL(string: url)?.absoluteString == url)
        #expect(DocumentID.isValidHandle("raolm-demo"))
        #expect(!DocumentID.isValidHandle("Raolm"))
        #expect(!DocumentID.isValidHandle("a"))
    }

    @Test("the chunker behaves as RaoLM's tests require")
    func chunker() {
        let a = String(repeating: "alpha beta. ", count: 20).trimmingCharacters(in: .whitespaces)
        let b = String(repeating: "gamma delta. ", count: 20).trimmingCharacters(in: .whitespaces)
        #expect(TextChunker.chunk("\(a)\n\n\(b)\n") == [a, b])
        let sentence = "This sentence is about forty characters."
        let paragraph = Array(repeating: sentence, count: 40).joined(separator: " ")
        let chunks = TextChunker.chunk(paragraph, maxChars: 200, minChars: 10)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 200 && $0.hasSuffix(".") })
        #expect(chunks.joined(separator: " ") == paragraph)
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        #expect(TextChunker.chunk("tiny\n\n\(long)", maxChars: 600, minChars: 50) == ["tiny \(long)"])
        #expect(TextChunker.chunk("   \n\n  \n") == [])
    }

    @Test("documents RaoLM generated decode, re-encode byte for byte, and rebuild to the same ids and hashes")
    func fixtures() throws {
        let fixtures = try Support.fixtureDocuments()
        #expect(fixtures.count == 3)
        for (url, data) in fixtures {
            let document = try JSONCoding.decoder().decode(CorpusDocument.self, from: data)
            #expect(try JSONCoding.prettyEncoder().encode(document) == data, "re-encoding \(url.lastPathComponent)")
            #expect(TextChunker.chunk(document.text) == document.partitions.map(\.text))
            #expect(document.id == DocumentID.make(slug: "veldmar", canonicalText: ContentHash.canonical(document.text)))
            #expect(document.textSHA256 == ContentHash.sha256Hex(ContentHash.canonical(document.text)))
            for partition in document.partitions {
                #expect(partition.textSHA256 == ContentHash.sha256Hex(partition.text))
                #expect(partition.url == DocumentID.partitionURL(slug: "veldmar", documentID: document.id, index: partition.index))
            }
            let rebuilt = CorpusDocument.make(slug: "veldmar", name: document.name, kind: document.kind, subject: document.subject,
                                              text: document.text)
            #expect(rebuilt.id == document.id)
            #expect(rebuilt.partitions == document.partitions)
            #expect(rebuilt.textSHA256 == document.textSHA256)
            // RaoLM's facts sit at their offsets: the prompt ends where the answer starts.
            for fact in document.facts {
                let text = document.partitions[fact.partitionIndex].text
                #expect(Tokenizer.slice(text, fact.answerStart, fact.answerEnd) == fact.answer)
                #expect(Tokenizer.slice(text, fact.answerStart - fact.prompt.utf8.count, fact.answerStart) == fact.prompt)
            }
        }
    }

    @Test("roles match RaoLM's: function words, clitics and punctuation are form; names and numbers content")
    func roles() {
        #expect(TokenRoles.role(of: "They") == .form)
        #expect(TokenRoles.role(of: "asked") == .content)
        #expect(TokenRoles.role(of: ":") == .form)
        #expect(TokenRoles.role(of: "about") == .form)
        #expect(TokenRoles.role(of: "Milise") == .content)
        #expect(TokenRoles.role(of: "'s") == .form)
        #expect(TokenRoles.role(of: "56047") == .content)
        let tokens = Tokenizer.tokenize("They asked: what did I read about Milise Garard? Nashett's 56047.").tokens
        #expect(tokens.map(\.text) == ["They", "asked", ":", "what", "did", "I", "read", "about", "Milise", "Garard", "?", "Nashett", "'s", "56047", "."])
        #expect(tokens.map(\.role) == [.form, .content, .form, .form, .form, .form, .content, .form, .content, .content, .form, .content,
                                       .form, .content, .form])
    }

    @Test("the facts in RaoLM's synthetic corpus are cut where Leviathon cuts stems")
    func stemsMatchFacts() throws {
        let url = try Support.fixture("raolm-veldmar-0045262cc9e7f1b4ac79b485.json")
        let document = try JSONCoding.read(CorpusDocument.self, from: url)
        var matched = 0
        for fact in document.facts {
            let tokens = Tokenizer.tokenize(fact.sentence).tokens
            let cuts = StemCutter.cut(tokens, minStemWords: 3, maxAnswerWords: 6)
            let pairs = cuts.map { cut in
                (Tokenizer.slice(fact.sentence, tokens[cut.stem.lower].start, tokens[cut.stem.upper - 1].end),
                 Tokenizer.slice(fact.sentence, tokens[cut.answer.lower - 1].end, tokens[cut.answer.upper - 1].end))
            }
            if pairs.contains(where: { $0.0 == fact.prompt && $0.1 == fact.answer }) { matched += 1 }
        }
        #expect(matched == document.facts.count)
    }
}
