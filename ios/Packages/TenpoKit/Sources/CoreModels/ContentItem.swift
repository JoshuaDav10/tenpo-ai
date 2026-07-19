import Foundation

public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case vocab, grammar, kanji, sentence, scenario, lesson
}

/// A curriculum item (§4.7 `content_item`). Payload shape is kind-specific and
/// interpreted by the LanguagePack / ContentKit.
public struct ContentItem: Codable, Sendable, Hashable, Identifiable {
    public var id: ItemID
    public var language: LanguageID
    public var kind: ContentKind
    public var payload: JSONValue
    public var band: String?
    public var frequencyRank: Int?
    public var source: String?
    public var license: String?

    public init(
        id: ItemID, language: LanguageID, kind: ContentKind, payload: JSONValue,
        band: String? = nil, frequencyRank: Int? = nil,
        source: String? = nil, license: String? = nil
    ) {
        self.id = id
        self.language = language
        self.kind = kind
        self.payload = payload
        self.band = band
        self.frequencyRank = frequencyRank
        self.source = source
        self.license = license
    }
}

/// Edge in the kanji↔vocab↔grammar↔sentence graph (§4.7 `item_link`).
public struct ItemLink: Codable, Sendable, Hashable {
    public enum Relation: String, Codable, Sendable {
        case contains, exemplifies, uses
    }

    public var fromID: ItemID
    public var toID: ItemID
    public var relation: Relation

    public init(fromID: ItemID, toID: ItemID, relation: Relation) {
        self.fromID = fromID
        self.toID = toID
        self.relation = relation
    }
}
