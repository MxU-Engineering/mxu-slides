import Foundation

@MainActor
public final class APIFireFeed {
    public static let shared = APIFireFeed()

    @TaskLocal public static var cause: Int?

    public var sink: (@Sendable (APIFireEvent) -> Void)?
    private var seq = 0
    private let clock: () -> Double

    public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    @discardableResult
    public func publish(_ event: APIFireEvent) -> Int {
        seq += 1
        guard let sink else { return seq }
        var stamped = event
        stamped.seq = seq
        stamped.at = clock()
        stamped.source = APIFireSource.current ?? APIFireSource(kind: .ui)
        stamped.cause = Self.cause
        sink(stamped)
        return seq
    }

    public nonisolated static func encode(_ event: APIFireEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(event)
    }

    public nonisolated static func decode(_ data: Data) -> APIFireEvent? {
        try? JSONDecoder().decode(APIFireEvent.self, from: data)
    }
}
