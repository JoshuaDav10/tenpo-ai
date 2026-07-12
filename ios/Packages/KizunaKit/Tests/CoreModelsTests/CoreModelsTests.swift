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
