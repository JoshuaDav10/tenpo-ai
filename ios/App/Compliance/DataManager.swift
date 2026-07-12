import Foundation
import GRDB
import Persistence

/// Data export + account deletion (§8.2). Apple requires in-app account deletion;
/// GDPR/CCPA hygiene requires export. Both are trivial here because learner state
/// is just local rows.
enum DataManager {
    struct ExportBundle: Encodable {
        var exportedAt: Date
        var skillStates: [SkillStateRecord]
        var reviewEvents: [ReviewEventRecord]
        var errorEvents: [ErrorEventRecord]
        var sessions: [SessionRow]
    }

    /// Write a JSON dump of the learner's own data to a temp file for the share sheet.
    static func exportJSON(_ db: DatabaseManager) async throws -> URL {
        let bundle = try await db.read { database in
            ExportBundle(
                exportedAt: Date(),
                skillStates: try SkillStateRecord.fetchAll(database),
                reviewEvents: try ReviewEventRecord.fetchAll(database),
                errorEvents: try ErrorEventRecord.fetchAll(database),
                sessions: try SessionRow.fetchAll(database)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kizuna-export-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url)
        return url
    }

    /// Purge all learner state (keeps bundled curriculum). Used for account deletion.
    static func deleteLearnerData(_ db: DatabaseManager) async throws {
        try await db.write { database in
            for table in ["skill_state", "review_event", "error_event", "transcript_turn", "session"] {
                try database.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
