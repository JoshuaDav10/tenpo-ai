import Foundation
import GRDB
import CoreModels
import Persistence

/// The app's spine (§4.5). Every mode reports evidence here; the daily queue
/// comes from here. Phase 1 lands FSRS-6 scheduling, the daily queue builder,
/// mastery dashboard queries, and the R8 error→SRS loop.
public protocol LearnerModelService: Sendable {
    /// Items for a session plan: due reviews interleaved with new items (§4.5 queue builder).
    func requestItems(count: Int, dimension: SkillDimension?) async throws -> [ContentItem]
    /// Ingest review evidence from any mode; appends the review log AND updates FSRS state.
    func report(_ event: ReviewEvent) async throws
    /// Ingest a categorized error (Director or drill) — R8 pipeline (error → SRS).
    func report(_ event: ErrorEvent) async throws
    /// Dashboard: total tracked (per-item, per-dimension) FSRS states.
    func trackedItemCount() async throws -> Int
    /// Dashboard: number of due, non-suspended dimensions as of `now`.
    func dueCount(now: Date) async throws -> Int
    /// Dashboard: per-dimension stability-band counts (learning/young/mature — R17).
    func masteryCounts() async throws -> MasterySummary
    /// Due/weak items in a JLPT band, most-overdue first — for `seed_weak_items`
    /// scenario seeding (§3.2 moat loop: yesterday's errors shape today's scene).
    func weakItems(bandPrefix: String?, count: Int) async throws -> [ContentItem]
    /// Dashboard "why is this due?" inspector (§3.1 Anki-trust): due items with their
    /// current FSRS state and a plain-English reason, most-forgotten first.
    func dueExplanations(now: Date, limit: Int) async throws -> [DueExplanation]
    /// Dashboard weak-area heatmap (§3.3): mastery mix per (JLPT sub-band × dimension).
    func weakAreaGrid() async throws -> WeakAreaGrid
}

// MARK: - Dashboard summary types

/// Counts of tracked dimensions grouped by FSRS stability band (§4.5 R17):
/// learning (< 2d), young (< 21d), mature (≥ 21d).
public struct MasteryBandCounts: Codable, Sendable, Hashable {
    public var learning: Int
    public var young: Int
    public var mature: Int

    public init(learning: Int = 0, young: Int = 0, mature: Int = 0) {
        self.learning = learning
        self.young = young
        self.mature = mature
    }

    public var total: Int { learning + young + mature }
}

/// Band counts for a single skill dimension.
public struct DimensionMastery: Codable, Sendable, Hashable {
    public var dimension: SkillDimension
    public var counts: MasteryBandCounts

    public init(dimension: SkillDimension, counts: MasteryBandCounts) {
        self.dimension = dimension
        self.counts = counts
    }
}

/// Whole-learner mastery snapshot for the Phase-1 dashboard. Uses an array of
/// per-dimension entries (rather than a `[SkillDimension: …]` dictionary) so it
/// round-trips cleanly through `Codable` regardless of encoder dictionary policy.
public struct MasterySummary: Codable, Sendable, Hashable {
    public var dimensions: [DimensionMastery]
    public var total: MasteryBandCounts

    public init(dimensions: [DimensionMastery], total: MasteryBandCounts) {
        self.dimensions = dimensions
        self.total = total
    }
}

/// One cell of the weak-area heatmap (§3.3 / §4.7 dashboard): mastery mix for a
/// single (JLPT sub-band × skill dimension) intersection.
public struct AreaCell: Sendable, Hashable {
    public var band: String
    public var dimension: SkillDimension
    public var counts: MasteryBandCounts

    public init(band: String, dimension: SkillDimension, counts: MasteryBandCounts) {
        self.band = band
        self.dimension = dimension
        self.counts = counts
    }
}

/// The weak-area heatmap grid: which JLPT sub-bands are still shaky, per skill
/// dimension. Bands/dimensions list only those actually tracked, so the grid is
/// dense. `cell(band:dimension:)` returns nil where nothing is tracked yet.
public struct WeakAreaGrid: Sendable, Hashable {
    public var bands: [String]
    public var dimensions: [SkillDimension]
    public var cells: [AreaCell]

    public init(bands: [String], dimensions: [SkillDimension], cells: [AreaCell]) {
        self.bands = bands
        self.dimensions = dimensions
        self.cells = cells
    }

    public func cell(band: String, dimension: SkillDimension) -> AreaCell? {
        cells.first { $0.band == band && $0.dimension == dimension }
    }
}

