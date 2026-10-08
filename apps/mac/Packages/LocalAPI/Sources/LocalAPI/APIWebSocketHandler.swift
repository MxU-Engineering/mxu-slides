import FlyingFox
import Foundation

struct APIWebSocketHandler: WSMessageHandler {
    let router: APIRouter
    let events: APIEventBus
    let token: APIToken
    let tokens: APITokenStore

    private var scope: APIScope { token.scope }

    private var isAuthorized: Bool {
        tokens.activeToken(id: token.id)?.scope == token.scope
    }

    struct Inbound: Decodable {
        var type: String
        var topics: [String]?
        var id: String?
        var method: String?
        var path: String?
        var body: JSONValue?
    }

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        let (output, continuation) = AsyncStream<WSMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        guard isAuthorized else {
            continuation.finish()
            return output
        }
        let subscriptions = TopicBox()
        let eventStream = await events.subscribe()

        Self.send(["type": "hello", "scope": scope.rawValue], to: continuation)

        let pumpTask = Task {
            for await event in eventStream {
                guard isAuthorized else {
                    continuation.finish()
                    break
                }
                guard subscriptions.contains(event.topic) else { continue }
                Self.send(
                    ["type": "event", "topic": event.topic.rawValue],
                    payload: ("data", event.payload),
                    to: continuation
                )
            }
        }

        let inputTask = Task {
            for await message in client {
                guard isAuthorized else { break }
                guard case .text(let text) = message else { continue }
                await handle(text: text, subscriptions: subscriptions, continuation: continuation)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            pumpTask.cancel()
            inputTask.cancel()
        }
        return output
    }

    private func handle(
        text: String, subscriptions: TopicBox,
        continuation: AsyncStream<WSMessage>.Continuation
    ) async {
        guard let inbound = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else {
            Self.send(["type": "error", "message": "Unparseable frame."], to: continuation)
            return
        }
        switch inbound.type {
        case "ping":
            Self.send(["type": "pong"], to: continuation)
        case "subscribe", "unsubscribe":
            let topics = (inbound.topics ?? APITopic.allCases.map(\.rawValue))
                .compactMap(APITopic.init(rawValue:))
            if inbound.type == "subscribe" {
                subscriptions.add(topics)
            } else {
                subscriptions.remove(topics)
            }
            Self.send(
                ["type": "subscribed", "topics": subscriptions.all.map(\.rawValue)],
                to: continuation
            )
        case "command":
            await handleCommand(inbound, continuation: continuation)
        default:
            Self.send(
                ["type": "error", "message": "Unknown frame type '\(inbound.type)'."],
                to: continuation
            )
        }
    }

    private func handleCommand(
        _ inbound: Inbound, continuation: AsyncStream<WSMessage>.Continuation
    ) async {
        let id = inbound.id ?? ""
        func reply(status: Int, data: Data) {
            Self.send(
                ["type": "result", "id": id, "status": status],
                payload: ("data", data),
                to: continuation
            )
        }
        guard let method = inbound.method, let path = inbound.path,
              let match = router.match(method: method, path: path)
        else {
            let error = APIError.notFound("No such operation.")
            reply(status: error.status, data: encode(error))
            return
        }
        guard scope.allows(match.route.scope) else {
            let error = APIError.forbidden(match.route.scope)
            reply(status: error.status, data: encode(error))
            return
        }
        let body = inbound.body.map { $0.encoded() } ?? Data()
        let context = APIRequestContext(
            pathParameters: match.parameters, query: [:], body: body, scope: scope
        )
        do {
            let response = try await match.route.handler(context)
            reply(status: response.status, data: response.body)
        } catch let error as APIError {
            reply(status: error.status, data: encode(error))
        } catch {
            let wrapped = APIError(status: 500, code: "internal", message: "\(error)")
            reply(status: 500, data: encode(wrapped))
        }
    }

    private func encode(_ error: APIError) -> Data {
        (try? JSONEncoder().encode(error)) ?? Data("{}".utf8)
    }

    static func send(
        _ envelope: [String: Any], payload: (key: String, json: Data)? = nil,
        to continuation: AsyncStream<WSMessage>.Continuation
    ) {
        guard let frame = frameText(envelope, payload: payload) else { return }
        continuation.yield(.text(frame))
    }

    static func frameText(
        _ envelope: [String: Any], payload: (key: String, json: Data)? = nil
    ) -> String? {
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if let payload {
            let key = "\"\(payload.key)\":"
            let json = String(decoding: payload.json, as: UTF8.self)
            let splice = (text == "{}" ? "" : ",") + key + json
            text.insert(contentsOf: splice, at: text.index(before: text.endIndex))
        }
        return text
    }
}

final class TopicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var topics: Set<APITopic> = []

    var all: [APITopic] {
        lock.lock()
        defer { lock.unlock() }
        return APITopic.allCases.filter(topics.contains)
    }

    func contains(_ topic: APITopic) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return topics.contains(topic)
    }

    func add(_ new: [APITopic]) {
        lock.lock()
        defer { lock.unlock() }
        topics.formUnion(new)
    }

    func remove(_ old: [APITopic]) {
        lock.lock()
        defer { lock.unlock() }
        topics.subtract(old)
    }
}
