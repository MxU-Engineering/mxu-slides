import Foundation
import Testing
@testable import LocalAPI

@Suite(.serialized) struct InkRelayServerTests {
    private final class Client {
        let task: URLSessionWebSocketTask

        init(port: UInt16) {
            task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            task.resume()
        }

        func send(_ object: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        }

        func next() async throws -> [String: Any] {
            while true {
                let message = try await task.receive()
                if case .string(let text) = message,
                   let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    return object
                }
            }
        }

        func next(type: String) async throws -> [String: Any] {
            while true {
                let message = try await next()
                if message["t"] as? String == type { return message }
            }
        }
    }

    private func start(pin: String = "4242") async throws -> (InkRelayServer, UInt16, Task<Void, Error>) {
        for _ in 0 ..< 20 {
            let port = UInt16.random(in: 20000 ... 40000)
            let server = InkRelayServer(port: port, pin: pin)
            let task = Task { try await server.run() }
            do {
                try await server.waitUntilListening()
                return (server, port, task)
            } catch {
                task.cancel()
            }
        }
        throw CancellationError()
    }

    @Test func wrongPINIsRefusedAndRightPINJoins() async throws {
        let (server, port, task) = try await start()
        defer { task.cancel() }

        let bad = Client(port: port)
        try await bad.send(["t": "login", "pin": "0000"])
        let refusal = try await bad.next(type: "auth")
        #expect(refusal["ok"] as? Bool == false)

        let good = Client(port: port)
        try await good.send(["t": "login", "pin": "4242"])
        let accepted = try await good.next(type: "auth")
        #expect(accepted["ok"] as? Bool == true)
        let state = try await good.next(type: "state")
        #expect((state["strokes"] as? [Any])?.isEmpty == true)
        await server.stop()
    }

    @Test func strokesRelayToOtherViewersAndCommandsApply() async throws {
        let (server, port, task) = try await start()
        defer { task.cancel() }

        let a = Client(port: port), b = Client(port: port)
        try await a.send(["t": "login", "pin": "4242"])
        let idA = try await a.next(type: "auth")["id"] as? String ?? ""
        _ = try await a.next(type: "state")
        try await b.send(["t": "login", "pin": "4242"])
        _ = try await b.next(type: "state")

        try await a.send([
            "t": "ss", "id": "\(idA).1", "c": "#ff3b30", "w": 0.01, "a": 1, "cap": "round",
            "g": 0, "e": 0, "p": [0.1, 0.1],
        ])
        let relayed = try await b.next(type: "ss")
        #expect(relayed["id"] as? String == "\(idA).1")
        try await a.send(["t": "sp", "id": "\(idA).1", "p": [0.2, 0.2, 0.3, 0.3]])
        _ = try await b.next(type: "sp")
        try await a.send(["t": "se", "id": "\(idA).1"])
        _ = try await b.next(type: "se")

        let board = server.snapshot
        #expect(board.strokes.count == 1)
        #expect(board.strokes[0].points.count == 6)
        #expect(!board.strokes[0].isOpen)

        try await a.send(["t": "cmd", "c": "hide"])
        let hidden = try await b.next(type: "hidden")
        #expect(hidden["v"] as? Bool == true)
        #expect(server.snapshot.hidden)

        server.clear()
        _ = try await b.next(type: "clear")
        #expect(server.snapshot.strokes.isEmpty)
        await server.stop()
    }

    @Test func spoofedStrokeIDsAreIgnored() async throws {
        let (server, port, task) = try await start()
        defer { task.cancel() }

        let a = Client(port: port)
        try await a.send(["t": "login", "pin": "4242"])
        _ = try await a.next(type: "state")
        try await a.send([
            "t": "ss", "id": "c999.1", "c": "#ff3b30", "w": 0.01, "a": 1, "cap": "round",
            "g": 0, "e": 0, "p": [0.1, 0.1],
        ])
        try await a.send(["t": "cmd", "c": "hide"])
        _ = try await a.next(type: "hidden")
        #expect(server.snapshot.strokes.isEmpty)
        await server.stop()
    }
}
