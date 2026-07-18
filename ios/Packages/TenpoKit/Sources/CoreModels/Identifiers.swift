import Foundation

/// Codable-as-a-bare-string for the string-newtype identifiers below, so they
/// appear as `"vocab:食べる"` in JSON, not `{"rawValue":"vocab:食べる"}`.
public protocol StringIdentifier: RawRepresentable, Codable, Sendable, Hashable,
                                  ExpressibleByStringLiteral where RawValue == String {
    init(rawValue: String)
}

public extension StringIdentifier {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// BCP-47 language identifier, e.g. "ja".
public struct LanguageID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let japanese: LanguageID = "ja"
}

/// Identifies which provider produced a result, e.g. "apple:sfspeech", "deepgram:nova-ja".
public struct ProviderID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// A TTS voice identifier, provider-scoped.
public struct VoiceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// Actor persona (warm tutor, casual friend, formal senpai — R16).
public struct PersonaID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let warmTutor: PersonaID = "warm_tutor"
    public static let casualFriend: PersonaID = "casual_friend"
    public static let formalSenpai: PersonaID = "formal_senpai"
}

/// Content item id, namespaced by kind: "vocab:食べる", "grammar:te_form", "kanji:食".
public struct ItemID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}
