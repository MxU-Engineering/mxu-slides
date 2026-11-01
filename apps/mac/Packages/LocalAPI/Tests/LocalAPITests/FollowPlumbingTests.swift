import Foundation
import os
import XCTest

@testable import LocalAPI

@MainActor
final class APIFireFeedTests: XCTestCase {
    private func feed(_ events: OSAllocatedUnfairLock<[APIFireEvent]>, clock: @escaping () -> Double = { 42 }) -> APIFireFeed {
        let feed = APIFireFeed(clock: clock)
        feed.sink = { event in events.withLock { $0.append(event) } }
        return feed
    }

    func testEachPublishIsOneStampedEvent() {
        let events = OSAllocatedUnfairLock<[APIFireEvent]>(initialState: [])
        let feed = feed(events)
        for kind in APIFireEvent.Kind.allCases {
            feed.publish(APIFireEvent(kind: kind, id: kind.rawValue))
        }
        let sent = events.withLock { $0 }
        XCTAssertEqual(sent.map(\.kind), APIFireEvent.Kind.allCases)
        XCTAssertEqual(sent.map(\.seq), Array(1 ... APIFireEvent.Kind.allCases.count))
        XCTAssertEqual(Set(sent.map(\.at)), [42])
        XCTAssertTrue(sent.allSatisfy { $0.source == APIFireSource(kind: .ui) }, "unbound = someone here")
        XCTAssertTrue(sent.allSatisfy { $0.cause == nil })
    }

    func testTheEntryPointsSourceRidesTheFire() {
        let events = OSAllocatedUnfairLock<[APIFireEvent]>(initialState: [])
        let feed = feed(events)
        for kind in [APIFireSource.Kind.scheduler, .midi, .api, .mxu, .timeline, .timecode, .keyboard] {
            APIFireSource.$current.withValue(APIFireSource(kind: kind, name: "Companion")) {
                feed.publish(APIFireEvent(kind: .slide))
            }
        }
        XCTAssertEqual(events.withLock { $0.map(\.source.kind) }, [.scheduler, .midi, .api, .mxu, .timeline, .timecode, .keyboard])
        XCTAssertEqual(events.withLock { $0.first?.source.name }, "Companion")
    }

    func testEffectsCarryTheirFiresSeq() async {
        let events = OSAllocatedUnfairLock<[APIFireEvent]>(initialState: [])
        let feed = feed(events)
        let slide = feed.publish(APIFireEvent(kind: .slide))
        let delayed = APIFireFeed.$cause.withValue(slide) {
            feed.publish(APIFireEvent(kind: .outputPreset, id: "stream"))
            return Task { @MainActor in feed.publish(APIFireEvent(kind: .media, id: "bumper")) }
        }
        await delayed.value
        feed.publish(APIFireEvent(kind: .clearAll))
        XCTAssertEqual(events.withLock { $0.map(\.cause) }, [nil, slide, slide, nil])
    }

    func testWithTheAPIOffPublishOnlyCounts() {
        let feed = APIFireFeed()
        XCTAssertEqual(feed.publish(APIFireEvent(kind: .slide)), 1)
        XCTAssertEqual(feed.publish(APIFireEvent(kind: .slide)), 2)
    }

    func testTheWireRoundTrips() throws {
        var event = APIFireEvent(
            kind: .slide, slide: APIFireSlideCommand(presentationId: "p", slideId: "s", serviceItemId: "i", occurrence: 2),
            settled: true, slideActions: false)
        event.seq = 7
        event.at = 1234.5
        event.source = APIFireSource(kind: .scheduler)
        event.cause = 3
        let data = try XCTUnwrap(APIFireFeed.encode(event))
        XCTAssertEqual(APIFireFeed.decode(data), event)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"timer\""), "absent fields stay off the wire")
    }

    func testTheFiresTopicDocumentsEveryKind() {
        guard case .object(let schema)? = OpenAPIDocument.wireSchemas["FireEvent"],
              case .object(let properties)? = schema["properties"],
              case .object(let kind)? = properties["kind"],
              case .array(let kinds)? = kind["enum"]
        else { return XCTFail("FireEvent schema") }
        XCTAssertEqual(kinds, APIFireEvent.Kind.allCases.map { .string($0.rawValue) })
        XCTAssertEqual(AsyncAPIDocument.payloadSchemas[.fires]?.name, "FireEvent")
    }
}

