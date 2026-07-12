import Foundation
import NaturalLanguage
import CoreModels
import LanguagePackCore

/// Reference LanguagePack (§5). Phase 0 ships the D9 fallback path
/// (Apple NLTokenizer); Sudachi + JMdict + Kanjium data land in Phase 1.
public struct JapanesePack: LanguagePack {
    public let id: LanguageID = .japanese

    public let scripts: [ScriptDescriptor] = [
        ScriptDescriptor(id: "kanji", name: "漢字"),
        ScriptDescriptor(id: "hiragana", name: "ひらがな"),
        ScriptDescriptor(id: "katakana", name: "カタカナ"),
    ]

    public let registers: [RegisterDescriptor] = [
        RegisterDescriptor(id: "casual", name: "Casual"),
        RegisterDescriptor(id: "polite", name: "Polite (です・ます)"),
        RegisterDescriptor(id: "keigo", name: "Keigo (尊敬・謙譲)"),
    ]

    // Kanjium accent data loads here in Phase 1.
    public let prosody: ProsodyModel = .pitchAccent(PitchAccentData(lookup: { _ in [] }))

    // ~120 N5–N4 points authored as JSON content in Phase 1.
    public let grammarTaxonomy: [GrammarPoint] = []

    // Kanjium frequency lists load here in Phase 1.
    public let frequencyList = FrequencyList(rank: { _ in nil })

    public let ttsVoiceMap: [PersonaID: VoiceID] = [
        .warmTutor: "ja-warm-tutor",
        .casualFriend: "ja-casual-friend",
        .formalSenpai: "ja-formal-senpai",
    ]

    public let sttLocale = "ja-JP"

    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text
        var tokens: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let surface = String(text[range])
            tokens.append(Token(surface: surface, lemma: surface, pos: "unknown"))
            return true
        }
        return tokens
    }

    public func reading(for text: String) -> RubyAnnotated? {
        // JMdict + Sudachi readings arrive in Phase 1; kana-only text reads as itself.
        guard text.allSatisfy({ $0.isKana || $0.isWhitespace }) else { return nil }
        return RubyAnnotated(segments: [.init(base: text)])
    }

    /// Kana-fold + width-fold + case-fold + strip whitespace/punctuation, so that
    /// 食べる/たべる comparison happens on a canonical form (meaning-graded leniency;
    /// pronunciation-graded strictness is enforced by the grading algorithm, not here — R10).
    public func normalizeAnswer(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping // width folding (ＡＢ→AB, ｶﾞ→ガ)
        t = t.applyingTransform(.hiraganaToKatakana, reverse: true) ?? t // katakana → hiragana
        t = t.lowercased()
        t.removeAll { $0.isWhitespace || $0.isPunctuation || $0 == "。" || $0 == "、" }
        return t
    }

    public func answersMatch(_ heard: String, _ expected: [String]) -> MatchResult {
        if expected.contains(heard) { return .exact }
        let heardNorm = normalizeAnswer(heard)
        if expected.contains(where: { normalizeAnswer($0) == heardNorm }) { return .equivalent }
        return .mismatch(closest: expected.first)
    }

    public func lookup(_ lemma: String) -> DictionaryEntry? {
        // JMdict lookup lands in Phase 1 (content import).
        nil
    }
}

extension Character {
    var isKana: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x3040...0x30FF).contains(scalar.value) // hiragana + katakana blocks
            || (0xFF66...0xFF9D).contains(scalar.value) // halfwidth katakana
    }
}
