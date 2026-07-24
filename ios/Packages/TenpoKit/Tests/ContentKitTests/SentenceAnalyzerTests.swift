import Testing
import Foundation
@testable import ContentKit
import CoreModels
import LanguagePackCore
import JapanesePack

private func vocab(_ id: String, _ lemma: String, _ kana: String, _ glosses: [String]) -> ContentItem {
    ContentItem(id: ItemID(rawValue: id), language: .japanese, kind: .vocab,
                payload: .object([
                    "lemma": .string(lemma),
                    "kana": .string(kana),
                    "glosses": .array(glosses.map { .string($0) }),
                ]))
}

private struct StubContent: ContentService {
    var vocabItems: [ContentItem]
    func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem] {
        kind == .vocab ? vocabItems : []
    }
    func item(id: ItemID) async throws -> ContentItem? { vocabItems.first { $0.id == id } }
    func upsert(_ items: [ContentItem]) async throws {}
    func itemCount() async throws -> Int { vocabItems.count }
}

private func makeAnalyzer() -> SentenceAnalyzer {
    let content = StubContent(vocabItems: [
        vocab("vocab:私", "私", "わたし", ["I", "me"]),
        vocab("vocab:水", "水", "みず", ["water"]),
        vocab("vocab:飲む", "飲む", "のむ", ["to drink"]),
        vocab("vocab:名前", "名前", "なまえ", ["name"]),
    ])
    return SentenceAnalyzer(content: content, pack: JapanesePack())
}

struct RomajiTests {
    @Test func convertsBasicKana() {
        #expect(Romaji.from(kana: "わたし") == "watashi")
        #expect(Romaji.from(kana: "こんにちは") == "konnichiha")
        #expect(Romaji.from(kana: "みず") == "mizu")
    }

    @Test func handlesDigraphsSokuonAndLongVowels() {
        #expect(Romaji.from(kana: "しゅくだい") == "shukudai")   // youon
        #expect(Romaji.from(kana: "がっこう") == "gakkou")       // sokuon doubles k
        #expect(Romaji.from(kana: "きって") == "kitte")
        #expect(Romaji.from(kana: "ラーメン") == "raamen")       // katakana + long mark
    }

    @Test func assimilatesNBeforeLabials() {
        #expect(Romaji.from(kana: "しんぶん") == "shimbun")
        #expect(Romaji.from(kana: "せんえん") == "sen'en".replacingOccurrences(of: "'", with: ""))
    }

    @Test func passesNonKanaThrough() {
        #expect(Romaji.from(kana: "私") == "私")          // kanji untouched
        #expect(Romaji.isAllKana("はじめまして"))
        #expect(!Romaji.isAllKana("私はジョシュです"))     // contains kanji
    }
}

struct SentenceAnalyzerTests {

    @Test func annotatesVocabWithReadingRomajiAndGloss() async {
        let sentence = await makeAnalyzer().analyze("水を飲む")
        #expect(sentence.tokens.count == 3)

        let water = sentence.tokens[0]
        #expect(water.surface == "水")
        #expect(water.reading == "みず")
        #expect(water.romaji == "mizu")
        #expect(water.glosses == ["water"])
        #expect(water.itemID?.rawValue == "vocab:水")

        // Whole-sentence kana + romaji lines for the transcript.
        #expect(sentence.kana == "みずをのむ")
        #expect(sentence.romaji.contains("mizu"))
        #expect(sentence.romaji.contains("nomu"))
    }

    @Test func explainsParticlesWithGrammarNotes() async {
        let sentence = await makeAnalyzer().analyze("水を飲む")
        let particle = sentence.tokens[1]
        #expect(particle.surface == "を")
        // を is pronounced "o" — the kind of thing a learner needs told.
        #expect(particle.reading == "お")
        #expect(particle.romaji == "o")
        #expect(particle.note?.contains("object marker") == true)
        #expect(particle.isExplainable)
    }

    @Test func longestMatchWinsOverSingleCharacters() async {
        let sentence = await makeAnalyzer().analyze("名前")
        #expect(sentence.tokens.count == 1)
        #expect(sentence.tokens[0].surface == "名前")
        #expect(sentence.tokens[0].reading == "なまえ")
    }

    @Test func unknownRunsStayTogetherAndKanaReadsItself() async {
        let sentence = await makeAnalyzer().analyze("ジョシュです")
        // An unknown katakana name shouldn't shatter into single characters
        // (it may split at a script boundary, which is correct).
        #expect(sentence.tokens.first?.surface == "ジョシュ")
        #expect(sentence.tokens.first?.reading == "ジョシュ")
        #expect(sentence.romaji.contains("josh"))
        #expect(sentence.romaji.contains("desu"))
    }

    @Test func multiCharFunctionWordsWinOverTheirFirstCharacter() async {
        // Regression: です must not fragment into で + す ("de su"), which happened
        // when only single-character particles were matched.
        let sentence = await makeAnalyzer().analyze("私はジョシュです")
        let copula = sentence.tokens.last
        #expect(copula?.surface == "です")
        #expect(copula?.romaji == "desu")
        #expect(copula?.note?.contains("polite") == true)
        #expect(sentence.romaji.contains("desu"))
    }

    @Test func fixedGreetingsReadAsOneWordWithSpokenWa() async {
        // こんにちは must not fragment into "kon ni chi wa", and its trailing は
        // is pronounced "wa" — exactly the kind of thing learners need told.
        let sentence = await makeAnalyzer().analyze("こんにちは")
        #expect(sentence.tokens.count == 1)
        let greeting = sentence.tokens[0]
        #expect(greeting.surface == "こんにちは")
        #expect(greeting.romaji == "konnichiwa")
        #expect(greeting.note?.contains("hello") == true)
        #expect(greeting.isExplainable)
    }

    @Test func longestFixedPhraseWins() async {
        let sentence = await makeAnalyzer().analyze("ありがとうございます")
        #expect(sentence.tokens.count == 1)
        #expect(sentence.tokens[0].note?.contains("polite") == true)
    }

    @Test func questionParticleStaysItsOwnWord() async {
        // です + か should read "desu ka", not "desuka".
        let sentence = await makeAnalyzer().analyze("何ですか")
        #expect(sentence.romaji.contains("desu ka"))
        #expect(sentence.tokens.contains { $0.surface == "か" && $0.note?.contains("question") == true })
    }

    @Test func cachesRepeatedAnalyses() async {
        let analyzer = makeAnalyzer()
        let first = await analyzer.analyze("私は水を飲む")
        let second = await analyzer.analyze("私は水を飲む")
        #expect(first == second)
        #expect(first.tokens.contains { $0.surface == "私" && $0.glosses.contains("I") })
        #expect(first.tokens.contains { $0.surface == "は" && $0.note != nil })
    }
}
