import Foundation
import Testing
@testable import BibleKit

private actor APIFixture {
    private(set) var requests: [URLRequest] = []
    let replies: [String: String]
    let status: Int
    init(_ replies: [String: String], status: Int = 200) { self.replies = replies; self.status = status }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        requests.append(request)
        let body = replies[request.url!.path] ?? #"{"data":[]}"#
        return (Data(body.utf8), status)
    }
}

@Suite struct BibleAPIClientTests {
    private let bible = APIBible(id: "test-01", abbreviation: "TEST", name: "Test Bible", language: "English", copyright: "Test publisher")
    private static let content = #"[{"name":"para","attrs":{"style":"s1"},"items":[{"type":"text","text":"Heading must be omitted"}]},{"name":"para","attrs":{"style":"p"},"items":[{"name":"verse","attrs":{"sid":"JHN 3:16"},"items":[{"type":"text","text":"16"}]},{"type":"text","text":"First ","attrs":{"verseId":"JHN.3.16"}},{"name":"char","items":[{"type":"text","text":"verse."}]},{"name":"note","items":[{"type":"text","text":"Footnote"}]}]},{"name":"para","items":[{"name":"verse","attrs":{"sid":"JHN 3:17"}},{"name":"char","items":[{"type":"text","text":"Second verse."}]}]}]"#

    @Test func nestedTextPreservesVerseBoundariesAndOmitsNumbersNotesAndHeadings() throws {
        let verses = try BibleAPIClient.parseContent(Self.content)
        #expect(verses.map(\.id) == ["JHN.3.16", "JHN.3.17"])
        #expect(verses.map(\.text) == ["First verse.", "Second verse."])
    }

    @Test func referencesUseCanonicalIDsAndRejectReversedRanges() throws {
        #expect(try BibleAPIClient.reference("John 3:16–18").id == "JHN.3.16-JHN.3.18")
        #expect(try BibleAPIClient.reference("1 Corinthians 13").id == "1CO.13")
        #expect(try BibleAPIClient.reference("Psalm 23").chapterOnly)
        #expect(try BibleAPIClient.reference("John 3:36-4:2").id == "JHN.3.36-JHN.4.2")
        #expect(throws: BibleAPIError.self) { try BibleAPIClient.reference("John 3:18-16") }
        #expect(throws: BibleAPIError.self) { try BibleAPIClient.reference("John 0:1") }
    }