/// One row of the "why is this due?" inspector (§3.1). Exposes the FSRS state
/// verbatim — no black box — so the learner can see and trust the schedule.
public struct DueExplanation: Sendable, Hashable, Identifiable {
    public var itemID: ItemID
    public var dimension: SkillDimension
    /// Current recall probability (0…1) from FSRS retrievability at `now`.
    public var retrievability: Double
    /// Memory stability in days (how slowly this is being forgotten).
    public var stability: Double
    public var due: Date
    public var reps: Int
    public var lapses: Int
    /// Plain-English reason this item surfaced now.
    public var headline: String

    public var id: String { "\(itemID.rawValue):\(dimension.rawValue)" }

    public init(itemID: ItemID, dimension: SkillDimension, retrievability: Double,
                stability: Double, due: Date, reps: Int, lapses: Int, headline: String) {
        self.itemID = itemID
        self.dimension = dimension
        self.retrievability = retrievability
        self.stability = stability
        self.due = due
        self.reps = reps
        self.lapses = lapses
        self.headline = headline
    }

    /// Pure, honest explanation from the FSRS state. Recall % is the lede (the
    /// scheduler targets ~90% retention); lapses and maturity add context.
    public static func reason(retrievability: Double, stability: Double, lapses: Int) -> String {
        let pct = Int((retrievability * 100).rounded())
        if lapses >= 1 {
            return "About \(pct)% recall now — you've slipped on it \(lapses)× before, so it comes back sooner."
        } else if stability >= 21 {
            return "About \(pct)% recall — a mature item due for its scheduled check-in."
        } else {
            return "About \(pct)% recall now, below the ~90% target — time to reinforce it."
        }
    }
}

/// Persistence-backed implementation. Review/error events are durably recorded,
/// FSRS state is scheduled on every review, and the daily queue is built here.
public final class LiveLearnerModelService: LearnerModelService {
    private let db: DatabaseManager
    private let fsrs: FSRS

    /// Default new-items-per-day cap for the queue builder (§4.5).
    public static let defaultNewItemsPerDay = 8
    /// Once `recognitionReading` stability exceeds this (days), the queue biases
    /// toward production dimensions for that item (§3.3, "60/40 production").
    static let productionBiasStabilityThresholdDays: Double = 7

    public init(db: DatabaseManager, parameters: FSRSParameters = .default) {
        self.db = db
        self.fsrs = FSRS(parameters: parameters)
    }

    // MARK: - Reporting evidence