final class DiscoveryTests: XCTestCase {
    func testTXTCarriesTheIds() {
        let info = APIServerInfo(
            name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1,
            stationHexId: "st1", teamHexId: "tm9", stationName: "Booth")
        XCTAssertEqual(BonjourAdvertiser.txt(for: info), ["stationHexId": "st1", "teamHexId": "tm9", "stationName": "Booth"])
        XCTAssertEqual(
            BonjourAdvertiser.txtRecord(["teamHexId": "tm9", "stationHexId": "st1"]),
            Data([16]) + Data("stationHexId=st1".utf8) + Data([13]) + Data("teamHexId=tm9".utf8))
        let signedOut = APIServerInfo(name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1)
        XCTAssertEqual(BonjourAdvertiser.txt(for: signedOut), [:])
        XCTAssertEqual(BonjourAdvertiser.txtRecord([:]), Data([0]))
    }

    func testPingCarriesTheIdsAndFollowsAnUpdate() async throws {
        let running = try await RunningServer.start(info: APIServerInfo(
            name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1))
        defer { running.stop() }
        var info = try await running.ping()
        XCTAssertNil(info.stationHexId)
        XCTAssertNil(info.teamHexId)
        running.server.update(stationHexId: "st1", teamHexId: "tm9", stationName: "Booth")
        info = try await running.ping()
        XCTAssertEqual(info.stationHexId, "st1")
        XCTAssertEqual(info.teamHexId, "tm9")
        XCTAssertEqual(info.stationName, "Booth")
    }

    func testTheBrowserListsOnlyTheTeamsOtherComputers() {
        func candidate(_ txt: [String: String]) -> BonjourBrowser.Candidate? {
            BonjourBrowser.candidate(name: "Booth Mac", txt: txt, teamHexId: "tm9", ownStationHexId: "me")
        }
        XCTAssertEqual(
            candidate(["teamHexId": "tm9", "stationHexId": "booth"]),
            BonjourBrowser.Candidate(name: "Booth Mac", stationHexId: "booth"))
        XCTAssertEqual(
            candidate(["teamHexId": "tm9", "stationHexId": "booth", "stationName": "Booth"])?.stationName, "Booth",
            "its MxU name, for a backup pairing with the internet down")
        XCTAssertNil(candidate(["teamHexId": "other", "stationHexId": "booth"]), "another team's computer")
        XCTAssertNil(candidate(["teamHexId": "tm9", "stationHexId": "me"]), "this computer")
        XCTAssertNil(candidate(["stationHexId": "booth"]), "signed out")
        XCTAssertNil(candidate(["teamHexId": "tm9"]), "not registered yet")
    }

    func testLiveBrowseFindsAnAdvertisedTeammate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALAPI_LIVE_BONJOUR"] == "1")
        let running = try await RunningServer.start(info: APIServerInfo(
            name: "F1 Booth \(UUID().uuidString.prefix(4))", product: "MxU Slides", apiVersion: "1", schemaVersion: 1,
            stationHexId: "booth", teamHexId: "tm-live"), advertise: true)
        defer { running.stop() }
        let browser = BonjourBrowser(teamHexId: "tm-live", ownStationHexId: "backup")
        let peers = browser.start()
        let found = await first(within: 10) {
            for await list in peers where !list.isEmpty { return list.first }
            return nil
        }
        browser.stop()
        XCTAssertEqual(found?.stationHexId, "booth")
        XCTAssertEqual(found?.port, running.port)
    }
}

final class LocalAPIClientTests: XCTestCase {
    private let endpoint = LocalAPIClient.Endpoint(host: "127.0.0.1", port: 1, token: "mxu_x")

    func testBackoffDoublesToItsCeilingAndStopsAtTheCap() {
        let policy = LocalAPIClient.Policy()
        let delays = (1 ... 10).map { policy.delay(afterFailures: $0) }
        XCTAssertEqual(delays, [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
            .seconds(30), .seconds(30), .seconds(30), nil,
        ])
    }

