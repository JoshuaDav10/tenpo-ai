import Testing
@testable import JapanesePack
import LanguagePackCore

@Suite struct NormalizationTests {
    let pack = JapanesePack()

    @Test func kanaFoldingEquatesKatakanaAndHiragana() {
        #expect(pack.normalizeAnswer("タベル") == pack.normalizeAnswer("たべる"))
    }

    @Test func widthFoldingNormalizesFullwidthLatin() {
        #expect(pack.normalizeAnswer("ＡＢＣ") == "abc")
    }

    @Test func punctuationAndWhitespaceStripped() {
        #expect(pack.normalizeAnswer("はい、そうです。") == pack.normalizeAnswer("はいそうです"))
    }
}

@Suite struct AnswerMatchTests {
    let pack = JapanesePack()

    @Test func exactMatchWins() {
        #expect(pack.answersMatch("食べる", ["食べる"]) == .exact)
    }

    @Test func kanaVariantIsEquivalent() {
        // §5: answersMatch handles kana/kanji equivalence (たべる accepted for 食べる's kana).
        #expect(pack.answersMatch("タベル", ["たべる"]) == .equivalent)
    }

    @Test func mismatchReportsClosest() {
        let result = pack.answersMatch("学校を行く", ["学校に行く"])
        #expect(!result.isMatch)
    }
}

@Suite struct TokenizerTests {
    @Test func tokenizesJapaneseText() {
        let tokens = JapanesePack().tokenize("私は学生です")
        #expect(!tokens.isEmpty)
        #expect(tokens.map(\.surface).joined() == "私は学生です")
    }
}
