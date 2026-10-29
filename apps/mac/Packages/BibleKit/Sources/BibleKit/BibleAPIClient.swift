import Foundation

public struct APIBible: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let abbreviation: String
    public let name: String
    public let language: String
    public let copyright: String
}

public struct APIBibleDetails: Sendable {
    public let bible: APIBible
    public let chapters: [String: [Int]]
}

public struct APIBibleLookup: Sendable {
    public let translation: BibleTranslation
    public let verses: [BibleVerse]
    public let total: Int
    public let viewToken: String?
}

public enum BibleAPIError: LocalizedError {
    case missingKey, unauthorized, forbidden, notFound, rateLimited, server(Int), invalidResponse, network, unsupportedVerse, invalidReference, tooManyVerses
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your API.Bible API key in Settings → Bible."
        case .unauthorized: "API.Bible rejected the API key. Check the application key in Settings → Bible."
        case .forbidden: "Your API.Bible application does not have access to this translation. Check its plan and translation permissions."
        case .notFound: "API.Bible could not find that Bible or passage. Check the reference and your translation access."
        case .rateLimited: "API.Bible's request limit was reached. Wait before retrying or check your plan's usage."
        case .server(let status): "API.Bible returned HTTP \(status). Please try again later."
        case .invalidResponse: "API.Bible returned an unexpected response. No Scripture was displayed."
        case .network: "Could not reach API.Bible. Check the internet connection. Offline WEB is still available."
        case .unsupportedVerse: "This passage uses a verse identifier this version of the Bible tool cannot safely interpret. Try another passage or translation."
        case .invalidReference: "Enter an English book name and chapter, verse, or range, such as John 3:16–18 or Psalm 23."
        case .tooManyVerses: "API.Bible returns at most 200 verses per passage. Choose a smaller range."
        }
    }
}

