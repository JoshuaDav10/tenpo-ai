import Foundation
import CoreModels

/// Typed view over a vocab `ContentItem.payload` (§4.7). Tolerant of several key
/// spellings so it survives small differences in how the content importer writes
/// payloads; reconcile exact keys with `tools/seed` at integration.
public struct VocabFields: Sendable, Hashable {
    public var lemma: String
    public var reading: String?
    public var romaji: String?
    public var glosses: [String]

    public init(lemma: String, reading: String? = nil, romaji: String? = nil, glosses: [String] = []) {
        self.lemma = lemma
        self.reading = reading
        self.romaji = romaji
        self.glosses = glosses
    }

    public init(_ item: ContentItem) {
        let p = item.payload
        // lemma: explicit key, else strip the "vocab:" id namespace.
        let fallbackLemma = item.id.rawValue.split(separator: ":", maxSplits: 1).last.map(String.init) ?? item.id.rawValue
        self.lemma = p["lemma"]?.stringValue ?? p["surface"]?.stringValue ?? fallbackLemma
        self.reading = p["kana"]?.stringValue ?? p["reading"]?.stringValue
        self.romaji = p["romaji"]?.stringValue
        if case .array(let arr)? = p["glosses"] {
            self.glosses = arr.compactMap(\.stringValue)
        } else if let single = p["gloss"]?.stringValue ?? p["meaning"]?.stringValue {
            self.glosses = [single]
        } else {
            self.glosses = []
        }
    }

    /// Human-readable intro line, e.g. "食べる (たべる) — to eat".
    public var introLine: String {
        var head = lemma
        if let reading, reading != lemma { head += " (\(reading))" }
        return glosses.isEmpty ? head : "\(head) — \(glosses.prefix(3).joined(separator: ", "))"
    }

    /// The English prompt for a production retrieval, e.g. "to eat".
    public var meaningPrompt: String {
        glosses.first ?? lemma
    }

    /// Answers accepted for production (kanji lemma and kana reading).
    public var acceptedAnswers: [String] {
        var answers = [lemma]
        if let reading, reading != lemma { answers.append(reading) }
        return answers
    }
}
