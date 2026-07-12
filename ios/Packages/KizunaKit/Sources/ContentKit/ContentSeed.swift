import Foundation
import CoreModels

/// Loads the committed starter curriculum (`tools/seed/*.json`) into `ContentItem`
/// values (§9 Phase 1 step 3). The app bundles these files and upserts them on
/// first launch; the same JSON is what `tools/import_content.py --seed` ingests.
///
/// Each seed entry is a flat JSON object (id, band, frequency_rank + kind-specific
/// fields). We keep the whole object as the item payload so LanguagePack views like
/// `VocabFields` can read whatever keys they need.
public enum ContentSeed {
    public struct FileSpec: Sendable {
        public var resource: String       // basename, e.g. "vocab_n5"
        public var kind: ContentKind
        public var source: String?
        public var license: String?

        public init(resource: String, kind: ContentKind, source: String? = nil, license: String? = nil) {
            self.resource = resource
            self.kind = kind
            self.source = source
            self.license = license
        }
    }

    /// The seed files shipped with the app, in load order.
    public static let manifest: [FileSpec] = [
        FileSpec(resource: "vocab_n5", kind: .vocab, source: "Kizuna seed (N5)"),
        FileSpec(resource: "kanji_n5", kind: .kanji, source: "Kizuna seed (N5)"),
        FileSpec(resource: "grammar_n5", kind: .grammar, source: "Kizuna seed (N5)"),
        FileSpec(resource: "sentences_n5", kind: .sentence, source: "Kizuna seed (N5)"),
        FileSpec(resource: "scenarios_n5", kind: .scenario, source: "Kizuna seed (N5)"),
    ]

    public enum SeedError: Error, Sendable {
        case missingID(resource: String)
    }

    /// Parse one seed file into content items. Accepts either a bare JSON array or
    /// an object wrapping the entries under `items` (the seed files use the latter,
    /// with a leading `_comment`).
    public static func items(fromJSONArray data: Data, spec: FileSpec) throws -> [ContentItem] {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let entries: [JSONValue]
        switch root {
        case .array(let arr):
            entries = arr
        case .object:
            if case .array(let arr)? = root["items"] {
                entries = arr
            } else {
                entries = []
            }
        default:
            entries = []
        }
        return try entries.map { entry in
            guard let id = entry["id"]?.stringValue else {
                throw SeedError.missingID(resource: spec.resource)
            }
            var frequencyRank: Int?
            if case .number(let n)? = entry["frequency_rank"] { frequencyRank = Int(n) }
            return ContentItem(
                id: ItemID(rawValue: id),
                language: .japanese,
                kind: spec.kind,
                payload: entry,
                band: entry["band"]?.stringValue,
                frequencyRank: frequencyRank,
                source: spec.source,
                license: spec.license
            )
        }
    }

    /// Load every seed file found in `bundle` (subdirectory optional) into items.
    /// Files that aren't present are skipped, so a partial bundle still boots.
    public static func loadAll(from bundle: Bundle, subdirectory: String? = "Seed") throws -> [ContentItem] {
        var items: [ContentItem] = []
        for spec in manifest {
            guard let url = bundle.url(forResource: spec.resource, withExtension: "json", subdirectory: subdirectory)
                ?? bundle.url(forResource: spec.resource, withExtension: "json") else { continue }
            let data = try Data(contentsOf: url)
            items.append(contentsOf: try Self.items(fromJSONArray: data, spec: spec))
        }
        return items
    }
}

public extension ContentService {
    /// First-launch bootstrap: if the store is empty, load the bundled seed.
    /// Idempotent — a populated store is left untouched. Returns items inserted.
    @discardableResult
    func seedIfEmpty(from bundle: Bundle, subdirectory: String? = "Seed") async throws -> Int {
        guard try await itemCount() == 0 else { return 0 }
        let items = try ContentSeed.loadAll(from: bundle, subdirectory: subdirectory)
        guard !items.isEmpty else { return 0 }
        try await upsert(items)
        return items.count
    }
}
