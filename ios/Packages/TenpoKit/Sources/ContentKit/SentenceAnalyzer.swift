import Foundation
import CoreModels
import LanguagePackCore

/// One tappable piece of a sentence: the surface text plus whatever we know
/// about it (reading, romaji, meaning). Powers the transcript's romaji line,
/// kanji⇄kana toggle, and tap-to-explain (Joshua's parity items 4–7).
public struct AnalyzedToken: Identifiable, Sendable, Hashable {
    public var id: Int
    public var surface: String
    /// Kana reading when known (from the dictionary or when the surface IS kana).
    public var reading: String?
    /// Hepburn romaji of the reading, when we have one.
    public var romaji: String?
    public var glosses: [String]
    /// Grammatical note for particles and function words the dictionary misses.
    public var note: String?
    /// The curriculum item this token matched, if any — lets the UI show SRS state
    /// and lets "explain" link into the learner model.
    public var itemID: ItemID?

    public var isExplainable: Bool { !glosses.isEmpty || note != nil }

    public init(id: Int, surface: String, reading: String? = nil, romaji: String? = nil,
                glosses: [String] = [], note: String? = nil, itemID: ItemID? = nil) {
        self.id = id
        self.surface = surface
        self.reading = reading
        self.romaji = romaji
        self.glosses = glosses
        self.note = note
        self.itemID = itemID
    }
}

public struct AnalyzedSentence: Sendable, Hashable {
    public var tokens: [AnalyzedToken]
    /// Whole-sentence kana rendering (kanji replaced by readings where known).
    public var kana: String
    /// Whole-sentence romaji.
    public var romaji: String

    public init(tokens: [AnalyzedToken], kana: String, romaji: String) {
        self.tokens = tokens
        self.kana = kana
        self.romaji = romaji
    }
}

