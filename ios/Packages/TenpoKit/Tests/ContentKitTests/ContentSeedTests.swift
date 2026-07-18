import Testing
import Foundation
import CoreModels
@testable import ContentKit

/// Locate the repo's `tools/seed` directory relative to this source file, so the
/// tests validate the ACTUAL shipped curriculum, not a fixture.
private func seedDir() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    // .../ios/Packages/TenpoKit/Tests/ContentKitTests/ContentSeedTests.swift → repo root
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("tools/seed", isDirectory: true)
}

private func loadSeed(_ resource: String, kind: ContentKind) throws -> [ContentItem] {
    let url = seedDir().appendingPathComponent("\(resource).json")
    return try ContentSeed.items(fromJSONArray: try Data(contentsOf: url),
                                 spec: .init(resource: resource, kind: kind))
}

@Suite struct ContentSeedTests {
    @Test func vocabSeedParsesAndIsWellFormed() throws {
        let vocab = try loadSeed("vocab_n5", kind: .vocab)
        #expect(vocab.count >= 80)                       // ~100 authored
        for item in vocab {
            #expect(item.kind == .vocab)
            #expect(item.id.rawValue.hasPrefix("vocab:"))
            let fields = VocabFields(item)
            #expect(!fields.lemma.isEmpty)
            #expect(!fields.glosses.isEmpty, "\(item.id.rawValue) has no glosses")
        }
    }

    @Test func vocabIsRoughlyFrequencyOrderedAndHasReadings() throws {
        let vocab = try loadSeed("vocab_n5", kind: .vocab)
        // The most common word (私 / わたし) should be near the top of the frequency list.
        let ranked = vocab.compactMap { $0.frequencyRank != nil ? $0 : nil }
        #expect(ranked.count >= 80, "most vocab should carry a frequency_rank")
        // Every vocab item has a kana reading (needed for furigana + production answers).
        for item in vocab {
            #expect(VocabFields(item).reading != nil, "\(item.id.rawValue) missing kana")
        }
    }

    @Test func grammarAndKanjiSeedParse() throws {
        let grammar = try loadSeed("grammar_n5", kind: .grammar)
        let kanji = try loadSeed("kanji_n5", kind: .kanji)
        #expect(grammar.count >= 25)
        #expect(kanji.count >= 25)
        #expect(grammar.allSatisfy { $0.id.rawValue.hasPrefix("grammar:") })
        #expect(kanji.allSatisfy { $0.id.rawValue.hasPrefix("kanji:") })
    }

    @Test func vocabRetrievalPromptsAreUsable() throws {
        // The VocabIntroMode prompt ("How do you say X?") must have a meaning to show.
        let vocab = try loadSeed("vocab_n5", kind: .vocab)
        for item in vocab.prefix(20) {
            #expect(!VocabFields(item).meaningPrompt.isEmpty)
        }
    }
}
