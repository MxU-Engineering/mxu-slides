import XCTest

@testable import LocalAPI

final class APITokenTests: XCTestCase {
    private func makeStore() -> APITokenStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString).json")
        return APITokenStore(fileURL: url)
    }

    func testMintedSecretVerifiesAndIsStoredHashed() {
        let store = makeStore()
        let (token, secret) = store.create(name: "Booth", scope: .control)
        XCTAssertTrue(secret.hasPrefix("mxu_"))
        XCTAssertFalse(token.secretRecord.contains(secret))
        XCTAssertEqual(store.verify(secret: secret)?.id, token.id)
        XCTAssertNil(store.verify(secret: "mxu_wrong"))
    }

    func testRevokedTokenStopsVerifying() {
        let store = makeStore()
        let (token, secret) = store.create(name: "Old", scope: .view)
        store.revoke(id: token.id)
        XCTAssertNil(store.verify(secret: secret))
    }

    func testTokensPersistAcrossReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString).json")
        let secret: String
        do {
            let store = APITokenStore(fileURL: url)
            secret = store.create(name: "Persisted", scope: .edit).secret
        }
        let reloaded = APITokenStore(fileURL: url)
        XCTAssertEqual(reloaded.verify(secret: secret)?.name, "Persisted")
    }

    func testEnsureDefaultKeyMintsOperateKeyOnlyWhenEmpty() {
        let store = makeStore()
        let secret = store.ensureDefaultKey()
        XCTAssertNotNil(secret)
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.all.first?.name, APITokenStore.defaultKeyName)
        XCTAssertEqual(store.all.first?.scope, .control)
        XCTAssertEqual(store.verify(secret: secret!)?.id, store.all.first?.id)

        XCTAssertEqual(store.ensureDefaultKey(), secret)
        XCTAssertEqual(store.defaultKeySecret, secret)
        XCTAssertEqual(store.all.count, 1)
    }

    func testEnsureDefaultKeySkipsWhenHandMadeKeysExist() {
        let store = makeStore()
        store.create(name: "Booth", scope: .view)
        XCTAssertNil(store.ensureDefaultKey())
        XCTAssertNil(store.defaultKeySecret)
        XCTAssertEqual(store.all.count, 1)

        let secret = store.ensureDefaultKey(evenIfPopulated: true)
        XCTAssertNotNil(secret)
        XCTAssertEqual(store.all.count, 2)
        XCTAssertEqual(store.ensureDefaultKey(evenIfPopulated: true), secret)
        XCTAssertEqual(store.all.count, 2)
    }

    func testRevokingDefaultKeyClearsItsSecret() {
        let store = makeStore()
        let secret = store.ensureDefaultKey()!
        store.revoke(id: store.all[0].id)
        XCTAssertNil(store.defaultKeySecret)
        XCTAssertNil(store.verify(secret: secret))

        let again = store.ensureDefaultKey()
        XCTAssertNotNil(again)
        XCTAssertNotEqual(again, secret)
    }

    func testDefaultKeySecretSurvivesReloadThroughVault() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString).json")
        let vault = APIDefaultKeyVault.inMemory()
        let secret = APITokenStore(fileURL: url, vault: vault).ensureDefaultKey()
        let reloaded = APITokenStore(fileURL: url, vault: vault)
        XCTAssertEqual(reloaded.defaultKeySecret, secret)

        let stale = APITokenStore(fileURL: url, vault: .inMemory())
        XCTAssertNil(stale.defaultKeySecret)
    }

    func testScopeNesting() {
        XCTAssertTrue(APIScope.edit.allows(.view))
        XCTAssertTrue(APIScope.edit.allows(.control))
        XCTAssertTrue(APIScope.control.allows(.view))
        XCTAssertFalse(APIScope.view.allows(.control))
        XCTAssertFalse(APIScope.control.allows(.edit))
    }
}

@MainActor
final class FakeBridge: LocalAPIBridge {
    var calls: [String] = []
    var documents: [String: Data] = [:]

    func librarySummary() throws -> APILibrarySummary {
        APILibrarySummary(counts: ["presentations": 2])
    }

    func libraryEntries(kind: APIDocumentKind) throws -> [APILibraryEntry] {
        [APILibraryEntry(id: "p1", name: "Amazing Grace", kind: kind.rawValue, folder: "Lyrics", updatedAt: nil)]
    }

