import Foundation

public extension Character {
    /// Hiragana, katakana, or halfwidth katakana.
    var isKana: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x3040...0x30FF).contains(scalar.value) // hiragana + katakana blocks
            || (0xFF66...0xFF9D).contains(scalar.value) // halfwidth katakana
    }
}

/// Kana → Hepburn romaji. Pure and dependency-free so it is unit-testable and
/// usable anywhere (transcript readings, study cards, pronunciation hints).
///
/// Handles the cases that actually bite learners: youon (きゃ), sokuon (っ→
/// doubled consonant), long vowels (ー), ん before labials → m, and both kana
/// scripts. Not a linguistics-grade transliterator — a legible pronunciation aid.
public enum Romaji {
    /// Romanize any kana in `text`; non-kana (kanji, latin, punctuation) passes through.
    public static func from(kana text: String) -> String {
        let hiragana = text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
        var out = ""
        var pendingSokuon = false
        let chars = Array(hiragana)
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            // Small tsu doubles the NEXT consonant.
            if ch == "っ" {
                pendingSokuon = true
                i += 1
                continue
            }

            // Try a two-character digraph first (きゃ, しゅ, ちょ…).
            var syllable: String?
            var consumed = 1
            if i + 1 < chars.count {
                let pair = String([ch, chars[i + 1]])
                if let romaji = digraphs[pair] {
                    syllable = romaji
                    consumed = 2
                }
            }
            if syllable == nil { syllable = monographs[String(ch)] }

            guard var romaji = syllable else {
                // Not kana: emit as-is (kanji, latin, punctuation).
                out.append(ch)
                pendingSokuon = false
                i += 1
                continue
            }

            // ん assimilates to m before labials (しんぶん → shimbun).
            if romaji == "n", i + 1 < chars.count {
                let next = String(chars[i + 1])
                let nextRomaji = digraphs[next] ?? monographs[next] ?? ""
                if nextRomaji.hasPrefix("p") || nextRomaji.hasPrefix("b") || nextRomaji.hasPrefix("m") {
                    romaji = "m"
                }
            }

            if pendingSokuon, let first = romaji.first, first != "a", first != "i",
               first != "u", first != "e", first != "o" {
                romaji = String(first) + romaji
                pendingSokuon = false
            }

            // Long-vowel mark repeats the previous vowel (ラーメン → raamen).
            if ch == "ー", let last = out.last {
                out.append(last)
                i += 1
                continue
            }

            out += romaji
            i += consumed
        }
        return out
    }

    /// True when the text contains no kanji (so a reading adds nothing).
    public static func isAllKana(_ text: String) -> Bool {
        text.allSatisfy { $0.isKana || $0.isWhitespace || $0.isPunctuation }
    }

    private static let digraphs: [String: String] = [
        "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
        "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
        "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho",
        "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
        "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
        "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
        "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
        "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
        "じゃ": "ja", "じゅ": "ju", "じょ": "jo",
        "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
        "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
        "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo",
        "うぃ": "wi", "うぇ": "we", "てぃ": "ti", "でぃ": "di",
        "ちぇ": "che", "しぇ": "she", "じぇ": "je",
    ]

    private static let monographs: [String: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "wi", "ゑ": "we", "を": "o", "ん": "n",
        "ゃ": "ya", "ゅ": "yu", "ょ": "yo",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
        "ー": "", "、": "、", "。": "。",
    ]
}
