import Foundation

/// Deterministic mock for tests and Phase 0 app boot. Returns canned responses
/// keyed by template id; structured calls decode canned JSON.
public final class MockChatProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cannedText: [String: String]
    private var cannedJSON: [String: Data]
    private var _requests: [ChatRequest] = []

    public var requests: [ChatRequest] {
        synced { _requests }
    }

    public init(cannedText: [String: String] = [:], cannedJSON: [String: Data] = [:]) {
        self.cannedText = cannedText
        self.cannedJSON = cannedJSON
    }

    public func setCanned(text: String, for templateID: String) {
        synced { cannedText[templateID] = text }
    }

    public func setCanned(json: Data, for templateID: String) {
        synced { cannedJSON[templateID] = json }
    }

    public func complete(_ req: ChatRequest) async throws -> ChatResponse {
        let text = synced {
            _requests.append(req)
            return cannedText[req.templateID] ?? "[mock:\(req.templateID)]"
        }
        return ChatResponse(text: text, provider: "mock:chat")
    }

    public func completeStructured<T: Decodable>(
        _ req: ChatRequest, schema: JSONSchema, as type: T.Type
    ) async throws -> T {
        let data = synced { () -> Data? in
            _requests.append(req)
            return cannedJSON[req.templateID]
        }
        guard let data else {
            throw MockProviderError.noCannedResponse(templateID: req.templateID)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func synced<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public enum MockProviderError: Error, Sendable {
    case noCannedResponse(templateID: String)
}
