import Foundation
import os
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
        XCTAssertEqual(Set(fires.map(\.kind)), Set(APIFireEvent.Kind.allCases).subtracting([.role, .capture, .quit]), "every fire kind replays")
        XCTAssertFalse(FollowReplay.replays(event(.role) { $0.term = 2; $0.inCharge = "booth" }), "who is in charge is never a fire")
        XCTAssertFalse(FollowReplay.replays(event(.capture) { $0.id = "stream1" }), "a backup never starts the booth's stream on its own")
        XCTAssertFalse(FollowReplay.replays(event(.quit)), "the booth quitting is never a fire")
        for fire in fires { try await FollowReplay.apply(fire, to: bridge) }
        XCTAssertEqual(bridge.calls, [
            "fireSlide:p1", "advance:-1", "clear:media", "clearAll", "fireMedia:m1", "fireOverlay:o1", "dismissOverlay:o1",
            "fireAlert:Parking lot", "dismissAlert", "timer:t1:play", "fireActionCombo:c1", "activatePreset:none",
            "setLock:true:-", "fireAudioItem:a1", "firePlaylist:pl1", "stopAudio", "audioTransport:next", "mediaTransport:m1:pause",
        ])
    }

    func testCatchUpRunsOnlyWhatDiffersFromTheBooth() throws {
        func show(_ json: String) throws -> APIShowStatus {
            try JSONDecoder().decode(APIShowStatus.self, from: Data(json.utf8))
        }
        let slide = #"{"presentationId":"p1","slideId":"s1"}"#
        let booth = try show(#"{"mediaLayers":{"background":{"mediaId":"loop"},"foreground":{"mediaId":"walkin"}},"overlays":[{"id":"lower","name":"Lower third"}]}"#)
        let here = try show(#"{"liveSlide":\#(slide),"mediaLayers":{"background":{"mediaId":"loop"},"loopingVideos":{"mediaId":"old"}},"overlays":[{"id":"logo","name":"Logo"}]}"#)
        let events = FollowReplay.catchUp(booth: booth, here: here)
        XCTAssertEqual(events.map(\.kind), [.clear, .clear, .dismissOverlay, .media, .overlay])
        XCTAssertEqual(events[0].clear, APIClearCommand(function: "slides"), "the booth shows no slide")
        XCTAssertEqual(events[1].clear, APIClearCommand(layer: "loopingVideos"), "a video the booth doesn't show comes down")
        XCTAssertEqual(events[2].id, "logo")
        XCTAssertEqual(events[3].id, "walkin", "the loop already in step keeps playing")
        XCTAssertEqual(events[4].id, "lower")
        XCTAssertTrue(FollowReplay.catchUp(booth: here, here: here).isEmpty, "in step: nothing runs")
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
        let again = pairing.answer(body("4817"), teamHexId: "team1", tokens: tokens)
        let second = try JSONDecoder().decode(APIFollowPairResponse.self, from: again.body).token
        XCTAssertNil(tokens.verify(secret: key), "pairing again replaces the old key")
        XCTAssertNotNil(tokens.verify(secret: second))
        XCTAssertEqual(tokens.all.filter { $0.name == "Backup: Backup Mac" }.count, 1)
    }

    func testTheBoothSeesWhichBackupsArePinging() async throws {
        let seen = OSAllocatedUnfairLock<[Set<String>]>(initialState: [])
        let presence = FollowPresence(lostAfter: .milliseconds(150)) { names in seen.withLock { $0.append(names) } }
        presence.heard(tokenName: "Companion")
        presence.heard(tokenName: "Backup: Backup Mac")
        presence.heard(tokenName: "Backup: Backup Mac")
        XCTAssertEqual(seen.withLock { $0 }, [["Backup Mac"]], "a key that isn't a backup's never counts; a second ping changes nothing")
        for _ in 0 ..< 50 where seen.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(seen.withLock { $0 }, [["Backup Mac"], []], "quiet past lostAfter: dropped")
    }

    func testStopBackingUpForgetsTheKeyItCalledWith() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString).json"))
        let key = tokens.create(name: "Backup: Backup Mac", scope: .control).secret
        let port = UInt16.random(in: 41000 ... 59000)
        let info = APIServerInfo(name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1)
        let booth = LocalAPIServer(
            configuration: .init(port: port, serviceName: "Booth Mac", advertise: false, info: info, unpair: { tokens.revoke(id: $0.id) }),
            routes: [], tokens: tokens)
        let task = Task { try await booth.run() }
        defer { task.cancel(); Task { await booth.stop() } }
        try await booth.waitUntilListening()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/follow/unpair")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        XCTAssertNil(tokens.verify(secret: key))
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
        XCTAssertNil(FollowHold.error(for: APIRoute("POST", "/v1/follow/takeover", scope: .control, operationId: "t", summary: "", tag: "", responseSchema: .object([:])) { _ in .ok }, following: "Booth Mac"), "Companion can still take over")
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

final class FollowFilesTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)

    func testTheBackupFetchesChangedItemsAndMissingFilesOnly() {
        let items = [
            FollowFiles.Item(kind: "presentation", id: "same", heads: ["h1"]),
            FollowFiles.Item(kind: "presentation", id: "changed", heads: ["h2"]),
            FollowFiles.Item(kind: "media", id: "new", heads: ["h3"], file: sha, ext: "mp4"),
            FollowFiles.Item(kind: "media", id: "fileHere", heads: ["h4"], file: "cd", ext: "mov"),
        ]
        let wanted = FollowFiles.wanted(items, heads: ["presentation/same": ["h1"], "presentation/changed": ["h1"], "media/fileHere": ["h4"]], filesHere: ["cd"])
        XCTAssertEqual(wanted.documents.map(\.id), ["changed", "new"])
        XCTAssertEqual(wanted.files, [sha])
    }

    func testCopiesTheBoothNoLongerHoldsGo() {
        let booth = [FollowFiles.Item(kind: "presentation", id: "kept", heads: ["h1"])]
        XCTAssertEqual(FollowFiles.gone(copied: ["presentation/kept", "presentation/deleted", "media/m1"], booth: booth), ["media/m1", "presentation/deleted"])
        XCTAssertEqual(FollowFiles.gone(copied: [], booth: booth), [], "nothing this backup didn't copy")
    }

    func testADriveItemSaysSoAndAnOlderBoothsListStillReads() throws {
        let drive = FollowFiles.Item(kind: "presentation", id: "d1", heads: ["h1"], area: "team")
        XCTAssertEqual(try JSONDecoder().decode(FollowFiles.Item.self, from: JSONEncoder().encode(drive)).area, "team")
        let older = Data(#"{"kind":"presentation","id":"d1","heads":["h1"]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FollowFiles.Item.self, from: older).area)
    }

    func testARefusalReadsAsItsMessage() {
        XCTAssertEqual(APIError(status: 403, code: "wrong_code", message: "That code doesn't match.").localizedDescription, "That code doesn't match.")
    }

    func testAFileNameIsAHashNeverAPath() {
        XCTAssertTrue(FollowFiles.isHash(sha))
        XCTAssertFalse(FollowFiles.isHash("../../secrets"))
        XCTAssertFalse(FollowFiles.isHash(sha.uppercased()))
    }

    func testTheBoothStreamsAFileToAnOperateKeyOnly() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString).json"))
        let operate = tokens.create(name: "Backup Mac", scope: .control).secret
        let watch = tokens.create(name: "Viewer", scope: .view).secret
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(sha).mp4")
        try Data("clip".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let port = UInt16.random(in: 41000 ... 59000)
        let info = APIServerInfo(name: "Booth Mac", product: "MxU Slides", apiVersion: "1", schemaVersion: 1)
        let sha = self.sha
        let booth = LocalAPIServer(
            configuration: .init(port: port, serviceName: "Booth Mac", advertise: false, info: info, blob: { $0 == sha ? file : nil }),
            routes: [], tokens: tokens)
        let task = Task { try await booth.run() }
        defer { task.cancel(); Task { await booth.stop() } }
        try await booth.waitUntilListening()

        func get(_ name: String, key: String) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/follow/blobs/\(name)")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let (status, data) = try await get(sha, key: operate)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "clip")
        let (watched, _) = try await get(sha, key: watch)
        XCTAssertEqual(watched, 403, "a Watch key never downloads media")
        let (missing, _) = try await get(String(repeating: "0", count: 64), key: operate)
        XCTAssertEqual(missing, 404)
    }
}
