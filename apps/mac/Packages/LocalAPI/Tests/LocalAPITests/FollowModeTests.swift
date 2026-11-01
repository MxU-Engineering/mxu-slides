import Foundation
import XCTest

@testable import LocalAPI

@MainActor
final class FollowReplayTests: XCTestCase {
    private func event(_ kind: APIFireEvent.Kind, cause: Int? = nil, _ build: (inout APIFireEvent) -> Void = { _ in }) -> APIFireEvent {
        var event = APIFireEvent(kind: kind)
        event.cause = cause
        build(&event)
        return event
    }

    func testOnlyARootFireReplaysItsEffectsFollowFromIt() {
        XCTAssertTrue(FollowReplay.replays(event(.combo)))
        XCTAssertFalse(FollowReplay.replays(event(.outputPreset, cause: 4)), "a combo's step runs here from the combo")
    }

    func testEachFireRunsTheMatchingBridgeCall() async throws {
        let bridge = FakeBridge()
        let fires: [APIFireEvent] = [
            event(.slide) { $0.slide = APIFireSlideCommand(presentationId: "p1", slideId: "s2") },
            event(.step) { $0.steps = -1 },
            event(.clear) { $0.clear = APIClearCommand(function: "media") },
            event(.clearAll),
            event(.media) { $0.id = "m1" },
            event(.overlay) { $0.id = "o1" },
            event(.dismissOverlay) { $0.id = "o1" },
            event(.alert) { $0.alert = APIFireAlertCommand(message: "Parking lot") },
            event(.dismissAlert),
            event(.timer) { $0.id = "t1"; $0.timer = .play },
            event(.combo) { $0.id = "c1" },
            event(.outputPreset) { $0.id = nil },
            event(.lock) { $0.locked = true },
            event(.audioItem) { $0.id = "a1" },
            event(.audioPlaylist) { $0.id = "pl1"; $0.entryId = "e2" },
            event(.stopAudio),
            event(.audioTransport) { $0.audioTransport = APIAudioTransportCommand(action: "next") },
            event(.mediaTransport) { $0.id = "m1"; $0.mediaTransport = APIMediaTransportCommand(action: "pause") },
        ]
        XCTAssertEqual(Set(fires.map(\.kind)), Set(APIFireEvent.Kind.allCases), "every kind replays")
        for fire in fires { try await FollowReplay.apply(fire, to: bridge) }
        XCTAssertEqual(bridge.calls, [
            "fireSlide:p1", "advance:-1", "clear:media", "clearAll", "fireMedia:m1", "fireOverlay:o1", "dismissOverlay:o1",
            "fireAlert:Parking lot", "dismissAlert", "timer:t1:play", "fireActionCombo:c1", "activatePreset:none",
            "setLock:true:-", "fireAudioItem:a1", "firePlaylist:pl1", "stopAudio", "audioTransport:next", "mediaTransport:m1:pause",
        ])
    }

    func testALibraryFireReplaysBySlideNotAsAServiceItem() {
        let library = FollowReplay.command(for: APIFireSlideCommand(presentationId: "p1", slideId: "s2", serviceItemId: "p1", occurrence: 3))
        XCTAssertNil(library.serviceItemId)
        XCTAssertEqual(library.slideId, "s2")
        let service = FollowReplay.command(for: APIFireSlideCommand(presentationId: "p1", slideId: "s2", serviceItemId: "item-9", occurrence: 3))
        XCTAssertEqual(service.serviceItemId, "item-9", "a service fire keeps its item and position")
    }
}

final class FollowPairingTests: XCTestCase {
    private func store() -> APITokenStore {
        APITokenStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString).json"))
    }

    private func body(_ code: String, team: String = "team1") -> Data {
        try! JSONEncoder().encode(APIFollowPairRequest(code: code, teamHexId: team, stationHexId: "backup1", name: "Backup Mac"))
    }

    func testTheRightCodeFromATeammateGetsAnOperateKeyNamedForIt() throws {
        let tokens = store()
        let pairing = FollowPairing(code: "4817")
        XCTAssertEqual(pairing.answer(body("4817", team: "other"), teamHexId: "team1", tokens: tokens).status, 403)
        let answer = pairing.answer(body("4817"), teamHexId: "team1", tokens: tokens)
        XCTAssertEqual(answer.status, 200)
        let key = try JSONDecoder().decode(APIFollowPairResponse.self, from: answer.body).token
        let token = try XCTUnwrap(tokens.verify(secret: key))
        XCTAssertEqual(token.scope, .control)
        XCTAssertEqual(token.name, "Backup: Backup Mac")
    }

    func testFiveWrongCodesRetireTheCodeUntilANewOne() {
        let tokens = store()
        let pairing = FollowPairing(code: "4817")
        for _ in 0 ..< FollowPairing.maxAttempts {
            XCTAssertEqual(pairing.answer(body("0000"), teamHexId: "team1", tokens: tokens).status, 403)
        }
        XCTAssertNil(pairing.current)
        XCTAssertEqual(pairing.answer(body("4817"), teamHexId: "team1", tokens: tokens).status, 403, "even the right code, once retired")
        let fresh = pairing.refresh()
        XCTAssertEqual(pairing.answer(body(fresh), teamHexId: "team1", tokens: tokens).status, 200)
        XCTAssertTrue(tokens.all.count == 1)
    }
}