    @Test func passageRequestsUseHeaderAuthenticationAndStructuredContent() async throws {
        let fixture = APIFixture(["/v1/bibles/test-01/passages/JHN.3.16-JHN.3.17":
            "{\"data\":{\"id\":\"JHN.3.16-JHN.3.17\",\"verseCount\":2,\"copyright\":\"&copy; Test publisher\",\"content\":\(Self.content)}}"])
        let client = BibleAPIClient(apiKey: " test-secret ", transport: { try await fixture.send($0) })
        let result = try await client.lookup(bible: bible, query: "John 3:16-17", search: false)
        #expect(result.verses.count == 2)
        #expect(result.translation.copyright == "© Test publisher")
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.host == "rest.api.bible")
        #expect(request.value(forHTTPHeaderField: "api-key") == "test-secret")
        #expect(request.url?.absoluteString.contains("secret") == false)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "content-type", value: "json")))
        #expect(query.contains(URLQueryItem(name: "include-verse-numbers", value: "true")))
    }

    @Test func catalogAndBookMetadataAreDecodedWithoutIntroChapters() async throws {
        let metadata = #"{"id":"test-01","name":"Test Bible","abbreviation":"TEST","language":{"name":"English"},"copyright":"Test publisher"}"#
        let fixture = APIFixture([
            "/v1/bibles": "{\"data\":[\(metadata)]}",
            "/v1/bibles/test-01": "{\"data\":\(metadata)}",
            "/v1/bibles/test-01/books": #"{"data":[{"id":"JHN","chapters":[{"number":"intro"},{"number":"1"},{"number":"3"},{"number":"3"}]}]}"#,
        ])
        let client = BibleAPIClient(apiKey: "secret", transport: { try await fixture.send($0) })
        #expect(try await client.bibles().map(\.id) == ["test-01"])
        #expect(try await client.details(id: "test-01").chapters == ["JHN": [1, 3]])
        _ = try await client.details(id: "test-01")
        #expect(await fixture.requests.count == 3) // Metadata is cached; Scripture is not.
    }

    @Test func keywordSearchRetainsTotalAndRequestsBoundedResults() async throws {
        let fixture = APIFixture(["/v1/bibles/test-01/search": #"{"data":{"total":250,"verses":[{"id":"JHN.3.16","text":"A test verse."}]}}"#])
        let client = BibleAPIClient(apiKey: "secret", transport: { try await fixture.send($0) })
        let result = try await client.lookup(bible: bible, query: "test & words", search: true)
        #expect(result.total == 250)
        #expect(result.verses.first?.text == "A test verse.")
        let request = try #require(await fixture.requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "limit", value: "100")))
        #expect(query.contains(URLQueryItem(name: "query", value: "test & words")))
    }

    @Test func missingKeyDoesNotMakeARequest() async {
        let fixture = APIFixture([:])
        let client = BibleAPIClient(apiKey: "", transport: { try await fixture.send($0) })
        do { _ = try await client.bibles(); Issue.record("Expected missing key") }
        catch { #expect(error.localizedDescription.contains("Settings")) }
        #expect(await fixture.requests.isEmpty)
    }

    @Test(arguments: [401, 403, 404, 429, 500]) func serverErrorsNeverExposeResponseBodiesOrSecrets(status: Int) async {
        let fixture = APIFixture(["/v1/bibles": "private response test-secret"], status: status)
        let client = BibleAPIClient(apiKey: "test-secret", transport: { try await fixture.send($0) })
        do { _ = try await client.bibles(); Issue.record("Expected HTTP error") }
        catch {
            #expect(error is BibleAPIError)
            #expect(!error.localizedDescription.contains("test-secret"))
            #expect(!error.localizedDescription.contains("private response"))
        }
    }

    @Test func malformedVerseIDsFailInsteadOfMislabelingText() async throws {
        #expect(throws: BibleAPIError.self) { try BibleAPIClient.parseContent("not JSON") }
        #expect(throws: BibleAPIError.self) {
            try BibleAPIClient.parseContent(#"[{"type":"text","attrs":{"verseId":"JHN.3.18-16"},"text":"Merged verse"}]"#)
        }
        let fixture = APIFixture(["/v1/bibles": "not JSON"])
        let client = BibleAPIClient(apiKey: "secret", transport: { try await fixture.send($0) })
        do { _ = try await client.bibles(); Issue.record("Expected invalid response") }
        catch { #expect(error is BibleAPIError) }
    }

    @Test func adjacentVerseUsesReturnedCanonicalReference() async throws {
        let fixture = APIFixture(["/v1/bibles/test-01/verses/JHN.3.16": #"{"data":{"next":{"id":"JHN.3.17"}}}"#])
        let client = BibleAPIClient(apiKey: "secret", transport: { try await fixture.send($0) })
        #expect(try await client.adjacentReference(bibleID: "test-01", verseID: "JHN.3.16", offset: 1) == "John 3:17")
    }
    @Test func truncatedPassagesAreRejectedInsteadOfLosingTheEndOfARange() async throws {
        let nodes: [[String: Any]] = (1...200).map { number in
            ["type": "text", "text": "Test verse \(number).", "attrs": ["verseId": "PSA.119.\(number)"]]
        }
        let response: [String: Any] = ["data": ["id": "PSA.119.1-PSA.119.200", "verseCount": 200, "content": nodes]]
        let body = String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        let fixture = APIFixture(["/v1/bibles/test-01/passages/PSA.119.1-PSA.120.20": body])
        let client = BibleAPIClient(apiKey: "secret", transport: { try await fixture.send($0) })
        do { _ = try await client.lookup(bible: bible, query: "Psalm 119:1-120:20", search: false); Issue.record("Expected truncation error") }
        catch BibleAPIError.tooManyVerses { }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func viewReportsNeverSendTheAPIKeyAndEncodeTheResponseToken() async throws {
        let fixture = APIFixture([:])
        let client = BibleAPIClient(apiKey: "secret", deviceID: "random-test-device", transport: { try await fixture.send($0) })
        await client.reportView(token: nil)
        #expect(await fixture.requests.isEmpty)
        await client.reportView(token: "opaque+token/value=&")
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.host == "fums.api.bible")
        #expect(request.value(forHTTPHeaderField: "api-key") == nil)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "t", value: "opaque+token/value=&")))
        #expect(query.contains(URLQueryItem(name: "dId", value: "random-test-device")))
        #expect(!query.contains { $0.name == "uId" })
    }

    @Test func groupedAndPartialVersesRetainTheirCompleteLabelsWithoutDuplicatingWords() throws {
        let verses = try BibleAPIClient.parseContent(#"[{"name":"verse","attrs":{"sid":"JHN 3:16-18"}},{"text":"A grouped text. "},{"name":"char","items":[{"text":"Its continuation."}]},{"text":"A partial verse.","attrs":{"verseId":"JHN.3.19a"}}]"#)
        #expect(verses.count == 2)
        #expect(verses[0].reference == "John 3:16–18")
        #expect(verses[0].text == "A grouped text. Its continuation.")
        #expect(verses[1].reference == "John 3:19a")
        let pages = BibleSlides.pages(verses: verses, oneVersePerSlide: true)
        #expect(pages.count == 2)
        #expect(pages[0].text == "16–18 A grouped text. Its continuation.")
        #expect(pages[0].reference == "John 3:16–18")
        #expect(BibleCorpus.reference(for: verses) == "John 3:16–19a")
    }

    @Test func fullBridgeIDsAndChapterFallbackSelectTheEntireOverlappingGroup() async throws {
        let fixture = APIFixture([
            "/v1/bibles/test-01/verses/JHN.3.17": #"{"data":{"content":[]}}"#,
            "/v1/bibles/test-01/chapters/JHN.3": #"{"data":{"verseCount":4,"content":[{"text":"Grouped words.","attrs":{"verseId":"JHN.3.16-JHN.3.18"}},{"text":"Other words.","attrs":{"verseId":"JHN.3.19"}}]}}"#,
        ])
        let client = BibleAPIClient(apiKey: "secret", transport: { try await fixture.send($0) })
        let result = try await client.lookup(bible: bible, query: "John 3:17", search: false)
        #expect(result.verses.count == 1)
        #expect(result.verses[0].reference == "John 3:16–18")
        #expect(result.verses[0].id == "JHN.3.16-JHN.3.18")
        #expect(await fixture.requests.count == 2)
        let before = await fixture.requests.count
        // Pagination/theme changes consume this in-memory result, never the client.
        for onePerSlide in [true, false] {
            let pages = BibleSlides.pages(verses: result.verses, oneVersePerSlide: onePerSlide)
            for style in BibleSlideStyle.allCases {
                _ = pages.map { BibleSlides.slide(page: $0, translation: result.translation, style: style, themeID: "test-theme") }
            }
        }
        #expect(await fixture.requests.count == before)
    }

}
