//
//  StemCutter.swift
//  LeviathanCore
//
//  WHAT: Where a text sets up an expectation: wherever a function word is followed by content,
//        the sentence up to and including the function word is a stem, and the run of content
//        words after it is what the text expects next.
//  PIN:  The function words are RaoLM's (`TokenRoles.functionWords`). A stem starts at its
//        sentence's first word and holds at least `minStemWords` words. The answer is the content
//        words that follow, each after a single space, at most `maxAnswerWords`; a comma, a
//        clitic or another function word ends it. RaoLM's synthetic facts have this shape: "The
//        childhood home of Mador Halfell stood in" + " Pinebrook".
//

import Foundation

public struct StemCut: Sendable, Hashable {
    public var sentence: IndexRange
    public var stem: IndexRange
    public var answer: IndexRange
    public var cutWord: String
}

public enum StemCutter {
    public static func cut(_ tokens: [Token], minStemWords: Int = 3, maxAnswerWords: Int = 6) -> [StemCut] {
        var cuts: [StemCut] = []
        for sentence in Tokenizer.sentences(tokens) {
            guard let first = sentence.first(where: { tokens[$0].isWord }) else { continue }
            var words = 0
            for i in first..<sentence.upperBound {
                let token = tokens[i]
                guard token.isWord else { continue }
                words += 1
                guard words >= minStemWords, TokenRoles.isFunctionWord(token.text) else { continue }
                var end = i + 1
                var count = 0
                while end < sentence.upperBound, count < maxAnswerWords, tokens[end].isWord, tokens[end].role == .content,
                      tokens[end].leading == " " {
                    end += 1
                    count += 1
                }
                guard count > 0 else { continue }
                cuts.append(StemCut(sentence: IndexRange(sentence.lowerBound, sentence.upperBound), stem: IndexRange(first, i + 1),
                                    answer: IndexRange(i + 1, end), cutWord: token.text.lowercased()))
            }
        }
        return cuts
    }
}