    func testAnUnreachableComputerGivesUpAfterTenConnects() async {
        let connects = OSAllocatedUnfairLock(initialState: 0)
        let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let client = LocalAPIClient(
            endpoint: endpoint, topics: [.fires],
            connect: { _ in
                connects.withLock { $0 += 1 }
                throw URLError(.cannotConnectToHost)
            },
            sleep: { duration in slept.withLock { $0.append(duration) } })
        await client.start()
        let health = await healthUpdates(client, until: .gaveUp)
        XCTAssertEqual(health.last, .gaveUp)
        XCTAssertFalse(health.contains(.live))
        XCTAssertEqual(connects.withLock { $0 }, 10)
        XCTAssertEqual(slept.withLock { $0 }, (1 ... 9).compactMap { LocalAPIClient.Policy().delay(afterFailures: $0) })
    }

    func testADroppedLiveSessionReconnectsFromTheFirstDelay() async {
        let connects = OSAllocatedUnfairLock(initialState: 0)
        let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        var policy = LocalAPIClient.Policy()
        policy.pingInterval = .seconds(7)
        let client = LocalAPIClient(
            endpoint: endpoint, topics: [.fires], policy: policy,
            connect: { _ in
                let attempt = connects.withLock { $0 += 1; return $0 }
                guard attempt == 1 else { throw URLError(.cannotConnectToHost) }
                return FakeSocket(frames: [#"{"type":"hello","scope":"control"}"#])
            },
            sleep: { duration in slept.withLock { $0.append(duration) } })
        await client.start()
        let health = await healthUpdates(client, until: .gaveUp)
        XCTAssertEqual(Array(health.prefix(3)), [.connecting, .live, .lost(.closed)])
        XCTAssertEqual(slept.withLock { $0.filter { $0 != .seconds(7) }.first }, .milliseconds(500))
        XCTAssertEqual(connects.withLock { $0 }, 10, "the live session plus nine more")
    }

    func testAStoppedBeatReadsFrozenAndSilenceReadsLost() {
        var monitor = HeartbeatMonitor(now: 0)
        monitor.pong(beat: 5, at: 0.5)
        XCTAssertEqual(monitor.reading(at: 1), .live)
        monitor.pong(beat: 5, at: 1.5)
        monitor.pong(beat: 5, at: 2.4)
        XCTAssertEqual(monitor.reading(at: 2.4), .live, "the beat moved 1.9 s ago")
        monitor.pong(beat: 5, at: 2.6)
        XCTAssertEqual(monitor.reading(at: 2.6), .frozen, "pongs still come; the beat stopped over 2 s ago")
        monitor.pong(beat: 6, at: 2.7)
        XCTAssertEqual(monitor.reading(at: 2.7), .live)
        XCTAssertEqual(monitor.reading(at: 5.8), .noAnswer, "no pong for over 3 s")

        var cut = HeartbeatMonitor(now: 0)
        cut.pong(beat: 1, at: 0.5)
        XCTAssertEqual(cut.reading(at: 3.4), .live, "silence with a moving beat is a link going quiet, not a freeze")
        XCTAssertEqual(cut.reading(at: 3.6), .noAnswer)

        var beatless = HeartbeatMonitor(now: 0)
        beatless.pong(beat: nil, at: 2.9)
        XCTAssertEqual(beatless.reading(at: 2.9), .live, "a sender without beats never reads frozen")
    }

    func testEndToEndFiresAndBeat() async throws {
        let beat = OSAllocatedUnfairLock<UInt64>(initialState: 1)
        let heard = OSAllocatedUnfairLock<[String]>(initialState: [])
        let running = try await RunningServer.start(
            info: APIServerInfo(name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1),
            beat: { beat.withLock { $0 } }, heard: { name in heard.withLock { $0.append(name) } })
        defer { running.stop() }
        var policy = LocalAPIClient.Policy()
        policy.pingInterval = .milliseconds(50)
        policy.heartbeat = HeartbeatMonitor.Limits(lostAfter: 2, frozenAfter: 0.3)
        let client = LocalAPIClient(
            endpoint: LocalAPIClient.Endpoint(host: "127.0.0.1", port: running.port, token: running.secret),
            topics: [.fires], policy: policy)
        await client.start()
        defer { Task { await client.stop() } }

        let seen = OSAllocatedUnfairLock<[LocalAPIClient.Update]>(initialState: [])
        let reader = Task { for await update in client.updates { seen.withLock { $0.append(update) } } }
        defer { reader.cancel() }

        func index(after: Int = -1, _ match: @escaping @Sendable (LocalAPIClient.Update) -> Bool) async -> Int? {
            for _ in 0 ..< 250 {
                let found = seen.withLock { list in list.indices.first { $0 > after && match(list[$0]) } }
                if let found { return found }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        let live = await index { if case .health(.live) = $0 { true } else { false } }
        XCTAssertNotNil(live)
        for _ in 0 ..< 50 where heard.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(heard.withLock { $0.first }, "Backup Mac", "each ping names its key to the booth")

        var fire = APIFireEvent(kind: .media, id: "bumper", serviceItemId: "item-3")
        fire.seq = 11
        fire.source = APIFireSource(kind: .scheduler)
        let payload = try XCTUnwrap(APIFireFeed.encode(fire))

        let publisher = Task {
            while !Task.isCancelled {
                await running.server.events.publish(APIEvent(topic: .fires, payload: payload))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let received = await index { if case .event(.fires, _) = $0 { true } else { false } }
        publisher.cancel()
        let arrived = try XCTUnwrap(received.map { at in seen.withLock { $0[at] } })
        guard case .event(_, let data) = arrived else { return XCTFail("no fire arrived") }
        XCTAssertEqual(APIFireFeed.decode(data), fire)

        let frozen = await index { if case .health(.lost(.frozen)) = $0 { true } else { false } }
        XCTAssertNotNil(frozen)
        let ticker = Task {
            while !Task.isCancelled {
                beat.withLock { $0 += 1 }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let back = await index(after: frozen ?? 0) { if case .health(.live) = $0 { true } else { false } }
        ticker.cancel()
        XCTAssertNotNil(back, "the beat moving again reads live")
    }

    func testAWrongTokenNeverGoesLive() async throws {
        let running = try await RunningServer.start(
            info: APIServerInfo(name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1))
        defer { running.stop() }
        var policy = LocalAPIClient.Policy()
        policy.maxAttempts = 2
        policy.baseDelay = .milliseconds(10)
        let client = LocalAPIClient(
            endpoint: LocalAPIClient.Endpoint(host: "127.0.0.1", port: running.port, token: "mxu_wrong"),
            topics: [.fires], policy: policy)
        await client.start()
        let health = await healthUpdates(client, until: .gaveUp)
        XCTAssertEqual(health.last, .gaveUp)
        XCTAssertFalse(health.contains(.live))
    }

    private func healthUpdates(_ client: LocalAPIClient, until end: LocalAPIClient.Health) async -> [LocalAPIClient.Health] {
        await first(within: 10) {
            var seen: [LocalAPIClient.Health] = []
            for await update in client.updates {
                guard case .health(let health) = update else { continue }
                seen.append(health)
                if health == end { break }
            }
            return seen
        } ?? []
    }
}

private final class FakeSocket: LocalAPIClientSocket, @unchecked Sendable {
    private let frames: OSAllocatedUnfairLock<[String]>

    init(frames: [String]) {
        self.frames = OSAllocatedUnfairLock(initialState: frames)
    }

    func send(_ text: String) async throws {}

    func receive() async throws -> String {
        guard let frame = frames.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw URLError(.networkConnectionLost)
        }
        return frame
    }

    func close() {}
}

private struct RunningServer {
    let server: LocalAPIServer
    let task: Task<Void, Error>
    let port: UInt16
    let secret: String

    static func start(
        info: APIServerInfo, advertise: Bool = false, beat: (@Sendable () -> UInt64)? = nil,
        heard: (@Sendable (String) -> Void)? = nil
    ) async throws -> RunningServer {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString).json"))
        let secret = tokens.create(name: "Backup Mac", scope: .control).secret
        let port = UInt16.random(in: 41000 ... 59000)
        let server = LocalAPIServer(
            configuration: .init(port: port, serviceName: info.name, advertise: advertise, info: info, beat: beat, heard: heard),
            routes: [], tokens: tokens)
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        return RunningServer(server: server, task: task, port: port, secret: secret)
    }

    func ping() async throws -> APIServerInfo {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/ping")!)
        return try JSONDecoder().decode(APIServerInfo.self, from: data)
    }

    func stop() {
        task.cancel()
        Task { await server.stop() }
    }
}

private func first<T: Sendable>(within seconds: Double, _ body: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let answer = await group.next() ?? nil
        group.cancelAll()
        return answer
    }
}
