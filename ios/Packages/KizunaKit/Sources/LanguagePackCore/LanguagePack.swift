import Foundation
import CoreModels

// MARK: - Supporting types (§5)

public struct ScriptDescriptor: Codable, Sendable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Token: Codable, Sendable, Hashable {
    public var surface: String
    public var lemma: String
    /// Part of speech (pack-specific tag set).
    public var pos: String
    /// Reading in kana / romanization, when known.
    public var reading: String?

    public init(surface: String, lemma: String, pos: String, reading: String? = nil) {
        self.surface = surface
        self.lemma = lemma
        self.pos = pos
        self.reading = reading
    }
}

/// Text with ruby annotations (furigana / pinyin / romanization).
public struct RubyAnnotated: Codable, Sendable, Hashable {
    public struct Segment: Codable, Sendable, Hashable {
        public var base: String
        public var ruby: String?

        public init(base: String, ruby: String? = nil) {
            self.base = base
            self.ruby = ruby
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public var plainText: String { segments.map(\.base).joined() }
}

public enum MatchResult: Sendable, Hashable {
    case exact
    /// Equivalent after normalization (kana/kanji equivalence, width folding).
    case equivalent
    case mismatch(closest: String?)

    public var isMatch: Bool {
        switch self {
        case .exact, .equivalent: return true
        case .mismatch: return false
        }
    }
}

public struct RegisterDescriptor: Codable, Sendable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum ProsodyModel: Sendable {
    case pitchAccent(PitchAccentData)
    case tones
    case stress
    case none
}

/// Pitch accent lookup (Kanjium mora-position format — loaded in Phase 1).
public struct PitchAccentData: Sendable {
    /// word (kana) → accent positions (0 = heiban, n = mora of downstep).
    public var lookup: @Sendable (String) -> [Int]

    public init(lookup: @escaping @Sendable (String) -> [Int]) {
        self.lookup = lookup
    }
}

public struct GrammarPoint: Codable, Sendable, Hashable {
    public var id: ItemID
    public var name: String
    public var band: String

    public init(id: ItemID, name: String, band: String) {
        self.id = id
        self.name = name
        self.band = band
    }
}

public struct DictionaryEntry: Codable, Sendable, Hashable {
    public var lemma: String
    public var readings: [String]
    public var glosses: [String]

    public init(lemma: String, readings: [String], glosses: [String]) {
        self.lemma = lemma
        self.readings = readings
        self.glosses = glosses
    }
}

public struct FrequencyList: Sendable {
    /// lemma → frequency rank (1 = most frequent); nil if unranked.
    public var rank: @Sendable (String) -> Int?

    public init(rank: @escaping @Sendable (String) -> Int?) {
        self.rank = rank
    }
}

// MARK: - LanguagePack protocol (§5, implement exactly)

/// Everything language-specific lives behind this protocol. FSRS, the mode engine,
/// the Director loop, sync, and UI shells are language-agnostic.
public protocol LanguagePack: Sendable {
    var id: LanguageID { get }
    var scripts: [ScriptDescriptor] { get }
    func tokenize(_ text: String) -> [Token]
    func reading(for text: String) -> RubyAnnotated?
    func normalizeAnswer(_ s: String) -> String
    func answersMatch(_ heard: String, _ expected: [String]) -> MatchResult
    var registers: [RegisterDescriptor] { get }
    var prosody: ProsodyModel { get }
    var grammarTaxonomy: [GrammarPoint] { get }
    func lookup(_ lemma: String) -> DictionaryEntry?
    var frequencyList: FrequencyList { get }
    var ttsVoiceMap: [PersonaID: VoiceID] { get }
    var sttLocale: String { get }
}