    func documentJSON(kind: APIDocumentKind, id: String) throws -> Data {
        guard let data = documents[id] else {
            throw APIError.notFound("No \(kind.rawValue) with id \(id).")
        }
        return data
    }

    func showStatus() -> APIShowStatus {
        APIShowStatus(
            liveSlide: nil, nextSlideText: nil, mediaLayers: [:],
            overlays: [], alert: nil, currentServiceId: nil
        )
    }

    func timers() -> [APITimerStatus] { [] }
    func audioStatus() -> APIAudioStatus { APIAudioStatus(buses: []) }
    func transportRows() -> [APITransportRow] { [] }
    func outputsStatus() -> APIOutputsStatus { APIOutputsStatus(screens: [], presets: []) }

    func schedulerStatus() -> APISchedulerStatus {
        APISchedulerStatus(enabled: false, nextFire: nil, triggers: [])
    }
    func fireScheduleTrigger(id: String) throws { calls.append("fireScheduleTrigger:\(id)") }
    func midiDevices() -> [APIMIDIDeviceStatus] {
        [APIMIDIDeviceStatus(
            id: "console-item", name: "Console", enabled: true, direction: "both",
            connected: true, destinationUid: 42, sourceUid: 43
        )]
    }
    func setMIDIDeviceEnabled(id: String, enabled: Bool) throws {
        guard id == "console-item" else { throw APIError.notFound("No MIDI device '\(id)'.") }
        calls.append("setMIDIDeviceEnabled:\(id):\(enabled)")
    }
    func videoInputs() -> [APIVideoInputStatus] {
        [APIVideoInputStatus(
            id: "vin-1", name: "Center Camera", kind: "camera",
            sourceId: "cam-uid", audioInputId: "ain-1"
        )]
    }
    func audioInputs() -> [APIAudioInputStatus] {
        [APIAudioInputStatus(
            id: "ain-1", name: "Board Feed", deviceUid: "usb-uid",
            live: true, enabled: true, gain: 0.8, muted: false, mixId: "main"
        )]
    }
    func audioMixes() -> [APIAudioMixStatus] {
        [
            APIAudioMixStatus(
                id: "main", name: "Main", channelOffset: 0, gain: 1, muted: false),
            APIAudioMixStatus(
                id: "mix-b", name: "Broadcast", deviceUid: "dante-uid",
                channelOffset: 2, gain: 0.9, muted: false),
        ]
    }
    func setMixerInput(id: String, command: APIMixerInputCommand) throws {
        guard id == "ain-1" else { throw APIError.notFound("No audio input '\(id)'.") }
        calls.append(
            "setMixerInput:\(id):\(command.enabled.map(String.init) ?? "-")"
                + ":\(command.gain.map { String(format: "%.1f", $0) } ?? "-")"
                + ":\(command.muted.map(String.init) ?? "-")")
    }
    func setSchedulerEnabled(_ enabled: Bool) { calls.append("setSchedulerEnabled:\(enabled)") }
    func setScheduleTriggerEnabled(id: String, enabled: Bool) throws {
        calls.append("setScheduleTriggerEnabled:\(id):\(enabled)")
    }

    var coldDecks: Set<String> = []

    var advanceError = false

    func fireSlide(_ command: APIFireSlideCommand) async throws {
        if let id = command.presentationId, coldDecks.contains(id) {
            await Task.yield()
            coldDecks.remove(id)
        }
        calls.append("fireSlide:\(command.presentationId ?? command.serviceItemId ?? "?")")
    }

    func advance(steps: Int, settled: Bool) async throws {
        if coldDecks.contains("advance") {
            await Task.yield()
            coldDecks.remove("advance")
        }
        if advanceError {
            throw APIError.badRequest("Already at the end of the service.")
        }
        calls.append(settled ? "advance:\(steps):settled" : "advance:\(steps)")
    }

    func clear(_ command: APIClearCommand) throws {
        calls.append("clear:\(command.function ?? command.layer ?? "?")")
    }

