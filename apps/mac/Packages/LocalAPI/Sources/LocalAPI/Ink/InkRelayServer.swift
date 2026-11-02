import FlyingFox
import Foundation

public final class InkRelayServer: @unchecked Sendable {
    public static let maxViewerMessage = 64 * 1024
    static let maxFails = 5
    static let blockSeconds: TimeInterval = 60
    static let authTimeout: Duration = .seconds(10)

    public let port: UInt16

    public var onChange: (@Sendable (InkBoard) -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public var onViewerCountChange: (@Sendable (Int) -> Void)? {
        get { lock.withLock { countHandler } }
        set { lock.withLock { countHandler = newValue } }
    }

    private struct Viewer {
        var continuation: AsyncStream<WSMessage>.Continuation
    }

    private struct Failure {
        var count = 0
        var blockedUntil = Date.distantPast
    }

    private let lock = NSLock()
    private var pin: String
    private var board = InkBoard()
    private var view = (w: 16.0, h: 9.0)
    private var region = InkRegion.full
    private var lastFrame: Data?
    private var viewers: [String: Viewer] = [:]
    private var failures: [String: Failure] = [:]
    private var sequence = 0
    private var changeHandler: (@Sendable (InkBoard) -> Void)?
    private var countHandler: (@Sendable (Int) -> Void)?

    private let http: HTTPServer

    public init(port: UInt16, pin: String) {
        self.port = port
        self.pin = pin
        self.http = HTTPServer(port: port)
    }

    public func setPIN(_ newPIN: String) {
        let dropped: [Viewer] = lock.withLock {
            pin = newPIN
            let all = Array(viewers.values)
            viewers.removeAll()
            return all
        }
        for viewer in dropped { viewer.continuation.finish() }
        if !dropped.isEmpty { countHandler?(0) }
    }

    public func run() async throws {
        await registerRoutes()
        try await http.run()
    }

    public func waitUntilListening() async throws {
        try await http.waitUntilListening()
    }

    public func stop() async {
        let all: [Viewer] = lock.withLock {
            let all = Array(viewers.values)
            viewers.removeAll()
            return all
        }
        for viewer in all { viewer.continuation.finish() }
        await http.stop(timeout: 1)
    }

    public var viewerCount: Int { lock.withLock { viewers.count } }

    public var snapshot: InkBoard { lock.withLock { board } }

    public func clear() {
        mutate { board in
            guard !board.strokes.isEmpty else { return nil }
            board.clear()
            return (["t": "clear"], nil)
        }
    }

    public func undo() {
        mutate { board in
            guard let id = board.undo() else { return nil }
            return (["t": "undo", "id": id], nil)
        }
    }

    public func setHidden(_ hidden: Bool) {
        mutate { board in
            guard board.setHidden(hidden) else { return nil }
            return (["t": "hidden", "v": hidden], nil)
        }
    }

    public func setView(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let changed: Bool = lock.withLock {
            guard view.w != width || view.h != height else { return false }
            view = (width, height)
            return true
        }
        if changed { broadcast(["t": "view", "w": width, "h": height], except: nil) }
    }

    public var drawRegion: InkRegion { lock.withLock { region } }

    public func setRegion(_ next: InkRegion) {
        let changed: Bool = lock.withLock {
            guard region != next else { return false }
            region = next
            return true
        }
        if changed {
            broadcast(
                ["t": "region", "x": next.x, "y": next.y, "w": next.width, "h": next.height],
                except: nil)
        }
    }

    public func sendFrame(jpeg: Data) {
        let targets: [Viewer] = lock.withLock {
            lastFrame = jpeg
            return Array(viewers.values)
        }
        for viewer in targets { viewer.continuation.yield(.data(jpeg)) }
    }

    private func mutate(_ change: (inout InkBoard) -> ([String: Any], String?)?) {
        let result: (message: [String: Any], except: String?, board: InkBoard)? = lock.withLock {
            guard let (message, except) = change(&board) else { return nil }
            return (message, except, board)
        }
        guard let result else { return }
        broadcast(result.message, except: result.except)
        changeHandler?(result.board)
    }

    private func broadcast(_ message: [String: Any], except: String?) {
        guard let text = Self.encode(message) else { return }
        let targets: [Viewer] = lock.withLock {
            viewers.filter { $0.key != except }.map(\.value)
        }
        for viewer in targets { viewer.continuation.yield(.text(text)) }
    }

    static func encode(_ message: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func registerRoutes() async {
        await http.appendRoute(HTTPRoute("GET /")) { _ in
            guard let page = Self.pageData() else { return HTTPResponse(statusCode: .internalServerError) }
            return HTTPResponse(
                statusCode: .ok,
                headers: [
                    HTTPHeader("Content-Type"): "text/html; charset=utf-8",
                    HTTPHeader("Cache-Control"): "no-store",
                    HTTPHeader("X-Content-Type-Options"): "nosniff",
                ],
                body: page
            )
        }
        await http.appendRoute(HTTPRoute("GET /ws")) { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            if let origin = request.headers[HTTPHeader("Origin")] {
                let originHost = URLComponents(string: origin)?.host.map { host -> String in
                    let port = URLComponents(string: origin)?.port.map { ":\($0)" } ?? ""
                    return host + port
                }
                let host = request.headers[.host]
                guard originHost == host else { return HTTPResponse(statusCode: .forbidden) }
            }
            let address = request.remoteAddress.map { "\($0)" } ?? "unknown"
            let handler = InkViewerHandler(server: self, address: address)
            let socket = WebSocketHTTPHandler(handler: MessageFrameWSHandler(handler: handler))
            return try await socket.handleRequest(request)
        }
    }

    static func pageData() -> Data? {
        guard let url = Bundle.module.url(forResource: "ink", withExtension: "html") else { return nil }
        return try? Data(contentsOf: url)
    }

    fileprivate func login(
        pin attempt: String, address: String,
        continuation: AsyncStream<WSMessage>.Continuation
    ) -> (id: String, state: [String: Any], frame: Data?)? {
        let outcome: (id: String, state: [String: Any], frame: Data?)?? = lock.withLock {
            var failure = failures[address] ?? Failure()
            if Date() < failure.blockedUntil { return .some(nil) }
            guard Self.constantTimeEqual(attempt, pin) else {
                failure.count += 1
                if failure.count >= Self.maxFails {
                    failure.count = 0
                    failure.blockedUntil = Date().addingTimeInterval(Self.blockSeconds)
                }
                failures[address] = failure
                return .none
            }
            failures[address] = nil
            sequence += 1
            let id = "c\(sequence)"
            viewers[id] = Viewer(continuation: continuation)
            return .some((id, stateMessage(), lastFrame))
        }
        switch outcome {
        case .none, .some(.none): return nil
        case .some(.some(let value)):
            countHandler?(viewerCount)
            return value
        }
    }

    fileprivate func isBlocked(address: String) -> Bool {
        lock.withLock { Date() < (failures[address]?.blockedUntil ?? .distantPast) }
    }

    fileprivate func detach(id: String) {
        let (removed, board): (Bool, InkBoard?) = lock.withLock {
            guard viewers.removeValue(forKey: id) != nil else { return (false, nil) }
            let closed = self.board.closeStrokes(withPrefix: id + ".")
            return (true, closed.isEmpty ? nil : self.board)
        }
        guard removed else { return }
        countHandler?(viewerCount)
        if let board { changeHandler?(board) }
    }

    fileprivate func receive(_ message: [String: Any], from id: String) {
        guard let type = message["t"] as? String else { return }
        switch type {
        case "ss":
            guard var stroke = Self.stroke(from: message, viewer: id) else { return }
            stroke.points = drawRegion.clamp(stroke.points)
            mutate { board in
                guard board.begin(stroke) else { return nil }
                var out = message
                out["t"] = "ss"
                out["p"] = board.strokes.last(where: { $0.id == stroke.id })?.points ?? []
                return (out, id)
            }
        case "sp":
            guard let strokeID = message["id"] as? String, strokeID.hasPrefix(id + "."),
                  let raw = message["p"] as? [Any]
            else { return }
            let points = drawRegion.clamp(raw.compactMap { ($0 as? NSNumber)?.doubleValue })
            mutate { board in
                guard let added = board.append(id: strokeID, points: points) else { return nil }
                return (["t": "sp", "id": strokeID, "p": added], id)
            }
        case "se":
            guard let strokeID = message["id"] as? String, strokeID.hasPrefix(id + ".") else { return }
            mutate { board in
                guard board.end(id: strokeID) else { return nil }
                return (["t": "se", "id": strokeID], id)
            }
        case "cmd":
            switch message["c"] as? String {
            case "clear": clear()
            case "undo": undo()
            case "hide": setHidden(true)
            case "show": setHidden(false)
            default: break
            }
        default:
            break
        }
    }

    static func stroke(from message: [String: Any], viewer: String) -> InkStroke? {
        guard let id = message["id"] as? String, id.count <= 40, id.hasPrefix(viewer + "."),
              let color = message["c"] as? String, isHexColor(color),
              let width = (message["w"] as? NSNumber)?.doubleValue, (0 ... 0.25).contains(width),
              let alpha = (message["a"] as? NSNumber)?.doubleValue, (0 ... 1).contains(alpha),
              let cap = message["cap"] as? String, cap == "round" || cap == "butt",
              let raw = message["p"] as? [Any]
        else { return nil }
        let glow = (message["g"] as? NSNumber)?.doubleValue ?? 0
        guard (0 ... 0.1).contains(glow) else { return nil }
        let erase = ((message["e"] as? NSNumber)?.intValue ?? 0) != 0
        let points = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        return InkStroke(
            id: id, colorHex: color.lowercased(), width: width, alpha: alpha,
            roundCap: cap == "round", glow: glow, erase: erase, points: points
        )
    }

    static func isHexColor(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#" else { return false }
        return scalars.dropFirst().allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) || ("A" ... "F").contains($0) }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var diff = a.count ^ b.count
        for index in 0 ..< max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    private func stateMessage() -> [String: Any] {
        let strokes: [[String: Any]] = board.strokes.map { stroke in
            [
                "id": stroke.id, "c": stroke.colorHex, "w": stroke.width, "a": stroke.alpha,
                "cap": stroke.roundCap ? "round" : "butt", "g": stroke.glow,
                "e": stroke.erase ? 1 : 0, "p": stroke.points, "open": stroke.isOpen,
            ]
        }
        return [
            "t": "state", "view": ["w": view.w, "h": view.h],
            "region": ["x": region.x, "y": region.y, "w": region.width, "h": region.height],
            "hidden": board.hidden, "strokes": strokes,
        ]
    }
}

private final class InkViewerState: @unchecked Sendable {
    private let lock = NSLock()
    private var viewerID: String?