final class FollowHoldTests: XCTestCase {
    func testABackupAnswersReadsAndHoldsEverythingElseOverRESTAndPairsThroughItsDoor() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString).json"))
        let secret = tokens.create(name: "Companion", scope: .control).secret
        let pairing = FollowPairing(code: "1234")
        let routes = [
            APIRoute("GET", "/v1/show", scope: .view, operationId: "show", summary: "", tag: "", responseSchema: .object([:])) { _ in .ok },
            APIRoute("POST", "/v1/show/next", scope: .control, operationId: "next", summary: "", tag: "", responseSchema: .object([:])) { _ in .ok },
        ]
        let port = UInt16.random(in: 41000 ... 59000)
        let info = APIServerInfo(name: "Backup Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1)
        let server = LocalAPIServer(
            configuration: .init(
                port: port, serviceName: "Backup Mac", advertise: false, info: info,
                hold: { FollowHold.error(for: $0, following: "Booth Mac") },
                pair: { pairing.answer($0, teamHexId: "team1", tokens: tokens) }),
            routes: routes, tokens: tokens)
        let task = Task { try await server.run() }
        defer { task.cancel(); Task { await server.stop() } }
        try await server.waitUntilListening()

        func call(_ method: String, _ path: String, body: Data? = nil, auth: Bool = true) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.httpBody = body
            if auth { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let read = try await call("GET", "/v1/show")
        XCTAssertEqual(read.0, 200)
        let next = try await call("POST", "/v1/show/next")
        XCTAssertEqual(next.0, 409)
        XCTAssertEqual(try JSONDecoder().decode(APIError.self, from: next.1).code, "backing_up")
        let paired = try await call(
            "POST", "/v1/follow/pair",
            body: try JSONEncoder().encode(APIFollowPairRequest(code: "1234", teamHexId: "team1", stationHexId: "b", name: "Lobby Mac")), auth: false)
        XCTAssertEqual(paired.0, 200, "pairing needs no key")
    }
}

@MainActor
final class FollowEndToEndTests: XCTestCase {
    func testABackupPairsByCodeFollowsTheBoothsFiresAndRunsOnlyTheRoots() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString).json"))
        let pairing = FollowPairing(code: "2468")
        let port = UInt16.random(in: 41000 ... 59000)
        let info = APIServerInfo(name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1)
        let booth = LocalAPIServer(
            configuration: .init(port: port, serviceName: "Booth Mac", advertise: false, info: info,
                                 pair: { pairing.answer($0, teamHexId: "team1", tokens: tokens) }),
            routes: [], tokens: tokens)
        let task = Task { try await booth.run() }
        defer { task.cancel(); Task { await booth.stop() } }
        try await booth.waitUntilListening()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/follow/pair")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(APIFollowPairRequest(code: "2468", teamHexId: "team1", stationHexId: "backup", name: "Backup Mac"))
        let (data, _) = try await URLSession.shared.data(for: request)
        let key = try JSONDecoder().decode(APIFollowPairResponse.self, from: data).token

        let client = LocalAPIClient(endpoint: .init(host: "127.0.0.1", port: port, token: key), topics: [.fires])
        await client.start()
        defer { Task { await client.stop() } }
        let bridge = FakeBridge()
        var combo = APIFireEvent(kind: .combo, id: "c1")
        combo.seq = 1
        var effect = APIFireEvent(kind: .outputPreset, id: "p1")
        effect.seq = 2
        effect.cause = 1

        var publisher: Task<Void, Never>?
        let loop = Task { @MainActor in
            var live = false
            for await update in client.updates {
                switch update {
                case .health(.live) where !live:
                    live = true

                    publisher = Task {
                        while !Task.isCancelled {
                            for event in [combo, effect] {
                                await booth.events.publish(APIEvent(topic: .fires, payload: APIFireFeed.encode(event)!))
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                case .event(.fires, let payload):
                    if let event = APIFireFeed.decode(payload), FollowReplay.replays(event) {
                        try? await FollowReplay.apply(event, to: bridge)
                    }
                default:
                    break
                }
                if !bridge.calls.isEmpty { break }
            }
        }
        let watchdog = Task { try await Task.sleep(for: .seconds(10)); loop.cancel() }
        await loop.value
        watchdog.cancel()
        publisher?.cancel()
        XCTAssertEqual(bridge.calls.first, "fireActionCombo:c1", "the combo replays")
        XCTAssertFalse(bridge.calls.contains("activatePreset:p1"), "its preset switch follows from it here, never replayed")
    }
}
