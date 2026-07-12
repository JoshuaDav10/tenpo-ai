import Foundation

/// The four independent FSRS dimensions tracked per content item (§4.5).
public enum SkillDimension: String, Codable, Sendable, CaseIterable {
    /// See it → know meaning (cloze, reading modes, flashcard).
    case recognitionReading
    /// Hear it → know meaning (listening-only mode, JP→EN answer).
    case recognitionListening
    /// Produce it in text (EN→JP typed, cloze-production).
    case productionWritten
    /// Produce it in speech (drills, roleplay — Director grades).
    case productionSpoken
}

/// FSRS review grade (§4.5). Raw values match the `review_event.grade` column.
public enum ReviewGrade: Int, Codable, Sendable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}