    public func report(_ event: ReviewEvent) async throws {
        let record = ReviewEventRecord(event)
        let scheduler = fsrs
        try await db.write { db in
            // Append-only review log (feeds later FSRS optimization).
            try record.insert(db)
            // Upsert FSRS state for this (item, dimension).
            let existing = try SkillStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM skill_state WHERE item_id = ? AND dimension = ?",
                arguments: [event.itemID.rawValue, event.dimension.rawValue]
            )
            let current = try existing?.asSkillState()
                ?? SkillState(itemID: event.itemID, dimension: event.dimension)
            let updated = scheduler.schedule(state: current, grade: event.grade, now: event.at)
            try SkillStateRecord(updated).save(db)
        }
    }

    public func report(_ event: ErrorEvent) async throws {
        // Always record the append-only error row first.
        let record = ErrorEventRecord(event)
        try await db.write { db in
            try record.insert(db)
        }
        // R8: an error on a known item feeds the SRS as a lapse. Exact id match is
        // enough for now; JMdict-lemma fallback is a later phase.
        guard let itemID = event.itemID else { return }
        let matches = try await db.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM content_item WHERE id = ?",
                arguments: [itemID.rawValue]
            ) ?? 0) > 0
        }
        guard matches else { return }
        // Errors default to the productionSpoken dimension (drills/roleplay grade there).
        let review = ReviewEvent(
            itemID: itemID,
            dimension: .productionSpoken,
            grade: .again,
            sessionID: event.sessionID,
            at: event.at
        )
        try await report(review)
    }

    // MARK: - Daily queue builder (§4.5)

    public func requestItems(count: Int, dimension: SkillDimension?) async throws -> [ContentItem] {
        guard count > 0 else { return [] }
        let now = Date()
        let scheduler = fsrs
        let newPerDay = min(Self.defaultNewItemsPerDay, count)

        let result = try await db.read { db -> QueueReadResult in
            // Predicate for a due, non-suspended dimension.
            let duePredicate = "suspended = 0 AND due IS NOT NULL AND due <= ?"

            // Due dimensions (optionally restricted to a single dimension).
            let dueStates: [SkillStateRecord]
            let dueContent: [ContentItemRecord]
            if let dimension {
                dueStates = try SkillStateRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM skill_state WHERE \(duePredicate) AND dimension = ?",
                    arguments: [now, dimension.rawValue]
                )
                dueContent = try ContentItemRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM content_item WHERE id IN (
                          SELECT DISTINCT item_id FROM skill_state WHERE \(duePredicate) AND dimension = ?
                        )
                        """,
                    arguments: [now, dimension.rawValue]
                )
            } else {
                dueStates = try SkillStateRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM skill_state WHERE \(duePredicate)",
                    arguments: [now]
                )
                dueContent = try ContentItemRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM content_item WHERE id IN (
                          SELECT DISTINCT item_id FROM skill_state WHERE \(duePredicate)
                        )
                        """,
                    arguments: [now]
                )
            }

            // All dimensions for items that have any due dimension — needed so the
            // production bias can read recognitionReading stability even when that
            // dimension is not itself due.
            let allStates = try SkillStateRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM skill_state WHERE item_id IN (
                      SELECT DISTINCT item_id FROM skill_state WHERE \(duePredicate)
                    )
                    """,
                arguments: [now]
            )

            // New items: never-studied content, frequency-ordered (nulls last).
            let newItems = try ContentItemRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM content_item
                    WHERE id NOT IN (SELECT DISTINCT item_id FROM skill_state)
                    ORDER BY frequency_rank IS NULL, frequency_rank
                    LIMIT ?
                    """,
                arguments: [newPerDay]
            )

            return QueueReadResult(
                dueStates: dueStates,
                allStates: allStates,
                dueContent: dueContent,
                newItems: newItems
            )
        }

        // --- Rank due reviews (Swift-side: retrievability + weakest/production dimension).
        func retrievability(_ s: SkillStateRecord) -> Double {
            guard let stability = s.stability, let last = s.lastReview else { return 0 }
            let elapsed = max(0, now.timeIntervalSince(last) / 86_400)
            return scheduler.retrievability(elapsedDays: elapsed, stability: stability)
        }

        var dueByItem: [String: [SkillStateRecord]] = [:]
        for s in result.dueStates { dueByItem[s.itemID, default: []].append(s) }
        var allByItem: [String: [SkillStateRecord]] = [:]
        for s in result.allStates { allByItem[s.itemID, default: []].append(s) }
        var contentByID: [String: ContentItemRecord] = [:]
        for c in result.dueContent { contentByID[c.id] = c }

        var dueEntries: [QueueEntry] = []
        for (itemID, dims) in dueByItem {
            guard let rec = contentByID[itemID], let item = try? rec.asContentItem() else { continue }
            let chosen: SkillStateRecord
            if dimension == nil {
                // Production bias: once recognitionReading is durable (> 7d), prefer a
                // due production dimension over recognition for this item (§3.3). The
                // strict 60/40 stochastic split is applied at drill-selection time in
                // the modes; here the queue enforces the qualitative production gate.
                let recStability = allByItem[itemID]?
                    .first { $0.dimension == SkillDimension.recognitionReading.rawValue }?
                    .stability
                let productionDims = dims.filter {
                    $0.dimension == SkillDimension.productionWritten.rawValue
                        || $0.dimension == SkillDimension.productionSpoken.rawValue
                }
                if let recStability, recStability > Self.productionBiasStabilityThresholdDays,
                   let weakestProduction = productionDims.min(by: { retrievability($0) < retrievability($1) }) {
                    chosen = weakestProduction
                } else if let weakest = dims.min(by: { retrievability($0) < retrievability($1) }) {
                    chosen = weakest
                } else {
                    continue
                }
            } else {
                // Dimension pinned: at most one due row per item.
                guard let only = dims.first else { continue }
                chosen = only
            }
            dueEntries.append(QueueEntry(item: item, kind: rec.kind, isNew: false, sortKey: retrievability(chosen)))
        }
        // Most overdue / lowest retrievability first.
        dueEntries.sort { $0.sortKey < $1.sortKey }

        // --- New items keep their frequency order (already sorted by SQL).
        let newEntries = result.newItems.compactMap { rec -> QueueEntry? in
            guard let item = try? rec.asContentItem() else { return nil }
            return QueueEntry(item: item, kind: rec.kind, isNew: true, sortKey: .infinity)
        }

        // Due before new, then interleave so no two consecutive items share a kind (§3.3).
        let ordered = dueEntries + newEntries
        return interleaveAvoidingConsecutiveKind(ordered, limit: count).map { $0.item }
    }

    // MARK: - Dashboard queries

    public func trackedItemCount() async throws -> Int {
        try await db.read { db in
            try SkillStateRecord.fetchCount(db)
        }
    }

    public func dueCount(now: Date) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM skill_state WHERE suspended = 0 AND due IS NOT NULL AND due <= ?",
                arguments: [now]
            ) ?? 0
        }
    }

    public func masteryCounts() async throws -> MasterySummary {
        let states = try await db.read { db in
            try SkillStateRecord.fetchAll(db, sql: "SELECT * FROM skill_state WHERE stability IS NOT NULL")
        }
        var byDimension: [SkillDimension: MasteryBandCounts] = [:]
        var total = MasteryBandCounts()
        for record in states {
            guard let dimension = SkillDimension(rawValue: record.dimension),
                  let stability = record.stability else { continue }
            var counts = byDimension[dimension] ?? MasteryBandCounts()
            if stability < 2 {
                counts.learning += 1; total.learning += 1
            } else if stability < 21 {
                counts.young += 1; total.young += 1
            } else {
                counts.mature += 1; total.mature += 1
            }
            byDimension[dimension] = counts
        }
        // Stable, dimension-ordered output.
        let dimensions = SkillDimension.allCases.compactMap { dim -> DimensionMastery? in
            guard let counts = byDimension[dim] else { return nil }
            return DimensionMastery(dimension: dim, counts: counts)
        }
        return MasterySummary(dimensions: dimensions, total: total)
    }

    public func weakItems(bandPrefix: String?, count: Int) async throws -> [ContentItem] {
        guard count > 0 else { return [] }
        let now = Date()
        let records = try await db.read { db -> [ContentItemRecord] in
            var sql = """
                SELECT content_item.* FROM content_item
                JOIN skill_state ON skill_state.item_id = content_item.id
                WHERE skill_state.suspended = 0 AND skill_state.due IS NOT NULL AND skill_state.due <= ?
                """
            var args: [DatabaseValueConvertible] = [now]
            if let bandPrefix {
                sql += " AND content_item.band LIKE ?"
                args.append("\(bandPrefix)%")
            }
            sql += " GROUP BY content_item.id ORDER BY MIN(skill_state.due) ASC LIMIT ?"
            args.append(count)
            return try ContentItemRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        return try records.map { try $0.asContentItem() }
    }

    public func dueExplanations(now: Date, limit: Int) async throws -> [DueExplanation] {
        guard limit > 0 else { return [] }
        let records = try await db.read { db in
            try SkillStateRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM skill_state
                    WHERE suspended = 0 AND due IS NOT NULL AND due <= ?
                      AND stability IS NOT NULL AND last_review IS NOT NULL
                    """,
                arguments: [now]
            )
        }
        let scheduler = fsrs
        let explained: [DueExplanation] = records.compactMap { r in
            guard let dim = SkillDimension(rawValue: r.dimension),
                  let stability = r.stability, let last = r.lastReview, let due = r.due else { return nil }
            let elapsed = max(0, now.timeIntervalSince(last) / 86_400)
            let ret = scheduler.retrievability(elapsedDays: elapsed, stability: stability)
            return DueExplanation(
                itemID: ItemID(rawValue: r.itemID), dimension: dim,
                retrievability: ret, stability: stability, due: due, reps: r.reps, lapses: r.lapses,
                headline: DueExplanation.reason(retrievability: ret, stability: stability, lapses: r.lapses)
            )
        }
        // Most-forgotten (lowest retrievability) first — the inspector's natural order.
        return Array(explained.sorted { $0.retrievability < $1.retrievability }.prefix(limit))
    }

    public func weakAreaGrid() async throws -> WeakAreaGrid {
        // Aggregate inside the read (GRDB `Row` isn't Sendable, so it can't escape).
        // Buckets reuse the §3.3 learning/young/mature thresholds (< 2d / < 21d / ≥ 21d).
        try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT content_item.band AS band, skill_state.dimension AS dim, skill_state.stability AS stability
                FROM skill_state
                JOIN content_item ON content_item.id = skill_state.item_id
                WHERE skill_state.stability IS NOT NULL AND content_item.band IS NOT NULL
                """)
            var agg: [String: [SkillDimension: MasteryBandCounts]] = [:]
            var bandsSeen = Set<String>()
            var dimsSeen = Set<SkillDimension>()
            for row in rows {
                guard let band = row["band"] as String?,
                      let dimRaw = row["dim"] as String?,
                      let dim = SkillDimension(rawValue: dimRaw) else { continue }
                let stability = (row["stability"] as Double?) ?? 0
                bandsSeen.insert(band); dimsSeen.insert(dim)
                var counts = agg[band]?[dim] ?? MasteryBandCounts()
                if stability < 2 { counts.learning += 1 }
                else if stability < 21 { counts.young += 1 }
                else { counts.mature += 1 }
                agg[band, default: [:]][dim] = counts
            }
            let bands = bandsSeen.sorted()
            let dimensions = SkillDimension.allCases.filter { dimsSeen.contains($0) }
            let cells = bands.flatMap { band in
                dimensions.compactMap { dim -> AreaCell? in
                    guard let counts = agg[band]?[dim] else { return nil }
                    return AreaCell(band: band, dimension: dim, counts: counts)
                }
            }
            return WeakAreaGrid(bands: bands, dimensions: dimensions, cells: cells)
        }
    }

    // MARK: - Queue helpers

    private struct QueueEntry {
        let item: ContentItem
        let kind: String
        let isNew: Bool
        let sortKey: Double
    }

    private struct QueueReadResult: Sendable {
        var dueStates: [SkillStateRecord]
        var allStates: [SkillStateRecord]
        var dueContent: [ContentItemRecord]
        var newItems: [ContentItemRecord]
    }

    /// Greedy interleave that preserves priority order while avoiding two
    /// consecutive entries of the same `kind`. When every remaining candidate
    /// matches the last kind, it falls back to the highest-priority one.
    private func interleaveAvoidingConsecutiveKind(_ ordered: [QueueEntry], limit: Int) -> [QueueEntry] {
        var pool = ordered
        var result: [QueueEntry] = []
        var lastKind: String? = nil
        while !pool.isEmpty, result.count < limit {
            if let index = pool.firstIndex(where: { $0.kind != lastKind }) {
                let entry = pool.remove(at: index)
                result.append(entry)
                lastKind = entry.kind
            } else {
                let entry = pool.removeFirst()
                result.append(entry)
                lastKind = entry.kind
            }
        }
        return result
    }
}

