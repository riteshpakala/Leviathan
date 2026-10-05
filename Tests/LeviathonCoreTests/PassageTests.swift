import Foundation
import Testing
@testable import LeviathonCore

@Suite("Tokenizer")
struct TokenizerTests {
    @Test("rebuilds its input byte for byte", arguments: [
        "The drone lifted over the ridge, and paused.",
        "# Title\n\n- one *item*\n- two `code`\n\n1. first\n2. second",
        "无人机越过山脊，然后停了下来。它在风中盘旋。",
        "Tabs\tand  double spaces, emoji 🚁 and quotes “like this”.",
        "Line one\r\nline two\n\n\nline five  ",
    ])
    func roundTrip(_ text: String) {
        let tokenized = Tokenizer.tokenize(text)
        #expect(tokenized.text == text)
        #expect(tokenized.byteCount == text.utf8.count)
        for token in tokenized.tokens {
            #expect(Tokenizer.slice(text, token.start, token.end) == token.text)
            #expect(!token.leading.contains("\n"))
        }
    }

    @Test("splits text without spaces into words")
    func cjk() {
        let words = Tokenizer.tokenize("无人机越过山脊").tokens.filter(\.isWord)
        #expect(words.count > 1)
    }

    @Test("sentences end at a full stop before a space or a capital, and at newlines")
    func sentences() {
        let tokens = Tokenizer.tokenize("One two three. Four five? Six\nSeven eight.Nine version 3.14 ends").tokens
        let sentences = Tokenizer.sentences(tokens).map { range in range.map { tokens[$0].text }.joined(separator: " ") }
        #expect(sentences == ["One two three .", "Four five ?", "Six", "Seven eight .", "Nine version 3.14 ends"])
    }
}

@Suite("Aligner")
struct AlignerTests {
    func align(_ a: String, _ b: String) -> Alignment {
        Aligner.align(baseline: Tokenizer.tokenize(a).tokens, sample: Tokenizer.tokenize(b).tokens)
    }

    @Test("identical texts keep every token")
    func identical() {
        let alignment = align("the red car stopped", "the red car stopped")
        #expect(alignment.matched == 4 && alignment.overlap == 1)
    }

    @Test("a substitution drops exactly the changed token")
    func substitution() {
        let alignment = align("the red car stopped at the light", "the blue car stopped at the light")
        #expect(alignment.map.map { $0 != nil } == [true, false, true, true, true, true, true])
    }

    @Test("the longest increasing chain survives a moved word")
    func moved() {
        let pairs = Aligner.matchPairs(["a", "b", "c", "d", "e"], ["b", "c", "d", "a", "e"])
        #expect(pairs.map(\.0) == [1, 2, 3, 4])
    }

    @Test("a long, mostly shared text aligns without blowing the cell cap")
    func long() {
        let words = (0..<3000).map { "w\($0 % 97)" }
        var other = words
        other[1500] = "changed"
        let pairs = Aligner.matchPairs(words, other, cellCap: 10_000)
        #expect(pairs.count == 2999)
    }
}

@Suite("Passage builder")
struct PassageBuilderTests {
    let base = "The drone lifted over the ridge and paused before the wind took it."

    @Test("identical samples lock everything")
    func identical() throws {
        let passage = try Support.passage([(0, base), (0, base), (0.8, base)])
        #expect(passage.areas.isEmpty)
        #expect(passage.measures.lockedShare == 1)
        #expect(passage.segments.map(\.text).joined() == base)
    }

    @Test("one substitution makes one area with both variants, shares and onset")
    func substitution() throws {
        let passage = try Support.passage([
            (0, base), (0, base), (0.4, base), (0.8, base.replacingOccurrences(of: "lifted", with: "rose")),
            (1.2, base.replacingOccurrences(of: "lifted", with: "clawed")),
        ])
        #expect(passage.areas.count == 1)
        let area = try #require(passage.areas.first)
        #expect(area.baselineText == " lifted ")
        #expect(area.variants.map(\.text) == [" lifted ", " rose ", " clawed "])
        #expect(area.variants.map(\.share) == [0.5, 0.25, 0.25])
        #expect(area.onsetTemperature == 0.8)
        #expect(area.holdsContent)
        #expect(passage.segments.map(\.text).joined() == base)
        #expect(passage.baselineTemperature == 0)
    }

    @Test("an insertion with no baseline text is a zero-width area")
    func insertion() throws {
        let passage = try Support.passage([(0, "the red car stopped"), (0.8, "the red sports car stopped"), (0.8, "the red car stopped")])
        let area = try #require(passage.areas.first)
        #expect(area.tokens.isEmpty)
        #expect(area.baselineText == " ")
        #expect(area.variants.map(\.text) == [" ", " sports "])
        #expect(passage.segments.map(\.text).joined() == "the red car stopped")
    }

    @Test("a punctuation-only change is an area that holds no content")
    func punctuation() throws {
        let passage = try Support.passage([(0, "It rained; we stayed inside all day long."), (0.8, "It rained, we stayed inside all day long.")])
        let area = try #require(passage.areas.first)
        #expect(!area.holdsContent)
        #expect(area.variants.map(\.text) == ["; ", ", "])
    }

    @Test("two changes split by a stop word become one area, not two")
    func absorb() throws {
        let passage = try Support.passage([
            (0, "The drone lifted the ridge and paused before the storm."),
            (0.8, "The drone cleared the summit and paused before the storm."),
        ])
        #expect(passage.areas.count == 1)
        #expect(passage.areas.first?.variants.map(\.text) == [" lifted the ridge ", " cleared the summit "])
    }