/// Turns Japanese sentences into annotated, tappable tokens using the shipped
/// curriculum as its dictionary (longest-match over vocab surfaces + readings),
/// falling back to the language pack's tokenizer. Built as an actor with a cache
/// because the transcript re-renders often and lookups hit the content store.
public actor SentenceAnalyzer {
    private let content: any ContentService
    private let pack: any LanguagePack
    /// surface/reading → (lemma, reading, glosses, itemID)
    private var dictionary: [String: DictionaryHit] = [:]
    private var loaded = false
    private var cache: [String: AnalyzedSentence] = [:]

    struct DictionaryHit: Sendable {
        var lemma: String
        var reading: String?
        var glosses: [String]
        var itemID: ItemID
    }

    public init(content: any ContentService, pack: any LanguagePack) {
        self.content = content
        self.pack = pack
    }

    public func analyze(_ text: String) async -> AnalyzedSentence {
        if let cached = cache[text] { return cached }
        await loadDictionaryIfNeeded()

        var tokens: [AnalyzedToken] = []
        var kana = ""
        var romaji = ""
        let chars = Array(text)
        var index = 0
        var tokenID = 0

        while index < chars.count {
            let remaining = String(chars[index...])

            // Longest match against the curriculum dictionary (up to 8 chars).
            var matched: (surface: String, hit: DictionaryHit)?
            for length in stride(from: min(8, chars.count - index), through: 1, by: -1) {
                let candidate = String(chars[index..<(index + length)])
                if let hit = dictionary[candidate] {
                    matched = (candidate, hit)
                    break
                }
            }

            if let (surface, hit) = matched {
                let reading = hit.reading ?? (Romaji.isAllKana(surface) ? surface : nil)
                tokens.append(AnalyzedToken(
                    id: tokenID, surface: surface, reading: reading,
                    romaji: reading.map(Romaji.from(kana:)),
                    glosses: hit.glosses, itemID: hit.itemID))
                kana += reading ?? surface
                romaji += (reading.map(Romaji.from(kana:)) ?? surface) + " "
                tokenID += 1
                index += surface.count
                continue
            }

            // Known particle / function word? Longest match first, so です wins
            // over で and ました over ま.
            var functionMatch: (surface: String, note: String)?
            for length in stride(from: min(4, chars.count - index), through: 1, by: -1) {
                let candidate = String(chars[index..<(index + length)])
                if let note = Self.functionWords[candidate] {
                    functionMatch = (candidate, note)
                    break
                }
            }
            if let (single, note) = functionMatch {
                // Particles are WRITTEN は/へ/を but PRONOUNCED wa/e/o. The kana
                // line shows spelling; only romaji reflects pronunciation.
                let spoken = Self.particleReadings[single] ?? single
                tokens.append(AnalyzedToken(
                    id: tokenID, surface: single, reading: spoken,
                    romaji: Romaji.from(kana: spoken), note: note))
                kana += single
                romaji += Romaji.from(kana: spoken) + " "
                tokenID += 1
                index += single.count
                continue
            }
            let single = String(chars[index])

            // Unknown: consume a run of the same character class so we don't
            // shatter words into single characters. Only a dictionary word or a
            // particle breaks the run — otherwise です would become "de su".
            // Common fixed phrases are matched whole so they read naturally.
            var run = single
            var next = index + 1
            var phraseNote: String?
            // Longest phrase wins (ありがとうございます over ありがとう).
            let remainder = String(chars[index...])
            if let phrase = Self.fixedPhrases.keys
                .filter({ remainder.hasPrefix($0) })
                .max(by: { $0.count < $1.count }) {
                run = phrase
                phraseNote = Self.fixedPhrases[phrase]
                next = index + phrase.count
            } else {
                while next < chars.count,
                      sameClass(chars[next], chars[index]),
                      !startsDictionaryWord(chars, at: next),
                      Self.functionWords[String(chars[next])] == nil {
                    run.append(chars[next])
                    next += 1
                }
            }
            let reading = Romaji.isAllKana(run) ? run : nil
            // Fixed greetings SPELL は but SAY わ (こんにちは → konnichiwa).
            let spoken = (phraseNote != nil && run.hasSuffix("は"))
                ? String(run.dropLast()) + "わ"
                : reading
            let tokenRomaji = spoken.map(Romaji.from(kana:))
            tokens.append(AnalyzedToken(
                id: tokenID, surface: run, reading: reading,
                romaji: tokenRomaji, note: phraseNote))
            kana += reading ?? run
            if let tokenRomaji { romaji += tokenRomaji + " " } else { romaji += run }
            tokenID += 1
            index = next
        }

        let sentence = AnalyzedSentence(
            tokens: tokens, kana: kana,
            romaji: romaji.trimmingCharacters(in: .whitespaces))
        cache[text] = sentence
        return sentence
    }

    private func sameClass(_ a: Character, _ b: Character) -> Bool {
        a.isKana == b.isKana && a.isLetter == b.isLetter
    }

    /// Does a dictionary entry START at this position? (Single characters that are
    /// merely *part* of a longer word must not break an unknown run.)
    private func startsDictionaryWord(_ chars: [Character], at index: Int) -> Bool {
        for length in stride(from: min(8, chars.count - index), through: 1, by: -1) {
            if dictionary[String(chars[index..<(index + length)])] != nil { return true }
        }
        return false
    }

    /// Index the shipped vocabulary once: surface AND reading both map to the entry
    /// so 私/わたし both resolve.
    private func loadDictionaryIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let items = try? await content.items(kind: .vocab, band: nil, limit: 5000) else { return }
        for item in items {
            let fields = VocabFields(item)
            let hit = DictionaryHit(lemma: fields.lemma, reading: fields.reading,
                                    glosses: fields.glosses, itemID: item.id)
            dictionary[fields.lemma] = hit
            if let reading = fields.reading, dictionary[reading] == nil {
                dictionary[reading] = hit
            }
        }
    }

    /// Particles and copula forms the vocab list won't cover — the pieces learners
    /// most need explained (Joshua's を-vs-は correction in the Pingo transcript).
    static let functionWords: [String: String] = [
        // Copula and polite endings (multi-character entries win by longest match).
        "です": "polite “is / am / are” — ends a polite statement",
        "ました": "past polite verb ending — “did …”",
        "ません": "negative polite verb ending — “does not …”",
        "ます": "polite verb ending — present or future",
        "ください": "please give me / please do — polite request",
        "でした": "polite past “was / were”",

        "は": "topic marker — marks what the sentence is about (pronounced “wa”)",
        "が": "subject marker — marks who/what does the action",
        "を": "object marker — marks what the action is done to (pronounced “o”)",
        "に": "to / at / in — destination, time, or indirect object",
        "へ": "toward — direction of movement (pronounced “e”)",
        "で": "at / by / with — where an action happens, or the means used",
        "と": "and / with — joins nouns, or marks who you do something with",
        "も": "also / too — replaces は or を to mean “as well”",
        "の": "possessive / linking — “X の Y” makes Y belong to or relate to X",
        "か": "question marker — turns a statement into a question",
        "ね": "right? — seeks agreement, softens the sentence",
        "よ": "you know — adds emphasis or new information",
        "から": "because / from — reason or starting point",
        "まで": "until / as far as — end point",
        "や": "and (among others) — non-exhaustive list",
    ]

    static let particleReadings: [String: String] = [
        "は": "わ", "へ": "え", "を": "お",
    ]

    /// Set phrases that must read as ONE word — the seed vocab can't cover the
    /// greetings and fillers that appear constantly in conversation, and without
    /// this こんにちは romanizes as "kon ni chi wa".
    static let fixedPhrases: [String: String] = [
        "こんにちは": "hello (daytime greeting) — は here is pronounced “wa”",
        "こんばんは": "good evening — は here is pronounced “wa”",
        "おはよう": "good morning (casual)",
        "おはようございます": "good morning (polite)",
        "はじめまして": "nice to meet you — said at a first meeting",
        "ありがとう": "thank you (casual)",
        "ありがとうございます": "thank you (polite)",
        "すみません": "excuse me / sorry / thank you — the all-purpose polite opener",
        "よろしくお願いします": "please treat me well — closes an introduction",
        "おねがいします": "please — polite request",
        "さようなら": "goodbye",
        "わかりました": "understood / got it",
        "わかりません": "I don't understand",
        "だいじょうぶ": "okay / fine / no problem",
        "いただきます": "said before eating",
        "ごちそうさま": "said after eating",
    ]
}
