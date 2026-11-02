import Foundation

public actor LocalAPIClient {
    public struct Endpoint: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var token: String

        public init(host: String, port: UInt16, token: String) {
            self.host = host
            self.port = port
            self.token = token
        }

        public var request: URLRequest {
            var request = URLRequest(url: URL(string: "ws://\(host):\(port)/v1/ws")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    public struct Policy: Sendable {
        public var maxAttempts = 10
        public var baseDelay: Duration = .milliseconds(500)
        public var maxDelay: Duration = .seconds(30)
        public var pingInterval: Duration = .seconds(1)
        public var heartbeat = HeartbeatMonitor.Limits()

        public init() {}

        public func delay(afterFailures failures: Int) -> Duration? {
            guard failures >= 1, failures < maxAttempts else { return nil }
            let doubled = baseDelay * (1 << min(failures - 1, 20))
            return min(doubled, maxDelay)
        }
    }

    public enum Health: Equatable, Sendable {
        public enum Loss: Equatable, Sendable {

            case closed

            case noAnswer

            case frozen
        }

        case connecting
        case live
        case lost(Loss)

        case gaveUp
    }

    public enum Update: Sendable {
        case health(Health)
        case event(topic: APITopic, data: Data)
    }

    public typealias Connect = @Sendable (URLRequest) async throws -> any LocalAPIClientSocket
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let endpoint: Endpoint
    private let topics: [APITopic]
    private let policy: Policy
    private let connect: Connect
    private let sleep: Sleep
    private let clock: @Sendable () -> Double

    private var runTask: Task<Void, Never>?

    private var runID = 0
    private var socket: (any LocalAPIClientSocket)?
    private var monitor: HeartbeatMonitor
    private var health: Health?
    private let continuation: AsyncStream<Update>.Continuation

    public nonisolated let updates: AsyncStream<Update>

    public init(
        endpoint: Endpoint, topics: [APITopic], policy: Policy = Policy(),
        connect: @escaping Connect = URLSessionClientSocket.connect,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.endpoint = endpoint
        self.topics = topics
        self.policy = policy
        self.connect = connect
        self.sleep = sleep
        self.clock = clock
        self.monitor = HeartbeatMonitor(limits: policy.heartbeat, now: clock())
        (updates, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public func start() {
        guard runTask == nil else { return }
        runID += 1
        let id = runID
        runTask = Task { await run(id) }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.close()
        socket = nil
    }

    private func run(_ id: Int) async {
        var failures = 0
        while !Task.isCancelled {
            report(.connecting)
            let wentLive = await session()
            if Task.isCancelled { break }
            failures = wentLive ? 1 : failures + 1
            guard let delay = policy.delay(afterFailures: failures) else {
                report(.gaveUp)
                break
            }
            if health != .lost(.noAnswer) { report(.lost(.closed)) }
            do { try await sleep(delay) } catch { break }
        }
        if runID == id { runTask = nil }
    }

    private func session() async -> Bool {
        let socket: any LocalAPIClientSocket
        do {
            socket = try await connect(endpoint.request)
            self.socket = socket
            _ = try await socket.receive()
            try await socket.send(Self.frame(["type": "subscribe", "topics": topics.map(\.rawValue)]))
        } catch {
            self.socket?.close()
            self.socket = nil
            return false
        }
        monitor = HeartbeatMonitor(limits: policy.heartbeat, now: clock())
        report(.live)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.receiveLoop(socket) }
            group.addTask { await self.pingLoop(socket) }
            await group.next()
            socket.close()
            group.cancelAll()
        }
        if self.socket === socket { self.socket = nil }
        return true
    }

    private func receiveLoop(_ socket: any LocalAPIClientSocket) async {
        while !Task.isCancelled, let text = try? await socket.receive() {
            handle(text)
        }
    }

    private func pingLoop(_ socket: any LocalAPIClientSocket) async {
        while !Task.isCancelled {
            do {
                try await sleep(policy.pingInterval)
                try await socket.send(Self.frame(["type": "ping"]))
            } catch { return }
            switch monitor.reading(at: clock()) {
            case .live: report(.live)
            case .frozen: report(.lost(.frozen))
            case .noAnswer:
                report(.lost(.noAnswer))
                return
            }
        }
    }

    private struct Inbound: Decodable {
        var type: String
        var topic: String?
        var data: JSONValue?
        var beat: UInt64?
    }

    private func handle(_ text: String) {
        guard let inbound = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else { return }
        switch inbound.type {
        case "pong":
            monitor.pong(beat: inbound.beat, at: clock())
        case "event":
            guard let topic = inbound.topic.flatMap(APITopic.init(rawValue:)), let data = inbound.data else { return }
            continuation.yield(.event(topic: topic, data: data.encoded()))
        default:
            break
        }
    }

    private func report(_ new: Health) {
        guard new != health else { return }
        health = new
        continuation.yield(.health(new))
    }

    private static func frame(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct HeartbeatMonitor: Sendable, Equatable {
    public struct Limits: Sendable, Equatable {

        public var lostAfter: Double = 3

        public var frozenAfter: Double = 2

        public init(lostAfter: Double = 3, frozenAfter: Double = 2) {
            self.lostAfter = lostAfter
            self.frozenAfter = frozenAfter
        }
    }

    public enum Reading: Equatable, Sendable { case live, noAnswer, frozen }

    public var limits: Limits
    private var lastPongAt: Double
    private var beat: UInt64?
    private var beatMovedAt: Double

    public init(limits: Limits = Limits(), now: Double) {
        self.limits = limits
        self.lastPongAt = now
        self.beatMovedAt = now
    }

    public mutating func pong(beat new: UInt64?, at now: Double) {
        lastPongAt = now
        if new != beat {
            beat = new
            beatMovedAt = now
        }
    }

    public func reading(at now: Double) -> Reading {
        if now - lastPongAt > limits.lostAfter { return .noAnswer }
        if beat != nil, lastPongAt - beatMovedAt > limits.frozenAfter { return .frozen }
        return .live
    }
}

public protocol LocalAPIClientSocket: AnyObject, Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

public final class URLSessionClientSocket: LocalAPIClientSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public static let connect: LocalAPIClient.Connect = { request in
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionClientSocket(task: task)
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
