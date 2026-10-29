import Foundation
import Testing
@testable import BibleKit

private actor ESVFixture {
    let body: Data
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(_ body: String, status: Int = 200) { self.body = Data(body.utf8); self.status = status }
    func send(_ request: URLRequest) -> (Data, Int) { requests.append(request); return (body, status) }
}

@Suite struct ESVClientTests {
    private static let response = #"{"passages":["<p><b class=\"verse-num\" id=\"v43003016-1\">16&nbsp;</b>First <em>test</em> verse. <b class=\"verse-num\" id=\"v43003017-1\">17&nbsp;</b>Second &#8220;test&#8221; verse.</p>"],"passage_meta":[{"prev_verse":43003015,"next_verse":43003018}]}"#

    @Test func htmlBoundariesPreserveWordsAndDiscardNumberMarkers() throws {
        let verses = try ESVClient.parseHTML(#"<p><b class="verse-num" id="v43003016-1">16&nbsp;</b>First <em>test</em> verse. <b class="verse-num" id="v43003017-1">17&nbsp;</b>Second &#8220;test&#8221; verse.</p>"#)
        #expect(verses.map(\.id) == ["JHN.3.16", "JHN.3.17"])
        #expect(verses.map(\.text) == ["First test verse.", "Second “test” verse."])
    }

    @Test func passageLookupKeepsSecretsInHeadersAndNavigationReusesMetadata() async throws {
        let fixture = ESVFixture(Self.response)
        let client = ESVClient(apiKey: "esv-test-secret", transport: { await fixture.send($0) })
        let result = try await client.lookup(query: "John 3:16–17", search: false)
        #expect(result.verses.count == 2)
        #expect(result.translation.source?.contains("api.esv.org") == true)
        #expect(try await client.adjacent(to: result.verses[0], offset: -1) == "John 3:15")
        #expect(try await client.adjacent(to: result.verses[1], offset: 1) == "John 3:18")
        #expect(await fixture.requests.count == 1)
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.host == "api.esv.org")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token esv-test-secret")
        #expect(request.url?.absoluteString.contains("secret") == false)
        let before = await fixture.requests.count
        for style in BibleSlideStyle.allCases {
            _ = BibleSlides.pages(verses: result.verses).map { BibleSlides.slide(page: $0, translation: result.translation, style: style) }
        }
        #expect(await fixture.requests.count == before)
    }

    @Test func searchReturnsBoundedVerseResultsAndTotal() async throws {
        let fixture = ESVFixture(#"{"total_results":203,"results":[{"reference":"John 3:16","content":"A test verse."}]}"#)
        let client = ESVClient(apiKey: "secret", transport: { await fixture.send($0) })
        let result = try await client.lookup(query: "test", search: true)
        #expect(result.total == 203)
        #expect(result.verses.first?.id == "JHN.3.16")
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.query?.contains("page-size=100") == true)
    }

    @Test(arguments: [401, 403, 429, 500]) func failuresDoNotRevealCredentialsOrBody(status: Int) async {
        let fixture = ESVFixture("Private body: secret", status: status)
        let client = ESVClient(apiKey: "secret", transport: { await fixture.send($0) })
        do { _ = try await client.lookup(query: "John 3:16", search: false); Issue.record("Expected failure") }
        catch { #expect(error is ESVError); #expect(!error.localizedDescription.contains("secret")) }
    }

    @Test func missingKeyAndEmptyContentFailExplicitly() async {
        let fixture = ESVFixture(#"{"passages":[]}"#)
        let noKey = ESVClient(apiKey: "", transport: { await fixture.send($0) })
        do { _ = try await noKey.lookup(query: "John 3:16", search: false); Issue.record("Expected missing key") }
        catch { #expect(error is ESVError) }
        #expect(await fixture.requests.isEmpty)
        let client = ESVClient(apiKey: "secret", transport: { await fixture.send($0) })
        do { _ = try await client.lookup(query: "invalid", search: false); Issue.record("Expected empty response failure") }
        catch { #expect(error is ESVError) }
    }
}
