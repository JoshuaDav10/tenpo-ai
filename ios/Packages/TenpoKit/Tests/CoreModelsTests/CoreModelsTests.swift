import Testing
import Foundation
@testable import CoreModels

@Suite struct ReviewGradeTests {
    @Test func gradeRawValuesMatchSchema() {
        // §4.7: review_event.grade — 1 Again 2 Hard 3 Good 4 Easy
        #expect(ReviewGrade.again.rawValue == 1)
        #expect(ReviewGrade.hard.rawValue == 2)
        #expect(ReviewGrade.good.rawValue == 3)
        #expect(ReviewGrade.easy.rawValue == 4)
    }
}

@Suite struct JSONValueTests {
    @Test func roundTripsThroughCodable() throws {
        let value: JSONValue = .object([
            "goal_id": .string("g2"),
            "completed": .bool(true),
            "evidence_turn": .number(7),
            "notes": .null,
            "tags": .array([.string("particle"), .string("register")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded["goal_id"]?.stringValue == "g2")
    }
}

@Suite struct MockChatProviderTests {
    @Test func structuredOutputDecodesCannedJSON() async throws {
        struct Verdict: Decodable {
            let sceneControl: String
            enum CodingKeys: String, CodingKey { case sceneControl = "scene_control" }
        }
        let mock = MockChatProvider()
        mock.setCanned(json: Data(#"{"scene_control":"continue"}"#.utf8), for: "director_turn")
        let verdict = try await mock.completeStructured(
            ChatRequest(templateID: "director_turn"),
            schema: JSONSchema(.object([:])),
            as: Verdict.self
        )
        #expect(verdict.sceneControl == "continue")
    }
}

@Suite struct CostGovernorTests {
    let caps = CostCaps.dogfoodDefault // soft 2.50, hard 5.00

    @Test func fullExperienceBelowSoftCap() {
        let gov = CostGovernor(caps: caps, forceCheapMode: false)
        #expect(gov.policy(todaySpendUSD: 0) == .full)
        #expect(gov.policy(todaySpendUSD: 2.49) == .full)
        #expect(gov.policy(todaySpendUSD: 0).roleplayPipeline == .realtime)
    }

    @Test func softCapForcesCheapMode() {
        let gov = CostGovernor(caps: caps, forceCheapMode: false)
        #expect(gov.policy(todaySpendUSD: 2.50) == .cheapMode)
        #expect(gov.policy(todaySpendUSD: 4.99) == .cheapMode)
        // Cheap mode still lets a roleplay start, on the cascade pipeline.
        #expect(gov.policy(todaySpendUSD: 3.00).allowsNewRoleplay)
        #expect(gov.policy(todaySpendUSD: 3.00).roleplayPipeline == .cascade)
    }

    @Test func hardCapAllowsDrillsOnly() {
        let gov = CostGovernor(caps: caps, forceCheapMode: false)
        #expect(gov.policy(todaySpendUSD: 5.00) == .drillsOnly)
        #expect(gov.policy(todaySpendUSD: 42) == .drillsOnly)
        #expect(gov.policy(todaySpendUSD: 5.00).allowsNewRoleplay == false)
    }

    @Test func manualToggleOnlyTightens() {
        let gov = CostGovernor(caps: caps, forceCheapMode: true)
        // Below soft cap, the manual toggle still forces cheap mode.
        #expect(gov.policy(todaySpendUSD: 0) == .cheapMode)
        // It never loosens: past the hard cap it is still drills-only.
        #expect(gov.policy(todaySpendUSD: 6) == .drillsOnly)
    }

    @Test func pipelineMapping() {
        #expect(CostPolicy.full.roleplayPipeline == .realtime)
        #expect(CostPolicy.cheapMode.roleplayPipeline == .cascade)
        #expect(CostPolicy.drillsOnly.roleplayPipeline == .cascade)
    }

    @Test func serverUsageDrivesPolicyFromProxyFlags() {
        let gov = CostGovernor(caps: caps, forceCheapMode: false)
        let under = ServerUsage(spentUSD: 1.0, softCapUSD: 2.5, hardCapUSD: 5, overSoftCap: false, overHardCap: false)
        let soft = ServerUsage(spentUSD: 3.0, softCapUSD: 2.5, hardCapUSD: 5, overSoftCap: true, overHardCap: false)
        let hard = ServerUsage(spentUSD: 6.0, softCapUSD: 2.5, hardCapUSD: 5, overSoftCap: true, overHardCap: true)
        #expect(gov.policy(serverUsage: under) == .full)
        #expect(gov.policy(serverUsage: soft) == .cheapMode)
        #expect(gov.policy(serverUsage: hard) == .drillsOnly)
        // Manual toggle still only tightens.
        #expect(CostGovernor(caps: caps, forceCheapMode: true).policy(serverUsage: under) == .cheapMode)
    }

    @Test func serverUsageDecodesFromProxyJSONShape() throws {
        // Exactly the payload shape the server's GET /usage returns (extra keys ignored).
        let json = Data("""
        {"userId":"dev","day":"2026-07-12","spentUSD":3.25,"softCapUSD":2.5,"hardCapUSD":5.0,"overSoftCap":true,"overHardCap":false}
        """.utf8)
        let usage = try JSONDecoder().decode(ServerUsage.self, from: json)
        #expect(usage.spentUSD == 3.25)
        #expect(usage.overSoftCap == true)
        #expect(usage.overHardCap == false)
    }
}