    var id: String? {
        get { lock.withLock { viewerID } }
        set { lock.withLock { viewerID = newValue } }
    }
}

private struct InkViewerHandler: WSMessageHandler {
    let server: InkRelayServer
    let address: String

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        let (output, continuation) = AsyncStream<WSMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let state = InkViewerState()
        let server = self.server
        let address = self.address

        let timeout = Task {
            try? await Task.sleep(for: InkRelayServer.authTimeout)
            if state.id == nil { continuation.finish() }
        }

        let input = Task {
            for await message in client {
                guard case .text(let text) = message,
                      text.utf8.count <= InkRelayServer.maxViewerMessage,
                      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                      let dictionary = object as? [String: Any]
                else { continue }
                if let id = state.id {
                    if dictionary["t"] as? String == "login" { continue }
                    server.receive(dictionary, from: id)
                    continue
                }
                guard dictionary["t"] as? String == "login" else { continue }
                if server.isBlocked(address: address) {
                    Self.send(["t": "auth", "ok": false, "error": "Too many attempts. Wait a minute."], to: continuation)
                    continue
                }
                let attempt = dictionary["pin"] as? String ?? ""
                if let accepted = server.login(pin: attempt, address: address, continuation: continuation) {
                    state.id = accepted.id
                    timeout.cancel()
                    Self.send(["t": "auth", "ok": true, "id": accepted.id, "host": true], to: continuation)
                    Self.send(accepted.state, to: continuation)
                    if let frame = accepted.frame { continuation.yield(.data(frame)) }
                } else {
                    Self.send(["t": "auth", "ok": false, "error": "Wrong PIN"], to: continuation)
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            timeout.cancel()
            input.cancel()
            if let id = state.id { server.detach(id: id) }
        }
        return output
    }

    private static func send(
        _ message: [String: Any], to continuation: AsyncStream<WSMessage>.Continuation
    ) {
        guard let text = InkRelayServer.encode(message) else { return }
        continuation.yield(.text(text))
    }
}