    @Test("a sample that barely resembles the baseline is an alternate, and shapes no area")
    func divergent() throws {
        let passage = try Support.passage([(0, base), (1.2, "Completely different words appear in this unrelated answer here.")])
        #expect(passage.areas.isEmpty)
        #expect(passage.samples.map(\.status) == [.baseline, .divergent])
    }

    @Test("truncated and empty samples are set aside with the reason")
    func setAside() throws {
        let prompt = Support.prompt
        let records = [
            Support.record(base, temperature: 0, index: 0, prompt: prompt, finish: "length"),
            Support.record(base, temperature: 0, index: 1, prompt: prompt),
            Support.record("   ", temperature: 0.4, index: 0, prompt: prompt),
        ]
        let passage = try PassageBuilder.build(set: "s", model: "acme/m1", prompt: prompt, records: records)
        #expect(passage.baselineRecordID == records[1].id)
        #expect(passage.samples.first { $0.recordID == records[0].id }?.reason == "truncated")
        #expect(passage.samples.first { $0.recordID == records[2].id }?.reason == "empty")
    }

    @Test("choosing each sample's variants rebuilds that sample exactly")
    func reconstruction() throws {
        let texts = [
            "The drone lifted over the ridge and paused before the wind took it.",
            "The drone rose over the ridge and paused before the wind took it away.",
            "A drone lifted over the ridge, and hung there before the wind took it.",
            "The drone lifted over the high ridge and paused before the wind took it.",
        ]
        let passage = try Support.passage([(0, texts[0]), (0.4, texts[1]), (0.8, texts[2]), (1.2, texts[3])])
        for sample in passage.samples where sample.status == .aligned {
            let choices = passage.areas.map { area in
                Choice(tokens: area.tokens, variant: area.variants.firstIndex { $0.samples.contains { $0.recordID == sample.recordID } })
            }
            let resolution = try Resolver.resolve(passage, choices: choices)
            let expected = texts[passage.samples.firstIndex { $0.recordID == sample.recordID }!]
            #expect(resolution.text == expected)
        }
        let untouched = try Resolver.resolve(passage, choices: [])
        #expect(untouched.text == texts[0])
    }

    @Test("your own words keep the area's edge whitespace")
    func ownWords() throws {
        let passage = try Support.passage([(0, base), (0.8, base.replacingOccurrences(of: "lifted", with: "rose"))])
        let area = try #require(passage.areas.first)
        let edited = try Resolver.resolve(passage, choices: [Choice(tokens: area.tokens, text: "  climbed  ")])
        #expect(edited.text == base.replacingOccurrences(of: "lifted", with: "climbed"))
        let removed = try Resolver.resolve(passage, choices: [Choice(tokens: area.tokens, text: "")])
        #expect(removed.text == base.replacingOccurrences(of: "lifted ", with: ""))
        #expect(edited.pieces.first { $0.basis == .edit }?.weight == 1)
    }

    @Test("a resolution's baseline pins the passage when a lower temperature arrives later")
    func pinned() throws {
        let prompt = Support.prompt
        var records = [Support.record(base, temperature: 0.4, index: 0, prompt: prompt)]
        let first = try PassageBuilder.build(set: "s", model: "acme/m1", prompt: prompt, records: records)
        records.append(Support.record("A different baseline at zero.", temperature: 0, index: 0, prompt: prompt))
        let unpinned = try PassageBuilder.build(set: "s", model: "acme/m1", prompt: prompt, records: records)
        let pinned = try PassageBuilder.build(set: "s", model: "acme/m1", prompt: prompt, records: records,
                                              baselineRecordID: first.baselineRecordID)
        #expect(unpinned.baselineRecordID != first.baselineRecordID)
        #expect(pinned.baselineRecordID == first.baselineRecordID)
    }
}

@Suite("Expectations")
struct ExpectationTests {
    @Test("stems are cut at function words and answers are the content words after them")
    func cuts() {
        let text = "The childhood home of Mador Halfell stood in Pinebrook."
        let tokens = Tokenizer.tokenize(text).tokens
        let cuts = StemCutter.cut(tokens)
        let pairs = cuts.map { cut in
            (Tokenizer.slice(text, tokens[cut.stem.lower].start, tokens[cut.stem.upper - 1].end),
             Tokenizer.slice(text, tokens[cut.answer.lower - 1].end, tokens[cut.answer.upper - 1].end), cut.cutWord)
        }
        #expect(pairs.map(\.0) == ["The childhood home of", "The childhood home of Mador Halfell stood in"])
        // The answer is the whole run of content words, up to the next function word or mark.
        #expect(pairs.map(\.1) == [" Mador Halfell stood", " Pinebrook"])
        #expect(pairs.map(\.2) == ["of", "in"])
    }

    @Test("support and kept count the samples that kept the stem, and those that also kept the answer")
    func counts() throws {
        let base = "The keeper of the lighthouse was born in Pinebrook."
        let passage = try Support.passage([
            (0, base), (0, base), (0.4, base),
            (0.8, base.replacingOccurrences(of: "Pinebrook", with: "Kestrel")),
            (1.2, base.replacingOccurrences(of: "keeper", with: "builder")),
        ])
        let expectation = try #require(passage.expectations.first { $0.cutWord == "in" })
        #expect(expectation.answerText == " Pinebrook")
        // The builder sample changed the stem, so it does not support it.
        #expect(expectation.support == 3)
        #expect(expectation.kept == 2)
        #expect(expectation.onsetTemperature == 0.8)
    }
}