    func clearAll() { calls.append("clearAll") }
    func fireMedia(id: String) throws { calls.append("fireMedia:\(id)") }
    func fireOverlay(id: String) throws { calls.append("fireOverlay:\(id)") }
    func dismissOverlay(id: String) throws { calls.append("dismissOverlay:\(id)") }
    func fireActionCombo(id: String) throws { calls.append("fireActionCombo:\(id)") }

    func fireAlert(_ command: APIFireAlertCommand) throws {
        calls.append("fireAlert:\(command.presetId ?? command.message ?? "?")")
    }

    func dismissAlert() { calls.append("dismissAlert") }

    func timerAction(id: String, action: APITimerAction) throws {
        calls.append("timer:\(id):\(action.rawValue)")
    }

    func fireAudioPlaylist(id: String, startAtEntryId: String?) throws {
        calls.append("firePlaylist:\(id)")
    }

    func fireAudioItem(id: String) throws { calls.append("fireAudioItem:\(id)") }
    func stopAudio(_ command: APIAudioStopCommand) throws { calls.append("stopAudio") }
    func audioTransport(_ command: APIAudioTransportCommand) throws {
        calls.append("audioTransport:\(command.action)")
    }

    func mediaTransport(id: String, command: APIMediaTransportCommand) throws {
        calls.append("mediaTransport:\(id):\(command.action)")
    }

    func activateOutputPreset(id: String?) throws {
        calls.append("activatePreset:\(id ?? "none")")
    }

    func selectService(id: String) throws {
        calls.append("selectService:\(id)")
    }

    func createDocument(kind: APIDocumentKind, body: Data) throws -> String {
        let id = "new-id"
        documents[id] = body
        calls.append("create:\(kind.rawValue)")
        return id
    }

    func updateDocument(kind: APIDocumentKind, id: String, body: Data) throws {
        guard documents[id] != nil else { throw APIError.notFound("No such document.") }
        documents[id] = body
        calls.append("update:\(kind.rawValue):\(id)")
    }

    func deleteDocument(kind: APIDocumentKind, id: String) throws {
        documents[id] = nil
        calls.append("delete:\(kind.rawValue):\(id)")
    }

    func addServiceItem(serviceId: String, refId: String, index: Int?) throws {
        calls.append("addItem:\(serviceId):\(refId)")
    }
}

@MainActor
final class APIRouterTests: XCTestCase {
    private func makeRouter() -> (APIRouter, FakeBridge) {
        let bridge = FakeBridge()
        return (APIRouter(routes: APIRouteTable.build(bridge: bridge)), bridge)
    }

    func testPathTemplateMatchCapturesParameters() async throws {
        let (router, _) = makeRouter()
        let match = router.match(method: "POST", path: "/v1/timers/abc/play")
        XCTAssertEqual(match?.route.operationId, "timerPlay")
        XCTAssertEqual(match?.parameters["id"], "abc")
        XCTAssertNil(router.match(method: "POST", path: "/v1/timers/abc/explode"))
    }

