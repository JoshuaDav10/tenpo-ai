import Foundation
import GRDB
import CoreModels
import Persistence

/// What the tutor knows about this learner — the "omnicron": a compact, always-on
/// picture of their history that every session reads, so the AI behaves like a
/// buddy who remembers rather than a stranger running a script.
///
/// Assembled from data we already record (FSRS state, the R8 error taxonomy,
/// session history); nothing here needs new capture. Kept small on purpose: it is
/// injected into prompts, so it must stay a few hundred tokens.
public struct LearnerProfile: Sendable, Equatable {
    /// Rough level from the bands the learner has actually been studying.
    public var band: String
    public var trackedItems: Int
    public var dueNow: Int
    public var streakDays: Int
    /// Sessions completed, ever.
    public var sessionsCompleted: Int
    public var daysSinceLastSession: Int?
    /// Phrases/words currently weakest, most-overdue first.
    public var weakItems: [String]
    /// Recurring mistake categories, worst first, with counts — e.g.
    /// [("particle", 7), ("pronunciation", 3)].
    public var recurringErrors: [(category: String, count: Int)]
    /// Concrete recent corrections: what they said → what was expected.
    public var recentCorrections: [(surface: String, expected: String)]
    /// True when the learner is new enough that history shouldn't be referenced.
    public var isNewLearner: Bool { sessionsCompleted == 0 }

    public init(band: String = "N5", trackedItems: Int = 0, dueNow: Int = 0,
                streakDays: Int = 0, sessionsCompleted: Int = 0,
                daysSinceLastSession: Int? = nil, weakItems: [String] = [],
                recurringErrors: [(category: String, count: Int)] = [],
                recentCorrections: [(surface: String, expected: String)] = []) {
        self.band = band
        self.trackedItems = trackedItems
        self.dueNow = dueNow
        self.streakDays = streakDays
        self.sessionsCompleted = sessionsCompleted
        self.daysSinceLastSession = daysSinceLastSession
        self.weakItems = weakItems
        self.recurringErrors = recurringErrors
        self.recentCorrections = recentCorrections
    }

    public static func == (a: LearnerProfile, b: LearnerProfile) -> Bool {
        a.band == b.band && a.trackedItems == b.trackedItems && a.dueNow == b.dueNow
            && a.streakDays == b.streakDays && a.sessionsCompleted == b.sessionsCompleted
            && a.daysSinceLastSession == b.daysSinceLastSession
            && a.weakItems == b.weakItems
            && a.recurringErrors.map(\.category) == b.recurringErrors.map(\.category)
            && a.recentCorrections.map(\.surface) == b.recentCorrections.map(\.surface)
    }

    /// The profile as prompt-ready lines. Empty for a brand-new learner (nothing
    /// is worse than an AI inventing a shared history you don't have).
    public func promptSummary(name: String? = nil) -> String {
        guard !isNewLearner else {
            return name.map { "This is \($0)'s first lesson." } ?? "This is the learner's first lesson."
        }
        var lines: [String] = []
        if let name { lines.append("Learner: \(name).") }
        lines.append("Level: around \(band). \(trackedItems) items tracked, \(dueNow) due for review.")
        if streakDays > 1 { lines.append("On a \(streakDays)-day streak — worth a brief nod.") }
        if let days = daysSinceLastSession, days >= 3 {
            lines.append("Hasn't practiced in \(days) days — ease back in, no guilt.")
        }
        if !weakItems.isEmpty {
            lines.append("Currently shaky on: \(weakItems.prefix(5).joined(separator: "、")).")
        }
        if let worst = recurringErrors.first, worst.count >= 2 {
            lines.append("Recurring weak spot: \(Self.errorHint(worst.category)) (\(worst.count) times recently).")
        }
        if !recentCorrections.isEmpty {
            let examples = recentCorrections.prefix(2)
                .map { "said “\($0.surface)” for “\($0.expected)”" }
                .joined(separator: "; ")
            lines.append("Recent slips: \(examples).")
        }
        return lines.joined(separator: "\n")
    }

    static func errorHint(_ category: String) -> String {
        switch category {
        case "particle": return "particles (は/が/を choice)"
        case "grammar": return "sentence structure"
        case "vocab": return "recalling vocabulary"
        case "pronunciation": return "pronunciation"
        case "register": return "politeness level"
        case "word_order": return "word order"
        default: return category
        }
    }
}

public extension LiveLearnerModelService {
    /// Build the profile from what we already store. One pass, cheap enough to
    /// run at the start of every session.
    func profile(now: Date = Date()) async throws -> LearnerProfile {
        let tracked = try await trackedItemCount()
        let due = try await dueCount(now: now)
        let weak = (try? await weakItems(bandPrefix: nil, count: 5)) ?? []

        // Error taxonomy: which mistakes keep recurring, and concrete examples.
        struct Snapshot: Sendable {
            var categories: [(String, Int)]
            var corrections: [(String, String)]
            var sessions: Int
            var lastSessionAt: Date?
            var band: String
        }
        let snapshot: Snapshot = try await db.read { db in
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            let categoryRows = try Row.fetchAll(db, sql: """
                SELECT category, COUNT(*) AS n FROM error_event
                WHERE at >= ? GROUP BY category ORDER BY n DESC LIMIT 4
                """, arguments: [cutoff])
            let correctionRows = try Row.fetchAll(db, sql: """
                SELECT surface, expected FROM error_event
                WHERE surface IS NOT NULL AND expected IS NOT NULL
                ORDER BY at DESC LIMIT 3
                """)
            let sessions = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM session WHERE ended_at IS NOT NULL") ?? 0
            let lastAt = try Date.fetchOne(db, sql:
                "SELECT MAX(started_at) FROM session WHERE ended_at IS NOT NULL")
            // Band the learner is actually working in: the most common band among
            // tracked items, falling back to N5.
            let band = try String.fetchOne(db, sql: """
                SELECT content_item.band FROM skill_state
                JOIN content_item ON content_item.id = skill_state.item_id
                WHERE content_item.band IS NOT NULL
                GROUP BY content_item.band ORDER BY COUNT(*) DESC LIMIT 1
                """) ?? "N5"
            return Snapshot(
                categories: categoryRows.map { ($0["category"] as String, $0["n"] as Int) },
                corrections: correctionRows.map { ($0["surface"] as String, $0["expected"] as String) },
                sessions: sessions, lastSessionAt: lastAt, band: band)
        }

        let daysSince = snapshot.lastSessionAt.map {
            max(0, Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0)
        }

        return LearnerProfile(
            band: snapshot.band,
            trackedItems: tracked,
            dueNow: due,
            streakDays: try await streakDays(now: now),
            sessionsCompleted: snapshot.sessions,
            daysSinceLastSession: daysSince,
            weakItems: weak.compactMap { $0.payload["lemma"]?.stringValue ?? $0.id.rawValue },
            recurringErrors: snapshot.categories.map { (category: $0.0, count: $0.1) },
            recentCorrections: snapshot.corrections.map { (surface: $0.0, expected: $0.1) })
    }

    /// Consecutive days (ending today or yesterday) with a completed session.
    func streakDays(now: Date = Date()) async throws -> Int {
        let days: [String] = try await db.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT date(started_at) FROM session
                WHERE ended_at IS NOT NULL ORDER BY 1 DESC LIMIT 366
                """)
        }
        guard !days.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: now)
        if days.first != formatter.string(from: cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var streak = 0
        var index = 0
        while index < days.count, days[index] == formatter.string(from: cursor) {
            streak += 1
            index += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }
}
