import Foundation

/// BCP-47 language identifier, e.g. "ja".
public struct LanguageID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let japanese: LanguageID = "ja"
}

/// Identifies which provider produced a result, e.g. "apple:sfspeech", "deepgram:nova-ja".
public struct ProviderID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// A TTS voice identifier, provider-scoped.
public struct VoiceID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// Actor persona (warm tutor, casual friend, formal senpai — R16).
public struct PersonaID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let warmTutor: PersonaID = "warm_tutor"
    public static let casualFriend: PersonaID = "casual_friend"
    public static let formalSenpai: PersonaID = "formal_senpai"
}

/// Content item id, namespaced by kind: "vocab:食べる", "grammar:te_form", "kanji:食".
public struct ItemID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}
