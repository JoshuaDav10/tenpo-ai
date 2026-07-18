import Foundation
import CoreModels

/// Typed view over a cloze `ContentItem.payload` (kind `sentence`, id `cloze:*`).
/// A cloze item is a sentence with one token blanked out — targeting a particle
/// or conjugation (§4.6 mode 5).
public struct ClozeFields: Sendable, Hashable {
    /// The sentence with the blank shown, e.g. "がっこう＿＿いきます".
    public var prompt: String
    /// The correct fill, e.g. "に".
    public var answer: String
    /// Optional teaching hint, e.g. "direction particle".
    public var hint: String?
    /// The complete sentence with the answer filled in.
    public var full: String?
    /// English translation.
    public var english: String?

    public init(prompt: String, answer: String, hint: String? = nil, full: String? = nil, english: String? = nil) {
        self.prompt = prompt
        self.answer = answer
        self.hint = hint
        self.full = full
        self.english = english
    }

    public init?(_ item: ContentItem) {
        let p = item.payload
        guard let prompt = p["prompt"]?.stringValue ?? p["cloze_prompt"]?.stringValue,
              let answer = p["answer"]?.stringValue ?? p["cloze_answer"]?.stringValue else {
            return nil
        }
        self.prompt = prompt
        self.answer = answer
        self.hint = p["hint"]?.stringValue
        self.full = p["full"]?.stringValue ?? p["sentence"]?.stringValue
        self.english = p["en"]?.stringValue ?? p["english"]?.stringValue
    }

    /// True when a content item carries a cloze payload.
    public static func isCloze(_ item: ContentItem) -> Bool {
        ClozeFields(item) != nil
    }
}
