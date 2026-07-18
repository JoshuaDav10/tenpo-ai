import Foundation

/// Registry of available modes (§4.6). Modes register their type; the Home
/// screen and SessionRunner discover them from here.
public struct ModeRegistry: Sendable {
    private var modes: [String: any LearningMode.Type] = [:]

    public init() {}

    public mutating func register(_ mode: any LearningMode.Type) {
        modes[mode.descriptor.id] = mode
    }

    public func mode(id: String) -> (any LearningMode.Type)? {
        modes[id]
    }

    public var descriptors: [ModeDescriptor] {
        modes.values.map { $0.descriptor }.sorted { $0.id < $1.id }
    }
}
