import FlyingFox
import Foundation
import os

public final class LocalAPIServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16

        public var serviceName: String
        public var advertise: Bool
        public var info: APIServerInfo

        public var beat: (@Sendable () -> UInt64)?

        public init(
            port: UInt16, serviceName: String, advertise: Bool, info: APIServerInfo,
            beat: (@Sendable () -> UInt64)? = nil
        ) {
            self.port = port
            self.serviceName = serviceName
            self.advertise = advertise
            self.info = info
            self.beat = beat
        }
    }

    public let events = APIEventBus()
    public let router: APIRouter

    private let configuration: Configuration
    private let tokens: APITokenStore
    private let http: HTTPServer
    private let bonjour = BonjourAdvertiser()

    private let info: OSAllocatedUnfairLock<APIServerInfo>

    public init(configuration: Configuration, routes: [APIRoute], tokens: APITokenStore) {
        self.configuration = configuration
        self.router = APIRouter(routes: routes)
        self.tokens = tokens
        self.http = HTTPServer(port: configuration.port)
        self.info = OSAllocatedUnfairLock(initialState: configuration.info)
    }

    public func update(stationHexId: String?, teamHexId: String?) {
        let changed = info.withLock { info -> APIServerInfo? in
            guard info.stationHexId != stationHexId || info.teamHexId != teamHexId else { return nil }
            info.stationHexId = stationHexId
            info.teamHexId = teamHexId
            return info
        }
        if let changed, configuration.advertise {
            bonjour.update(txt: BonjourAdvertiser.txt(for: changed))
        }
    }

    public func run() async throws {
        await registerRoutes()
        if configuration.advertise {
            bonjour.start(
                name: configuration.serviceName, port: configuration.port,
                txt: BonjourAdvertiser.txt(for: info.withLock { $0 }))
        }
        defer { bonjour.stop() }
        try await http.run()
    }

    public func waitUntilListening() async throws {
        try await http.waitUntilListening()
    }

    public func stop() async {
        bonjour.stop()
        await http.stop(timeout: 1)
    }

    private func registerRoutes() async {
        let info = self.info
        let specVersion = OpenAPIDocument.documentSchemaVersion()

        await http.appendRoute(HTTPRoute("GET /v1/ping")) { _ in
            Self.jsonResponse(APIHandlerResponse.json(info.withLock { $0 }))
        }
        let openAPIRoutes = router.routes
        await http.appendRoute(HTTPRoute("GET /openapi.json")) { _ in
            Self.jsonResponse(.raw(
                OpenAPIDocument.compose(routes: openAPIRoutes, schemaVersion: specVersion).encoded()
            ))
        }
        await http.appendRoute(HTTPRoute("GET /asyncapi.json")) { _ in
            Self.jsonResponse(.raw(AsyncAPIDocument.compose(schemaVersion: specVersion).encoded()))
        }

        let docRoutes = router.routes
        await http.appendRoute(HTTPRoute("GET /docs")) { request in
            let host = request.headers[.host] ?? "localhost"
            let page = DocsPage.html(routes: docRoutes, baseURL: host, schemaVersion: specVersion)
            return HTTPResponse(
                statusCode: .ok,
                headers: [HTTPHeader("Content-Type"): "text/html; charset=utf-8"],
                body: Data(page.utf8)
            )
        }

        let router = self.router
        let events = self.events
        let tokens = self.tokens
        let beat = configuration.beat
        await http.appendRoute(HTTPRoute("GET /v1/ws")) { request in
            guard let token = Self.authenticate(request, tokens: tokens) else {
                return Self.jsonResponse(.json(APIError.unauthorized(), status: 401))
            }
            let handler = APIWebSocketHandler(router: router, events: events, token: token, tokens: tokens, beat: beat)
            let webSocket = WebSocketHTTPHandler(handler: MessageFrameWSHandler(handler: handler))
            return try await webSocket.handleRequest(request)
        }

        await http.appendRoute(HTTPRoute("*")) { [weak self] request in
            guard let self else {
                return HTTPResponse(statusCode: .serviceUnavailable)
            }
            return await self.handle(request)
        }
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {

        if request.method == HTTPMethod("OPTIONS") {
            return Self.corsPreflightResponse()
        }
        guard let match = router.match(method: request.method.rawValue, path: request.path) else {
            let error = router.pathExists(request.path)
                ? APIError(status: 405, code: "method_not_allowed", message: "Method not allowed.")
                : APIError.notFound("No such endpoint. The contract is served at /openapi.json.")
            return Self.jsonResponse(.json(error, status: error.status))
        }
        guard let token = Self.authenticate(request, tokens: tokens) else {
            return Self.jsonResponse(.json(APIError.unauthorized(), status: 401))
        }
        guard token.scope.allows(match.route.scope) else {
            let error = APIError.forbidden(match.route.scope)
            return Self.jsonResponse(.json(error, status: error.status))
        }
        var query: [String: String] = [:]
        for item in request.query {
            query[item.name] = item.value
        }
        let body = (try? await request.bodyData) ?? Data()
        let context = APIRequestContext(
            pathParameters: match.parameters, query: query, body: body, scope: token.scope
        )
        do {
            return Self.jsonResponse(try await match.route.handler(context))
        } catch let error as APIError {
            return Self.jsonResponse(.json(error, status: error.status))
        } catch {
            let wrapped = APIError(status: 500, code: "internal", message: "\(error)")
            return Self.jsonResponse(.json(wrapped, status: 500))
        }
    }

    private static func authenticate(_ request: HTTPRequest, tokens: APITokenStore) -> APIToken? {
        if let header = request.headers[.authorization], header.hasPrefix("Bearer ") {
            return tokens.verify(secret: String(header.dropFirst("Bearer ".count)))
        }
        if let secret = request.query["token"] {
            return tokens.verify(secret: secret)
        }
        return nil
    }

    private static func jsonResponse(_ payload: APIHandlerResponse) -> HTTPResponse {
        var headers = corsHeaders()
        headers[.contentType] = "application/json"
        return HTTPResponse(
            statusCode: HTTPStatusCode(payload.status, phrase: ""),
            headers: headers,
            body: payload.body
        )
    }

    private static func corsPreflightResponse() -> HTTPResponse {
        HTTPResponse(statusCode: .noContent, headers: corsHeaders())
    }

    private static func corsHeaders() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers[HTTPHeader("Access-Control-Allow-Origin")] = "*"
        headers[HTTPHeader("Access-Control-Allow-Methods")] = "GET, POST, PUT, DELETE, OPTIONS"
        headers[HTTPHeader("Access-Control-Allow-Headers")] = "Authorization, Content-Type"
        return headers
    }
}
