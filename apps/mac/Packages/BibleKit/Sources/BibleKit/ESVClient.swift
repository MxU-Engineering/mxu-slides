import Foundation

public enum ESVError: LocalizedError {
    case missingKey, unauthorized, rateLimit, network, invalidResponse, storageLimit, server(Int)
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your ESV application API key in Settings → Bible."
        case .unauthorized: "ESV rejected this API key. Check Settings → Bible."
        case .rateLimit: "ESV's request limit was reached. Please wait before looking up another passage."
        case .network: "Could not reach ESV.org. Check the internet connection or use offline WEB."
        case .invalidResponse: "ESV returned an unsupported or empty passage. Try a smaller reference."
        case .storageLimit: "This would exceed the direct ESV API's local verse allowance. Remove older ESV presentations before saving or fetching more text. Nothing was deleted."
        case .server(let status): "ESV returned HTTP \(status). Please try again later."
        }
    }
}

/// Direct Crossway provider. No API.Bible key, disk cache, or shared developer key.
public actor ESVClient {
    public typealias Transport = BibleAPIClient.Transport
    public static let copyright = "Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. ESV Text Edition: 2025. Used by permission. All rights reserved. The ESV text may not be quoted in any publication made available to the public by a Creative Commons license. The ESV may not be translated into any other language. Users may not copy or download more than 500 verses of the ESV Bible or more than one half of any book of the ESV Bible."
    private let key: String
    private let transport: Transport
    private var requestDates: [Date] = []
    private var navigation: [String: (previous: Int?, next: Int?)] = [:]

    public init(apiKey: String, transport: Transport? = nil) {
        key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40
            let session = URLSession(configuration: config, delegate: ESVRedirectPolicy(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    public func lookup(query: String, search: Bool) async throws -> APIBibleLookup {
        if search {
            let response = try await request("search", query: [.init(name: "q", value: query), .init(name: "page-size", value: "100")])
            guard let hits = response["results"] as? [[String: Any]] else { throw ESVError.invalidResponse }
            let verses = try hits.map { hit -> BibleVerse in
                guard let reference = hit["reference"] as? String, let content = hit["content"] as? String else { throw ESVError.invalidResponse }
                let id = try BibleAPIClient.reference(reference).id
                let parts = id.split(separator: ".")
                guard parts.count == 3, let chapter = Int(parts[1]), let verse = Int(parts[2]) else { throw ESVError.invalidResponse }
                return BibleVerse(book: String(parts[0]), chapter: chapter, verse: verse, text: content)
            }
            return result(verses, total: response["total_results"] as? Int ?? verses.count)
        }
        let response = try await request("html", query: [
            .init(name: "q", value: query), .init(name: "include-passage-references", value: "false"),
            .init(name: "include-verse-numbers", value: "true"), .init(name: "include-first-verse-numbers", value: "true"),
            .init(name: "include-chapter-numbers", value: "false"), .init(name: "include-headings", value: "false"),
            .init(name: "include-subheadings", value: "false"), .init(name: "include-footnotes", value: "false"),
            .init(name: "include-footnote-body", value: "false"), .init(name: "include-crossrefs", value: "false"),
            .init(name: "include-short-copyright", value: "false"), .init(name: "include-copyright", value: "false"),
        ])
        guard let passages = response["passages"] as? [String], !passages.isEmpty else { throw ESVError.invalidResponse }
        var seen = Set<String>()
        let verses = try passages.flatMap(Self.parseHTML).filter { seen.insert($0.id).inserted }
        guard !verses.isEmpty else { throw ESVError.invalidResponse }
        guard verses.count <= 500 else { throw ESVError.storageLimit }
        if let meta = (response["passage_meta"] as? [[String: Any]])?.first, let first = verses.first, let last = verses.last {
            navigation[first.id] = (meta["prev_verse"] as? Int, nil)
            let previous = navigation[last.id]?.previous
            navigation[last.id] = (previous, meta["next_verse"] as? Int)
        }
        return result(verses, total: verses.count)
    }

    public func adjacent(to verse: BibleVerse, offset: Int) async throws -> String? {
        let known = offset < 0 ? navigation[verse.id]?.previous : navigation[verse.id]?.next
        if known == nil { _ = try await lookup(query: verse.reference, search: false) }
        guard let code = offset < 0 ? navigation[verse.id]?.previous : navigation[verse.id]?.next, code > 0 else { return nil }
        return try Self.verse(code: code, text: "").reference
    }

    private func result(_ verses: [BibleVerse], total: Int) -> APIBibleLookup {
        APIBibleLookup(translation: BibleTranslation(id: "ESV", name: "English Standard Version", language: "English",
            copyright: Self.copyright, source: "https://api.esv.org · https://www.esv.org · Fetched: \(Date().ISO8601Format())", verses: []),
            verses: verses, total: total, viewToken: nil)
    }

    private func request(_ endpoint: String, query: [URLQueryItem]) async throws -> [String: Any] {
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw ESVError.missingKey }
        let now = Date()
        requestDates.removeAll { now.timeIntervalSince($0) >= 86400 }
        guard requestDates.count < 5000, requestDates.filter({ now.timeIntervalSince($0) < 3600 }).count < 1000,
              requestDates.filter({ now.timeIntervalSince($0) < 60 }).count < 60 else { throw ESVError.rateLimit }
        requestDates.append(now)
        var url = URLComponents(string: "https://api.esv.org/v3/passage/\(endpoint)/")!
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue("Token " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: (Data, Int)
        do { response = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ESVError.network }
        switch response.1 {
        case 200...299: break
        case 401, 403: throw ESVError.unauthorized
        case 429: throw ESVError.rateLimit
        default: throw ESVError.server(response.1)
        }
        guard response.0.count < 10_000_000,
              let raw = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any] else { throw ESVError.invalidResponse }
        return raw
    }

    /// Crossway's HTML marks verse numbers with IDs such as v43003016-1.
    /// Consume those markers, not arbitrary digits in Scripture. Number labels
    /// are discarded; words, emphasis contents, poetry and punctuation survive.
    static func parseHTML(_ html: String) throws -> [BibleVerse] {
        let tokens = try NSRegularExpression(pattern: #"<[^>]+>|[^<]+"#)
        let marker = try NSRegularExpression(pattern: #"\bid\s*=\s*["']v(\d{8})(?:-[^"']*)?["']"#, options: .caseInsensitive)
        var order: [Int] = [], text: [Int: String] = [:]
        var current: Int?, skippingNumber = false
        for match in tokens.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let token = String(html[range])
            if token.hasPrefix("<") {
                if let found = marker.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
                   let range = Range(found.range(at: 1), in: token), let code = Int(token[range]) {
                    current = code; if text[code] == nil { order.append(code); text[code] = "" }
                    skippingNumber = true
                } else if token.lowercased().hasPrefix("</b") { skippingNumber = false }
                if token.lowercased().hasPrefix("</p") || token.lowercased().hasPrefix("<br"), let current { text[current, default: ""] += " " }
            } else if !skippingNumber, let current {
                // Decode entities without collapsing leading/trailing whitespace:
                // independently trimming inline spans would join adjacent words.
                text[current, default: ""] += decodeEntities(token)
            }
        }
        return try order.compactMap { code in
            let value = text[code, default: ""].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return value.isEmpty ? nil : try verse(code: code, text: value)
        }
    }

    private static func decodeEntities(_ value: String) -> String {
        var text = value
        for (entity, decoded) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&mdash;", "—"), ("&ndash;", "–")] {
            text = text.replacingOccurrences(of: entity, with: decoded)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: text) else { continue }
                let digits = String(text[digitsRange]); let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return text
    }

    private static func verse(code: Int, text: String) throws -> BibleVerse {
        let book = code / 1_000_000, chapter = (code / 1000) % 1000, number = code % 1000
        guard (1...BibleBook.all.count).contains(book), chapter > 0, number > 0 else { throw ESVError.invalidResponse }
        return BibleVerse(book: BibleBook.all[book - 1].id, chapter: chapter, verse: number, text: text)
    }
}

private final class ESVRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