    func testControlDispatchReachesBridge() async throws {
        let (router, bridge) = makeRouter()
        let match = try XCTUnwrap(router.match(method: "POST", path: "/v1/show/advance"))
        let context = APIRequestContext(body: Data(#"{"steps":-1}"#.utf8), scope: .control)
        let response = try await match.route.handler(context)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(bridge.calls, ["advance:-1"])

        let settled = APIRequestContext(
            body: Data(#"{"steps":1,"settled":true}"#.utf8), scope: .control
        )
        _ = try await match.route.handler(settled)
        XCTAssertEqual(bridge.calls.last, "advance:1:settled")
    }

    func testSlideFireIntoAColdDeckFiresAfterTheFill() async throws {
        let (router, bridge) = makeRouter()
        bridge.coldDecks = ["p9"]
        let match = try XCTUnwrap(router.match(method: "POST", path: "/v1/show/slide"))
        let context = APIRequestContext(body: Data(#"{"presentationId":"p9","slideIndex":0}"#.utf8), scope: .control)
        let response = try await match.route.handler(context)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(bridge.calls, ["fireSlide:p9"])
        XCTAssertTrue(bridge.coldDecks.isEmpty)
    }

    func testAdvanceIntoAColdWalkRunsAfterTheFillAndItsErrorReachesTheCaller() async throws {
        let (router, bridge) = makeRouter()
        bridge.coldDecks = ["advance"]
        let match = try XCTUnwrap(router.match(method: "POST", path: "/v1/show/advance"))
        let response = try await match.route.handler(APIRequestContext(body: Data(#"{"steps":1}"#.utf8), scope: .control))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(bridge.calls, ["advance:1"])
        XCTAssertTrue(bridge.coldDecks.isEmpty)

        bridge.coldDecks = ["advance"]
        bridge.advanceError = true
        do {
            _ = try await match.route.handler(APIRequestContext(body: Data(#"{"steps":1}"#.utf8), scope: .control))
            XCTFail("the advance's error reaches the caller after the fill")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 400)
        }
    }

    func testDocumentCRUDDispatch() async throws {
        let (router, bridge) = makeRouter()
        let create = try XCTUnwrap(router.match(method: "POST", path: "/v1/documents/presentations"))
        let body = Data(#"{"name":"New Song"}"#.utf8)
        let context = APIRequestContext(
            pathParameters: create.parameters, body: body, scope: .edit
        )
        let created = try await create.route.handler(context)
        XCTAssertEqual(created.status, 201)
        let response = try JSONDecoder().decode(APICreatedResponse.self, from: created.body)
        XCTAssertEqual(response.id, "new-id")

        let get = try XCTUnwrap(router.match(method: "GET", path: "/v1/documents/presentations/new-id"))
        let fetched = try await get.route.handler(
            APIRequestContext(pathParameters: get.parameters, scope: .view)
        )
        XCTAssertEqual(fetched.body, body)
        XCTAssertEqual(bridge.calls, ["create:presentations"])
    }

    func testUnknownDocumentKindIsBadRequest() async throws {
        let (router, _) = makeRouter()
        let match = try XCTUnwrap(router.match(method: "GET", path: "/v1/library/nonsense"))
        do {
            _ = try await match.route.handler(
                APIRequestContext(pathParameters: match.parameters, scope: .view)
            )
            XCTFail("Expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 400)
        }
    }

    func testInputsListAndMixerDispatch() async throws {

        let (router, bridge) = makeRouter()
        let video = try XCTUnwrap(router.match(method: "GET", path: "/v1/inputs/video"))
        let videoListed = try await video.route.handler(APIRequestContext(scope: .view))
        let videoInputs = try JSONDecoder().decode(
            [APIVideoInputStatus].self, from: videoListed.body)
        XCTAssertEqual(videoInputs.first?.id, "vin-1")
        XCTAssertEqual(videoInputs.first?.kind, "camera")
        XCTAssertEqual(videoInputs.first?.audioInputId, "ain-1")

        let audio = try XCTUnwrap(router.match(method: "GET", path: "/v1/inputs/audio"))
        let audioListed = try await audio.route.handler(APIRequestContext(scope: .view))
        let audioInputs = try JSONDecoder().decode(
            [APIAudioInputStatus].self, from: audioListed.body)
        XCTAssertEqual(audioInputs.first?.id, "ain-1")
        XCTAssertEqual(audioInputs.first?.live, true)

        let mixes = try XCTUnwrap(router.match(method: "GET", path: "/v1/audio/mixes"))
        let mixesListed = try await mixes.route.handler(APIRequestContext(scope: .view))
        let mixStatuses = try JSONDecoder().decode(
            [APIAudioMixStatus].self, from: mixesListed.body)
        XCTAssertEqual(mixStatuses.map(\.id), ["main", "mix-b"])
        XCTAssertEqual(mixStatuses.last?.channelOffset, 2)

        let mix = try XCTUnwrap(router.match(method: "POST", path: "/v1/inputs/audio/ain-1/mixer"))
        let response = try await mix.route.handler(APIRequestContext(
            pathParameters: mix.parameters,
            body: Data(#"{"enabled":true,"gain":0.5}"#.utf8), scope: .control
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(bridge.calls, ["setMixerInput:ain-1:true:0.5:-"])
    }

    func testMixerUnknownInputIs404() async throws {
        let (router, _) = makeRouter()
        let match = try XCTUnwrap(router.match(method: "POST", path: "/v1/inputs/audio/ghost/mixer"))
        do {
            _ = try await match.route.handler(APIRequestContext(
                pathParameters: match.parameters,
                body: Data(#"{"muted":true}"#.utf8), scope: .control
            ))
            XCTFail("Expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testMIDIDeviceListAndEnableDispatch() async throws {
        let (router, bridge) = makeRouter()
        let list = try XCTUnwrap(router.match(method: "GET", path: "/v1/midi/devices"))
        let listed = try await list.route.handler(APIRequestContext(scope: .view))
        let devices = try JSONDecoder().decode([APIMIDIDeviceStatus].self, from: listed.body)
        XCTAssertEqual(devices.first?.id, "console-item")
        XCTAssertEqual(devices.first?.direction, "both")
        XCTAssertEqual(devices.first?.destinationUid, 42)

        let toggle = try XCTUnwrap(router.match(method: "POST", path: "/v1/midi/devices/console-item/enabled"))
        let context = APIRequestContext(
            pathParameters: toggle.parameters,
            body: Data(#"{"enabled":false}"#.utf8), scope: .control
        )
        let response = try await toggle.route.handler(context)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(bridge.calls, ["setMIDIDeviceEnabled:console-item:false"])
    }

    func testMIDIDeviceEnableUnknownIdIs404() async throws {
        let (router, _) = makeRouter()
        let match = try XCTUnwrap(router.match(method: "POST", path: "/v1/midi/devices/ghost/enabled"))
        do {
            _ = try await match.route.handler(APIRequestContext(
                pathParameters: match.parameters,
                body: Data(#"{"enabled":true}"#.utf8), scope: .control
            ))
            XCTFail("Expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testEveryRouteHasUniqueOperationIdAndMethodPath() async {
        let (router, _) = makeRouter()
        let operationIds = router.routes.map(\.operationId)
        XCTAssertEqual(operationIds.count, Set(operationIds).count)
        let pairs = router.routes.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(pairs.count, Set(pairs).count)
    }

    func testEncodedPathSeparatorInParameterMatchesNothing() async {
        let (router, _) = makeRouter()
        XCTAssertNil(router.match(
            method: "GET", path: "/v1/documents/presentations/..%2F..%2Fsecrets"
        ))
        XCTAssertNil(router.match(
            method: "DELETE", path: "/v1/documents/media/evil%5C..%5Cpath"
        ))

        XCTAssertNotNil(router.match(method: "GET", path: "/v1/documents/presentations/.."))
    }
}

final class WebSocketFrameTests: XCTestCase {
    func testClientControlledStringsAreEscaped() throws {
        let hostile = #"x","status":200,"forged":"yes"#
        let frame = try XCTUnwrap(APIWebSocketHandler.frameText(
            ["type": "result", "id": hostile, "status": 404]
        ))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["id"] as? String, hostile)
        XCTAssertEqual(decoded["status"] as? Int, 404)
        XCTAssertNil(decoded["forged"])
    }

    func testPayloadSplicesAsRawJSON() throws {
        let payload = Data(#"{"liveSlide":null,"overlays":[]}"#.utf8)
        let frame = try XCTUnwrap(APIWebSocketHandler.frameText(
            ["type": "event", "topic": "show"], payload: ("data", payload)
        ))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        let data = try XCTUnwrap(decoded["data"] as? [String: Any])
        XCTAssertNotNil(data["overlays"])
        XCTAssertEqual(decoded["topic"] as? String, "show")
    }
}

@MainActor
final class OpenAPIDocumentTests: XCTestCase {
    private func makeRoutes() -> [APIRoute] {
        APIRouteTable.build(bridge: FakeBridge())
    }

    func testEveryRouteAppearsInComposedDocument() async throws {
        let routes = makeRoutes()
        let document = OpenAPIDocument.compose(routes: routes, schemaVersion: 12)
        guard case .object(let root) = document,
              case .object(let paths)? = root["paths"]
        else {
            return XCTFail("Malformed document")
        }
        for route in routes {
            guard case .object(let item)? = paths[route.path] else {
                return XCTFail("Missing path \(route.path)")
            }
            XCTAssertNotNil(item[route.method.lowercased()], "Missing \(route.method) \(route.path)")
        }
    }

    func testDocumentSchemasFromCodegenAreEmbedded() throws {
        let schemas = OpenAPIDocument.documentSchemas()
        XCTAssertNotNil(schemas["Presentation"], "codegen-emitted document schemas missing")
        XCTAssertNotNil(schemas["Service"])
        XCTAssertGreaterThan(OpenAPIDocument.documentSchemaVersion(), 0)

        XCTAssertGreaterThanOrEqual(OpenAPIDocument.documentSchemaVersion(), 87)
        guard case .object(let mediaItem)? = schemas["MediaItem"],
              case .object(let properties)? = mediaItem["properties"]
        else {
            return XCTFail("MediaItem schema missing")
        }
        XCTAssertNotNil(properties["actions"], "v87 MediaItem.actions missing from API schema")
        XCTAssertNotNil(properties["autoAdvance"], "v87 MediaItem.autoAdvance missing from API schema")
    }

    func testEveryReferencedSchemaResolves() async throws {
        let routes = makeRoutes()
        let document = OpenAPIDocument.compose(
            routes: routes, schemaVersion: OpenAPIDocument.documentSchemaVersion()
        )
        var available: Set<String> = []
        guard case .object(let root) = document,
              case .object(let components)? = root["components"],
              case .object(let schemas)? = components["schemas"]
        else {
            return XCTFail("Malformed document")
        }
        available.formUnion(schemas.keys)
        var references: Set<String> = []
        collectRefs(in: document, into: &references)
        for reference in references {
            XCTAssertTrue(available.contains(reference), "Unresolved $ref: \(reference)")
        }
    }

    func testServedDocumentOmitsServerSyncFields() async throws {
        let document = OpenAPIDocument.compose(
            routes: makeRoutes(), schemaVersion: OpenAPIDocument.documentSchemaVersion()
        )
        guard case .object(let root) = document,
              case .object(let components)? = root["components"],
              case .object(let schemas)? = components["schemas"],
              case .object(let item)? = schemas["ServiceItem"],
              case .object(let itemProperties)? = item["properties"],
              case .object(let service)? = schemas["Service"],
              case .object(let serviceProperties)? = service["properties"]
        else { return XCTFail("Malformed document") }
        XCTAssertNotNil(itemProperties["refId"])
        XCTAssertNil(itemProperties["mxuItemHexId"])
        XCTAssertNil(itemProperties["excludedTimeHexIds"])
        XCTAssertNil(serviceProperties["mxuPlanHexId"])
        XCTAssertNil(schemas["MxUPlanTime"])
    }

    func testAsyncAPIChannelsCarryTypedPayloads() throws {
        let document = AsyncAPIDocument.compose(schemaVersion: 1)
        guard case .object(let root) = document,
              case .object(let channels)? = root["channels"],
              case .object(let components)? = root["components"],
              case .object(let messages)? = components["messages"]
        else { return XCTFail("Malformed document") }
        for topic in APITopic.allCases {
            XCTAssertNotNil(channels[topic.rawValue], topic.rawValue)
            XCTAssertNotNil(messages["\(topic.rawValue)Event"], topic.rawValue)
        }
        var references: Set<String> = []
        collectRefs(in: document, into: &references)
        for reference in references {
            XCTAssertTrue(messages[reference] != nil, "Unresolved $ref: \(reference)")
        }
        guard case .object(let show)? = messages["showEvent"],
              case .object(let payload)? = show["payload"],
              case .object(let properties)? = payload["properties"],
              case .object(let data)? = properties["data"],
              case .object(let dataProperties)? = data["properties"],
              case .object(let live)? = dataProperties["liveSlide"],
              case .object(let liveProperties)? = live["properties"]
        else { return XCTFail("show payload is not the ShowStatus shape") }
        XCTAssertNotNil(liveProperties["stepIndex"])
        XCTAssertNotNil(liveProperties["stepCount"])
        if case .object(let channel)? = channels["show"], case .string(let text)? = channel["description"] {
            XCTAssertTrue(text.contains("/v1/show/advance"))
        } else { XCTFail() }
    }

    private func collectRefs(in value: JSONValue, into refs: inout Set<String>) {
        switch value {
        case .object(let object):
            for (key, child) in object {
                if key == "$ref", case .string(let path) = child,
                   let name = path.split(separator: "/").last {
                    refs.insert(String(name))
                } else {
                    collectRefs(in: child, into: &refs)
                }
            }
        case .array(let array):
            for child in array {
                collectRefs(in: child, into: &refs)
            }
        default:
            break
        }
    }
}
