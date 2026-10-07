import FlyingFox
import Foundation
import Testing

@testable import LocalAPI

@Suite(.timeLimit(.minutes(1)))
struct WebSocketAuthorizationTests {
    private func store() -> APITokenStore {
        APITokenStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-tokens-\(UUID().uuidString).json"))
    }

    @Test func revokedConnectionCannotExecuteCommands() async throws {
        let tokens = store()
        let token = tokens.create(name: "Remote", scope: .control).token
        let route = APIRoute("POST", "/command", scope: .control,
                            operationId: "command", summary: "Command", tag: "Test",
                            responseSchema: .object([:])) { _ in
            Issue.record("A revoked WebSocket reached the command handler")
            return .ok
        }
        let handler = APIWebSocketHandler(router: APIRouter(routes: [route]),
                                         events: APIEventBus(), token: token, tokens: tokens)
        let (input, continuation) = AsyncStream<WSMessage>.makeStream()
        defer { continuation.finish() }
        var output = try await handler.makeMessages(for: input).makeAsyncIterator()
        #expect(await output.next() != nil) // hello confirms the session was open
        tokens.revoke(id: token.id)
        continuation.yield(.text(#"{"type":"command","method":"POST","path":"/command"}"#))
        #expect(await output.next() == nil)
    }

    @Test func revokedConnectionCannotReceiveEvents() async throws {
        let tokens = store()
        let token = tokens.create(name: "Display", scope: .view).token
        let events = APIEventBus()
        let handler = APIWebSocketHandler(router: APIRouter(routes: []),
                                         events: events, token: token, tokens: tokens)
        let (input, continuation) = AsyncStream<WSMessage>.makeStream()
        defer { continuation.finish() }
        var output = try await handler.makeMessages(for: input).makeAsyncIterator()
        #expect(await output.next() != nil)
        continuation.yield(.text(#"{"type":"subscribe","topics":["show"]}"#))
        #expect(await output.next() != nil) // subscription acknowledgement
        await events.publish(APIEvent(topic: .show, payload: Data("{}".utf8)))
        #expect(await output.next() != nil) // active tokens still receive events
        tokens.revoke(id: token.id)
        await events.publish(APIEvent(topic: .show, payload: Data("{}".utf8)))
        #expect(await output.next() == nil)
    }

    @Test func viewConnectionCannotRunControlCommands() async throws {
        let tokens = store()
        let token = tokens.create(name: "Display", scope: .view).token
        let route = APIRoute("POST", "/command", scope: .control,
                            operationId: "command", summary: "Command", tag: "Test",
                            responseSchema: .object([:])) { _ in
            Issue.record("A view-only WebSocket reached the command handler")
            return .ok
        }
        let handler = APIWebSocketHandler(router: APIRouter(routes: [route]),
                                         events: APIEventBus(), token: token, tokens: tokens)
        let (input, continuation) = AsyncStream<WSMessage>.makeStream()
        defer { continuation.finish() }
        var output = try await handler.makeMessages(for: input).makeAsyncIterator()
        #expect(await output.next() != nil)
        continuation.yield(.text(#"{"type":"command","method":"POST","path":"/command"}"#))
        guard case .text(let frame) = await output.next() else {
            Issue.record("Expected a scope rejection")
            return
        }
        let result = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        #expect(result["status"] as? Int == 403)
    }

    @Test @MainActor func streamCredentialsRequireManageOverWebSocket() async throws {
        for scope in APIScope.allCases {
            let tokens = store()
            let token = tokens.create(name: "Test", scope: scope).token
            let bridge = FakeBridge()
            bridge.documents["preset"] = Data(#"{"destinations":[{"streamKey":"test-credential"}]}"#.utf8)
            let handler = APIWebSocketHandler(router: APIRouter(routes: APIRouteTable.build(bridge: bridge)),
                                             events: APIEventBus(), token: token, tokens: tokens)
            let (input, continuation) = AsyncStream<WSMessage>.makeStream()
            defer { continuation.finish() }
            var output = try await handler.makeMessages(for: input).makeAsyncIterator()
            #expect(await output.next() != nil)
            continuation.yield(.text(#"{"type":"command","method":"GET","path":"/v1/documents/stream-presets/preset"}"#))
            guard case .text(let frame) = await output.next() else {
                Issue.record("Expected a document response")
                continue
            }
            let result = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            #expect(result["status"] as? Int == (scope == .edit ? 200 : 403))
            #expect(frame.contains("test-credential") == (scope == .edit))
        }
    }

    @Test(arguments: [false, true])
    func revocationDuringCommandSuppressesResponse(fails: Bool) async throws {
        let tokens = store()
        let token = tokens.create(name: "Test", scope: .view).token
        let route = APIRoute("GET", "/document", scope: .view,
                            operationId: "document", summary: "Document", tag: "Test",
                            responseSchema: .object([:])) { _ in
            tokens.revoke(id: token.id)
            if fails { throw APIError.badRequest("sensitive error detail") }
            return .raw(Data(#"{"sensitive":"content"}"#.utf8))
        }
        let handler = APIWebSocketHandler(router: APIRouter(routes: [route]),
                                         events: APIEventBus(), token: token, tokens: tokens)
        let (input, continuation) = AsyncStream<WSMessage>.makeStream()
        defer { continuation.finish() }
        var output = try await handler.makeMessages(for: input).makeAsyncIterator()
        #expect(await output.next() != nil)
        continuation.yield(.text(#"{"type":"command","method":"GET","path":"/document"}"#))
        #expect(await output.next() == nil)
    }
}
