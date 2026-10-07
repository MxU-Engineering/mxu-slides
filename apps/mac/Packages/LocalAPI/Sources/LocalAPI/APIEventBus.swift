import Foundation

public enum APITopic: String, Codable, CaseIterable, Sendable {
    case show
    case timers
    case audio
    case transport
    case outputs
    case library
    case scheduler
}

public struct APIEvent: Sendable {
    public var topic: APITopic

    public var payload: Data

    public init(topic: APITopic, payload: Data) {
        self.topic = topic
        self.payload = payload
    }
}

public actor APIEventBus {
    private var continuations: [UUID: AsyncStream<APIEvent>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<APIEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<APIEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    public func publish(_ event: APIEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func closeAll() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }
}
