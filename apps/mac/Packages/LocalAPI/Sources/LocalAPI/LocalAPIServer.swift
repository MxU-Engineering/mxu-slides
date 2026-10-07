import FlyingFox
import Foundation

public final class LocalAPIServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16

        public var serviceName: String
        public var advertise: Bool
        public var info: APIServerInfo

        public init(port: UInt16, serviceName: String, advertise: Bool, info: APIServerInfo) {
            self.port = port
            self.serviceName = serviceName
            self.advertise = advertise
            self.info = info
        }
    }

    public let events = APIEventBus()
    public let router: APIRouter

    private let configuration: Configuration
    private let tokens: APITokenStore
    private let http: HTTPServer
    private let bonjour = BonjourAdvertiser()

    public init(configuration: Configuration, routes: [APIRoute], tokens: APITokenStore) {
        self.configuration = configuration
        self.router = APIRouter(routes: routes)
        self.tokens = tokens
        self.http = HTTPServer(port: configuration.port)
    }

    public func run() async throws {
        await registerRoutes()
        if configuration.advertise {
            bonjour.start(name: configuration.serviceName, port: configuration.port)
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
        let info = configuration.info
        let specVersion = OpenAPIDocument.documentSchemaVersion()

        await http.appendRoute(HTTPRoute("GET /v1/ping")) { _ in
            Self.jsonResponse(APIHandlerResponse.json(info))
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
        await http.appendRoute(HTTPRoute("GET /v1/ws")) { request in
            guard let secret = request.query["token"],
                  let token = tokens.verify(secret: secret)
            else {
                return Self.jsonResponse(.json(APIError.unauthorized(), status: 401))
            }
            let handler = APIWebSocketHandler(router: router, events: events, scope: token.scope)
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
        guard let token = authenticate(request) else {
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

    private func authenticate(_ request: HTTPRequest) -> APIToken? {
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