/// API keys travel only in the api-key header to API.Bible. No HTTP disk cache,
/// background retries, Scripture downloads, or response-body logging are used.
public actor BibleAPIClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let key: String
    private let transport: Transport
    private let deviceID: String
    private let sessionID = UUID().uuidString
    private var detailsCache: [String: (date: Date, details: APIBibleDetails)] = [:]

    public init(apiKey: String, deviceID: String = UUID().uuidString, transport: Transport? = nil) {
        self.deviceID = deviceID
        key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 40
            let session = URLSession(configuration: config, delegate: BibleAPIRedirectPolicy(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    public func bibles() async throws -> [APIBible] {
        let response = try await request(["bibles"], query: [.init(name: "include-full-details", value: "true")])
        guard let data = response["data"] as? [[String: Any]] else { throw BibleAPIError.invalidResponse }
        return try data.filter { !(($0["type"] as? String ?? "").lowercased().contains("audio")) }
            .map(Self.bible).sorted { ($0.language, $0.name, $0.id) < ($1.language, $1.name, $1.id) }
    }

    public func details(id: String) async throws -> APIBibleDetails {
        // Cache only non-Scripture metadata, briefly and in memory. Changing keys
        // creates a new client so one account's access cannot leak into another.
        if let cached = detailsCache[id], Date().timeIntervalSince(cached.date) < 900 { return cached.details }
        let metadata = try await request(["bibles", id])
        guard let raw = metadata["data"] as? [String: Any] else { throw BibleAPIError.invalidResponse }
        let bible = try Self.bible(raw)
        let bookResponse = try await request(["bibles", id, "books"], query: [.init(name: "include-chapters", value: "true")])
        guard let books = bookResponse["data"] as? [[String: Any]] else { throw BibleAPIError.invalidResponse }
        var chapters: [String: [Int]] = [:]
        let supported = Set(BibleBook.all.map(\.id))
        for book in books {
            guard let bookID = book["id"] as? String, supported.contains(bookID) else { continue }
            let values = (book["chapters"] as? [[String: Any]] ?? []).compactMap { chapter -> Int? in
                let number = (chapter["number"] as? String).flatMap(Int.init) ?? chapter["number"] as? Int
                return number.flatMap { $0 > 0 ? $0 : nil }
            }
            if !values.isEmpty { chapters[bookID] = Array(Set(values)).sorted() }
        }
        guard !chapters.isEmpty else { throw BibleAPIError.invalidResponse }
        let details = APIBibleDetails(bible: bible, chapters: chapters)
        detailsCache[id] = (Date(), details)
        return details
    }

    public func lookup(bible: APIBible, query: String, search: Bool) async throws -> APIBibleLookup {
        if search {
            let response = try await request(["bibles", bible.id, "search"], query: [
                .init(name: "query", value: query), .init(name: "limit", value: "100"),
                .init(name: "sort", value: "canonical"), .init(name: "fuzziness", value: "0"),
            ])
            guard let data = response["data"] as? [String: Any] else { throw BibleAPIError.invalidResponse }
            let hits = data["verses"] as? [[String: Any]] ?? []
            if hits.isEmpty, let passage = (data["passages"] as? [[String: Any]])?.first,
               let id = passage["id"] as? String {
                return try await passageResult(bible: bible, resource: "passages", id: id)
            }
            let verses = try hits.map { hit in
                guard let id = hit["id"] as? String, let text = hit["text"] as? String else { throw BibleAPIError.invalidResponse }
                return try Self.verse(id: id, text: text)
            }
            return result(bible: bible, verses: verses, copyright: bible.copyright, total: data["total"] as? Int ?? verses.count, viewToken: Self.viewToken(response))
        }
        let reference = try Self.reference(query)
        let resource = reference.chapterOnly ? "chapters" : (reference.id.contains("-") ? "passages" : "verses")
        do {
            return try await passageResult(bible: bible, resource: resource, id: reference.id)
        } catch {
            // Some grouped editions cannot resolve the single/range endpoint.
            // Fetch just that chapter once and select overlapping source units.
            switch error {
            case BibleAPIError.notFound, BibleAPIError.invalidResponse:
                guard !reference.chapterOnly else { throw error }
                return try await chapterFallback(bible: bible, referenceID: reference.id)
            default: throw error
            }
        }
    }

    private func chapterFallback(bible: APIBible, referenceID: String) async throws -> APIBibleLookup {
        let parts = referenceID.components(separatedBy: "-")
        let first = try Self.verse(id: parts[0], text: "")
        let last = try Self.verse(id: parts.last!, text: "")
        guard first.book == last.book, first.chapter == last.chapter else { throw BibleAPIError.notFound }
        let chapter = try await passageResult(bible: bible, resource: "chapters", id: "\(first.book).\(first.chapter)")
        let selected = chapter.verses.filter { $0.verse <= last.lastVerse && $0.lastVerse >= first.verse }
        guard !selected.isEmpty else { throw BibleAPIError.notFound }
        return APIBibleLookup(translation: chapter.translation, verses: selected, total: selected.count, viewToken: chapter.viewToken)
    }

    public func adjacentReference(bibleID: String, verseID: String, offset: Int) async throws -> String? {
        let response = try await request(["bibles", bibleID, "verses", verseID], query: Self.contentQuery)
        guard let data = response["data"] as? [String: Any] else { throw BibleAPIError.invalidResponse }
        guard let neighbor = data[offset < 0 ? "previous" : "next"] as? [String: Any],
              let id = neighbor["id"] as? String else { return nil }
        return try Self.verse(id: id, text: "").reference
    }

    private static let contentQuery: [URLQueryItem] = [
        .init(name: "content-type", value: "json"), .init(name: "include-notes", value: "false"),
        .init(name: "include-titles", value: "false"), .init(name: "include-chapter-numbers", value: "false"),
        // Retain boundary markers in JSON, then discard their number text in
        // parseContent. Displayed verse numbers are controlled entirely locally.
        .init(name: "include-verse-numbers", value: "true"),
    ]

    private func passageResult(bible: APIBible, resource: String, id: String) async throws -> APIBibleLookup {
        let response = try await request(["bibles", bible.id, resource, id], query: Self.contentQuery)
        guard let data = response["data"] as? [String: Any] else { throw BibleAPIError.invalidResponse }
        let verses = try Self.parseContent(data["content"])
        guard !verses.isEmpty else { throw BibleAPIError.invalidResponse }
        if (data["verseCount"] as? Int ?? verses.count) > 200 { throw BibleAPIError.tooManyVerses }
        // API.Bible can silently truncate a passage at 200 verses. Never present a
        // shortened range under the user's original reference.
        if resource == "passages", let returnedID = data["id"] as? String,
           returnedID != id, verses.count >= 200 { throw BibleAPIError.tooManyVerses }
        return result(bible: bible, verses: verses, copyright: data["copyright"] as? String ?? bible.copyright, total: verses.count, viewToken: Self.viewToken(response))
    }

    private func result(bible: APIBible, verses: [BibleVerse], copyright: String, total: Int, viewToken: String?) -> APIBibleLookup {
        let notice = Self.plainText(copyright)
        let translation = BibleTranslation(id: bible.abbreviation, name: bible.name, language: bible.language,
            copyright: notice.isEmpty ? "\(bible.name) · Scripture provided by API.Bible · https://api.bible" : notice,
            source: "https://api.bible · Bible ID: \(bible.id) · Fetched: \(Date().ISO8601Format())", verses: [])
        return APIBibleLookup(translation: translation, verses: verses, total: total, viewToken: viewToken)
    }

    private static func viewToken(_ response: [String: Any]) -> String? {
        (response["meta"] as? [String: Any])?["fumsToken"] as? String
    }

    /// API.Bible's native FUMS endpoint records a displayed preview. This request
    /// carries an opaque response token and random IDs, never the API key or user PII.
    /// Tracking failure must not interrupt a service or replace a successful lookup.
    public func reportView(token: String?) async {
        guard let token, !token.isEmpty, token.count < 8192 else { return }
        var url = URLComponents(string: "https://fums.api.bible/f3")!
        url.queryItems = [URLQueryItem(name: "t", value: token),
                         URLQueryItem(name: "dId", value: deviceID),
                         URLQueryItem(name: "sId", value: sessionID)]
        _ = try? await transport(URLRequest(url: url.url!))
    }

    private func request(_ components: [String], query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw BibleAPIError.missingKey }
        guard components.allSatisfy(Self.safeID) else { throw BibleAPIError.invalidReference }
        var url = URLComponents(string: "https://rest.api.bible/v1/" + components.joined(separator: "/"))!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: (Data, Int)
        do { response = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BibleAPIError.network }
        switch response.1 {
        case 200...299: break
        case 401: throw BibleAPIError.unauthorized
        case 403: throw BibleAPIError.forbidden
        case 404: throw BibleAPIError.notFound
        case 429: throw BibleAPIError.rateLimited
        default: throw BibleAPIError.server(response.1)
        }
        guard response.0.count < 10 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any] else { throw BibleAPIError.invalidResponse }
        return json
    }

    private static func bible(_ raw: [String: Any]) throws -> APIBible {
        guard let id = raw["id"] as? String, safeID(id), let name = raw["name"] as? String else { throw BibleAPIError.invalidResponse }
        let language = raw["language"] as? [String: Any] ?? [:]
        let abbreviation = raw["abbreviationLocal"] as? String ?? raw["abbreviation"] as? String ?? name
        return APIBible(id: id, abbreviation: abbreviation, name: name,
                        language: language["name"] as? String ?? language["id"] as? String ?? "Unknown",
                        copyright: plainText(raw["copyright"] as? String ?? ""))
    }

    private static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 150 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }
    }

    static func reference(_ input: String) throws -> (id: String, chapterOnly: Bool) {
        let pattern = #"^\s*(.+?)\s*(\d+)\s*(?::\s*(\d+)\s*(?:[-–—]\s*(?:(\d+)\s*:\s*)?(\d+)\s*)?)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { throw BibleAPIError.invalidReference }
        func part(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
        guard let book = part(1).flatMap(BibleBook.resolve), let chapter = part(2).flatMap(Int.init), chapter > 0 else { throw BibleAPIError.invalidReference }
        guard let verse = part(3).flatMap(Int.init) else { return ("\(book).\(chapter)", true) }
        let endChapter = part(4).flatMap(Int.init) ?? chapter
        let endVerse = part(5).flatMap(Int.init) ?? verse
        guard verse > 0, endVerse > 0, (endChapter, endVerse) >= (chapter, verse) else { throw BibleAPIError.invalidReference }
        let first = "\(book).\(chapter).\(verse)"
        return (first + ((chapter, verse) == (endChapter, endVerse) ? "" : "-\(book).\(endChapter).\(endVerse)"), false)
    }

    private static func verse(id: String, text: String) throws -> BibleVerse {
        // Both compact (JHN.3.16-18) and full (JHN.3.16-JHN.3.18)
        // bridges occur in Scripture sources. Never duplicate a bridge into
        // made-up individual verses or lose its complete reference on slides.
        let pattern = #"^([A-Z0-9]{3})\.(\d+)\.(\d+[a-z]?)(?:[-–]((?:[A-Z0-9]{3}\.\d+\.)?)(\d+[a-z]?))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) else { throw BibleAPIError.unsupportedVerse }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: id).map { String(id[$0]) } }
        guard let book = part(1), BibleBook.all.contains(where: { $0.id == book }),
              let chapter = part(2).flatMap(Int.init), (1...200).contains(chapter), let start = part(3),
              let number = Int(start.prefix(while: { $0.isNumber })), (1...999).contains(number) else { throw BibleAPIError.unsupportedVerse }
        let end = part(5)
        if let end {
            guard let last = Int(end.prefix(while: { $0.isNumber })), (number...999).contains(last),
                  part(4).map({ $0.isEmpty || $0 == "\(book).\(chapter)." }) == true else { throw BibleAPIError.unsupportedVerse }
        }
        let label = start + (end.map { "–" + $0 } ?? "")
        return BibleVerse(book: book, chapter: chapter, verse: number,
                          text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          verseLabel: label == String(number) ? nil : label, apiVerseID: id)
    }

    /// JSON text nodes carry verse IDs, including nested red-letter/poetry spans.
    /// Keep their order and exact text; never guess verse boundaries from digits.
    static func parseContent(_ raw: Any?) throws -> [BibleVerse] {
        var content = raw
        if let encoded = raw as? String, let data = encoded.data(using: .utf8) { content = try? JSONSerialization.jsonObject(with: data) }
        guard let nodes = content as? [[String: Any]] else { throw BibleAPIError.invalidResponse }
        var order: [String] = []
        var texts: [String: String] = [:]
        var currentID: String?
        func walk(_ node: [String: Any], inherited: String? = nil) {
            let name = node["name"] as? String ?? ""
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            let style = attrs["style"] as? String ?? ""
            if name == "note" || ["s", "s1", "s2", "s3", "r", "mt", "mt1", "cl", "cp"].contains(style) { return }
            if name == "verse" {
                if let sid = attrs["sid"] as? String { currentID = sid.replacingOccurrences(of: " ", with: ".").replacingOccurrences(of: ":", with: ".") }
                return // The marker's own number is not Scripture text.
            }
            let inheritedID = attrs["verseId"] as? String ?? inherited
            let id = inheritedID ?? currentID
            if let text = node["text"] as? String, let id {
                if texts[id] == nil { order.append(id); texts[id] = "" }
                texts[id, default: ""] += text
                currentID = id
            }
            for child in node["items"] as? [[String: Any]] ?? [] { walk(child, inherited: inheritedID) }
            if name == "para", let id = currentID, texts[id]?.last?.isWhitespace == false { texts[id, default: ""] += "\n" }
        }
        for node in nodes { walk(node) }
        return try order.compactMap { id in
            let text = texts[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : try verse(id: id, text: text)
        }
    }

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&copy;", "©"), ("&reg;", "®")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        // Copyright notices sometimes use numeric entities instead of © or ®.
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: text),
                      let fullRange = Range(match.range, in: text) else { continue }
                let digits = String(text[digitsRange])
                let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, let scalar = UnicodeScalar(value) { text.replaceSubrange(fullRange, with: String(scalar)) }
            }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class BibleAPIRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not forward the API-key header through redirects to any other host.
        completionHandler(nil)
    }
}
