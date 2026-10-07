import Foundation

public struct APIRequestContext: Sendable {
    public var pathParameters: [String: String]
    public var query: [String: String]
    public var body: Data
    public var scope: APIScope

    public init(
        pathParameters: [String: String] = [:], query: [String: String] = [:],
        body: Data = Data(), scope: APIScope = .edit
    ) {
        self.pathParameters = pathParameters
        self.query = query
        self.body = body
        self.scope = scope
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {

        let data = body.isEmpty ? Data("{}".utf8) : body
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.badRequest("Could not decode request body: \(error.localizedDescription)")
        }
    }

    public func pathParameter(_ name: String) throws -> String {
        guard let value = pathParameters[name], !value.isEmpty else {
            throw APIError.badRequest("Missing path parameter '\(name)'.")
        }
        return value
    }

    public func documentKind() throws -> APIDocumentKind {
        let raw = try pathParameter("kind")
        guard let kind = APIDocumentKind(rawValue: raw) else {
            throw APIError.badRequest(
                "Unknown document kind '\(raw)'. Kinds: \(APIDocumentKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return kind
    }
}

public struct APIHandlerResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int = 200, body: Data) {
        self.status = status
        self.body = body
    }

    public static func json(_ value: some Encodable, status: Int = 200) -> APIHandlerResponse {
        let data = (try? APIJSON.encoder().encode(value)) ?? Data("{}".utf8)
        return APIHandlerResponse(status: status, body: data)
    }

    public static func raw(_ data: Data, status: Int = 200) -> APIHandlerResponse {
        APIHandlerResponse(status: status, body: data)
    }

    public static let ok = APIHandlerResponse.json(APIOKResponse())
}

public struct APIRoute: Sendable {
    public var method: String

    public var path: String
    public var scope: APIScope
    public var operationId: String
    public var summary: String
    public var tag: String
    public var requestSchema: JSONValue?
    public var responseSchema: JSONValue
    public var handler: @Sendable (APIRequestContext) async throws -> APIHandlerResponse

    public init(
        _ method: String, _ path: String, scope: APIScope,
        operationId: String, summary: String, tag: String,
        requestSchema: JSONValue? = nil, responseSchema: JSONValue,
        handler: @escaping @Sendable (APIRequestContext) async throws -> APIHandlerResponse
    ) {
        self.method = method
        self.path = path
        self.scope = scope
        self.operationId = operationId
        self.summary = summary
        self.tag = tag
        self.requestSchema = requestSchema
        self.responseSchema = responseSchema
        self.handler = handler
    }
}

public struct APIRouter: Sendable {
    public let routes: [APIRoute]

    public init(routes: [APIRoute]) {
        self.routes = routes
    }

    public func match(method: String, path: String) -> (route: APIRoute, parameters: [String: String])? {
        let requestSegments = path.split(separator: "/", omittingEmptySubsequences: true)
        for route in routes where route.method == method.uppercased() {
            let templateSegments = route.path.split(separator: "/", omittingEmptySubsequences: true)
            guard templateSegments.count == requestSegments.count else { continue }
            var parameters: [String: String] = [:]
            var matched = true
            for (template, request) in zip(templateSegments, requestSegments) {
                if template.hasPrefix("{"), template.hasSuffix("}") {
                    let name = String(template.dropFirst().dropLast())
                    let value = request.removingPercentEncoding ?? String(request)

                    guard !value.contains("/"), !value.contains("\\"),
                          !value.contains("\0")
                    else {
                        matched = false
                        break
                    }
                    parameters[name] = value
                } else if template != request {
                    matched = false
                    break
                }
            }
            if matched {
                return (route, parameters)
            }
        }
        return nil
    }

    public func pathExists(_ path: String) -> Bool {
        routes.contains { route in
            let templateSegments = route.path.split(separator: "/", omittingEmptySubsequences: true)
            let requestSegments = path.split(separator: "/", omittingEmptySubsequences: true)
            guard templateSegments.count == requestSegments.count else { return false }
            return zip(templateSegments, requestSegments).allSatisfy { template, request in
                template.hasPrefix("{") || template == request
            }
        }
    }
}
