import Foundation
import CoreModels

/// LLM access via the proxy's `POST /chat` (§4.3.2). The client names a server-side
/// template by id; for structured calls the *template* carries the JSON schema
/// (director_turn §4.4), so the request wire shape is identical — the server returns
/// a `structured` field when the template demands one. The `schema:` parameter is
/// therefore not transmitted; it exists so callers state the shape they expect.
public struct ProxyChatProvider: ChatProvider {
    let client: ProxyClient

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.client = ProxyClient(config: config, session: session)
    }

    struct Request: Encodable {
        let template_id: String
        let variables: [String: JSONValue]
        let messages: [ChatMessage]
    }
    struct Response: Decodable {
        let text: String?
        let provider: String
        let inputTokens: Int?
        let outputTokens: Int?
    }
    struct StructuredResponse<T: Decodable>: Decodable {
        let structured: T
    }

    private func request(_ req: ChatRequest) -> Request {
        Request(template_id: req.templateID, variables: req.variables, messages: req.messages)
    }

    public func complete(_ req: ChatRequest) async throws -> ChatResponse {
        let res: Response = try await client.post("chat", body: request(req), as: Response.self)
        return ChatResponse(
            text: res.text ?? "", provider: ProviderID(rawValue: res.provider),
            inputTokens: res.inputTokens, outputTokens: res.outputTokens
        )
    }

    public func completeStructured<T: Decodable>(
        _ req: ChatRequest, schema: JSONSchema, as type: T.Type
    ) async throws -> T {
        let res: StructuredResponse<T> = try await client.post(
            "chat", body: request(req), as: StructuredResponse<T>.self)
        return res.structured
    }
}
