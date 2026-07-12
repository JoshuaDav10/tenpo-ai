import Foundation

public struct ChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Request to the LLM via the proxy. The client references a server-side prompt
/// template by id and supplies variables — prompts never live on device (§7).
public struct ChatRequest: Codable, Sendable, Hashable {
    public var templateID: String
    public var variables: [String: JSONValue]
    /// Extra transcript/context messages appended after the server-side template.
    public var messages: [ChatMessage]
    public var maxTokens: Int?
    public var temperature: Double?

    public init(
        templateID: String, variables: [String: JSONValue] = [:],
        messages: [ChatMessage] = [], maxTokens: Int? = nil, temperature: Double? = nil
    ) {
        self.templateID = templateID
        self.variables = variables
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct ChatResponse: Codable, Sendable, Hashable {
    public var text: String
    public var provider: ProviderID
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(text: String, provider: ProviderID, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A JSON Schema document used to constrain structured outputs (Director verdicts §4.4).
public struct JSONSchema: Codable, Sendable, Hashable {
    public var root: JSONValue

    public init(_ root: JSONValue) {
        self.root = root
    }
}

/// §4.3.2 — text + structured-output LLM access. Client names capabilities,
/// never providers; the proxy routes (§4.3.3).
public protocol ChatProvider: Sendable {
    func complete(_ req: ChatRequest) async throws -> ChatResponse
    func completeStructured<T: Decodable>(
        _ req: ChatRequest, schema: JSONSchema, as type: T.Type
    ) async throws -> T
}
