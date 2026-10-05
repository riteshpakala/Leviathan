//
//  TokenRoles.swift
//  LeviathanCore
//
//  WHAT: RaoLM's roles, mirrored: every word is form (whitespace, punctuation, a function word)
//        or content (names, numbers, content words). The function words are the stop words
//        Leviathan cuts stems at.
//  PIN:  Mirrors RaoLM `Sources/RaoLMCore/Citation/TokenRoles.swift`: the same fixed list, the
//        same clitics, the same rule for a whole word. RaoLM applies it to BPE pieces grouped
//        into words; Leviathan applies it to the words its tokenizer finds, which is the same
//        thing for the text the two share.
//

import Foundation

public enum TokenRole: String, Codable, Sendable {
    /// Structure: whitespace, punctuation or a function word.
    case form
    /// Information and a voice's word choices: names, numbers, content words.
    case content
}

public enum TokenRoles {
    /// Closed-class English words, as RaoLM lists them.
    public static let functionWords: Set<String> = Set("""
        a an the this that these those my your his her its our their i you he she it we they me him us them who whom whose which what
        of in on at to for with by from about as into onto over under between through during before after above below up down out off
        near since until upon within without and or but nor so yet if then than because while when where though although whether
        is are was were be been being am has have had do does did will would can could may might shall should must
        not no there here also just very too only more most such each every some any all both either neither other another own same
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Contractions a tokenizer splits off a word: form, like the words they stand for.
    public static let clitics: Set<String> = ["'s", "'t", "'re", "'ll", "'d", "'ve", "'m", "’s", "’t", "’re", "’ll", "’d", "’ve", "’m"]

    /// The role of one whole word.
    public static func role(of word: String) -> TokenRole {
        if !word.contains(where: { $0.isLetter || $0.isNumber }) { return .form }
        let lower = word.lowercased()
        if clitics.contains(lower) { return .form }
        if word.allSatisfy(\.isLetter), functionWords.contains(lower) { return .form }
        return .content
    }

    /// Whether a word is one of the function words stems are cut at.
    public static func isFunctionWord(_ word: String) -> Bool {
        word.allSatisfy(\.isLetter) && functionWords.contains(word.lowercased())
    }
}