// MARK: - In-memory mock

/// In-memory mock for tests and previews. FSRS-free: records evidence and serves
/// a fixed item list; dashboard queries return trivial values.
public final class MockLearnerModelService: LearnerModelService, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ContentItem]
    private var _reviewEvents: [ReviewEvent] = []
    private var _errorEvents: [ErrorEvent] = []

    public var reviewEvents: [ReviewEvent] { synced { _reviewEvents } }
    public var errorEvents: [ErrorEvent] { synced { _errorEvents } }

    public init(items: [ContentItem] = []) {
        self.items = items
    }

    public func requestItems(count: Int, dimension: SkillDimension?) async throws -> [ContentItem] {
        synced { Array(items.prefix(count)) }
    }

    public func report(_ event: ReviewEvent) async throws {
        synced { _reviewEvents.append(event) }
    }

    public func report(_ event: ErrorEvent) async throws {
        synced { _errorEvents.append(event) }
    }

    public func trackedItemCount() async throws -> Int {
        synced { items.count }
    }

    public func dueCount(now: Date) async throws -> Int {
        0
    }

    public func masteryCounts() async throws -> MasterySummary {
        MasterySummary(dimensions: [], total: MasteryBandCounts())
    }

    // Config knobs read inside `weakItems`/`dueExplanations` on an async executor
    // thread. They MUST be written under the same lock they're read under —
    // otherwise the unsynchronized write may not be visible to the reader thread
    // (an @unchecked-Sendable data race). Backed by locked storage, not bare vars.
    private var _weakItemsToReturn: [ContentItem] = []
    public var weakItemsToReturn: [ContentItem] {
        get { synced { _weakItemsToReturn } }
        set { synced { _weakItemsToReturn = newValue } }
    }

    private var _dueExplanationsToReturn: [DueExplanation] = []
    public var dueExplanationsToReturn: [DueExplanation] {
        get { synced { _dueExplanationsToReturn } }
        set { synced { _dueExplanationsToReturn = newValue } }
    }

    public func dueExplanations(now: Date, limit: Int) async throws -> [DueExplanation] {
        synced { Array(_dueExplanationsToReturn.prefix(limit)) }
    }

    private var _weakAreaGridToReturn = WeakAreaGrid(bands: [], dimensions: [], cells: [])
    public var weakAreaGridToReturn: WeakAreaGrid {
        get { synced { _weakAreaGridToReturn } }
        set { synced { _weakAreaGridToReturn = newValue } }
    }
    public func weakAreaGrid() async throws -> WeakAreaGrid {
        synced { _weakAreaGridToReturn }
    }

    public func weakItems(bandPrefix: String?, count: Int) async throws -> [ContentItem] {
        synced { Array(_weakItemsToReturn.prefix(count)) }
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
