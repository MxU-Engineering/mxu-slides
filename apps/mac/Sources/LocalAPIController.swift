import Foundation
import LocalAPI
import Observation
import os
import Security

enum NetworkInfo {

    static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let addr = pointer.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            let ip = String(cString: host)
            let name = String(cString: pointer.pointee.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil, name.hasPrefix("en") { fallback = ip }
        }
        return fallback
    }
}

enum LocalAPIDefaultKeyKeychain {
    private static let service = "com.example.mxuslides.localapi"
    private static let account = "default-key"

    static let vault = honorsSkipKeychain && ProcessInfo.processInfo.environment["MXU_SKIP_KEYCHAIN"] == "1"
        ? APIDefaultKeyVault.inMemory()
        : APIDefaultKeyVault(load: { load() }, save: { save($0) }, clear: { clear() })

    #if DEBUG || MXU_PERF_HOOKS
    private static let honorsSkipKeychain = true
    #else
    private static let honorsSkipKeychain = false
    #endif

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ secret: String) {
        clear()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

@MainActor
@Observable
final class LocalAPIController {
    static let enabledKey = "localAPI.enabled"
    static let portKey = "localAPI.port"
    static let defaultPort: UInt16 = 6980
    static let defaultKeyOfferedKey = "localAPI.defaultKeyOffered"

    private(set) var running = false
    private(set) var lastError: String?
    let tokens: APITokenStore

    private(set) var keysRevision = 0

    private let appModel: AppModel

    let bridge: AppAPIBridge
    private var server: LocalAPIServer?
    private var serverTask: Task<Void, Never>?

    private var generation = 0

    private var cachedDefaultKeySecret: String?
    private var defaultKeyTask: Task<Void, Never>?

    private var firesTask: Task<Void, Never>?

    let followPairing = FollowPairing()
    private(set) var pairingCode = ""
    @ObservationIgnored private nonisolated let teamHexId = OSAllocatedUnfairLock<String?>(initialState: nil)

    @ObservationIgnored var identity: () -> (stationHexId: String?, teamHexId: String?, stationName: String?) = { (nil, nil, nil) } {
        didSet { observeIdentity() }
    }

    init(
        appModel: AppModel, controls: ServiceControls,
        outputPresets: OutputPresetsController, render: RenderContext,
        scheduler: SchedulerController? = nil
    ) {
        self.appModel = appModel
        self.bridge = AppAPIBridge(
            appModel: appModel, controls: controls,
            outputPresets: outputPresets, render: render,
            scheduler: scheduler
        )
        self.tokens = APITokenStore(
            fileURL: appModel.client.rootURL
                .appendingPathComponent("local-api-tokens.json"),
            vault: LocalAPIDefaultKeyKeychain.vault
        )
        if enabled {
            start()
        }
    }

    var defaultKeySecret: String? {
        access(keyPath: \.keysRevision)
        return cachedDefaultKeySecret
    }

    var hasAnyKey: Bool {
        access(keyPath: \.keysRevision)
        return !tokens.all.isEmpty
    }

    var allKeys: [APIToken] {
        access(keyPath: \.keysRevision)
        return tokens.all
    }

    func keysDidChange() {
        keysRevision += 1
    }

    private func resolveDefaultKey() {
        guard defaultKeyTask == nil else { return }
        let store = tokens
        let offered = UserDefaults.standard.bool(forKey: Self.defaultKeyOfferedKey)
        defaultKeyTask = Task { [weak self] in
            let secret = await Task.detached(priority: .utility) {
                store.ensureDefaultKey(evenIfPopulated: !offered)
            }.value
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: Self.defaultKeyOfferedKey)
            self.cachedDefaultKeySecret = secret
            self.defaultKeyTask = nil
            self.keysDidChange()
        }
    }

    func revokeKey(id: String) {
        let store = tokens
        Task { [weak self] in
            let secret = await Task.detached(priority: .utility) {
                store.revoke(id: id)
                return store.defaultKeySecret
            }.value
            guard let self else { return }
            self.cachedDefaultKeySecret = secret
            self.keysDidChange()
        }
    }

    var enabled: Bool {
        get {
            access(keyPath: \.running) 
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024 ... 65535).contains(stored) ? UInt16(stored) : Self.defaultPort
    }

    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort >= 1024 else { return }
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        if running {
            restart()
        }
    }

    var lanAddress: String? {
        NetworkInfo.lanIPv4().map { "\($0):\(port)" }
    }

    var docsURL: String {
        let hostPort = lanAddress ?? "localhost:\(port)"
        return "http://\(hostPort)/docs"
    }

    func start() {
        guard serverTask == nil else { return }
        lastError = nil
        generation += 1

        resolveDefaultKey()
        let ids = identity()
        let info = APIServerInfo(
            name: Host.current().localizedName ?? "MxU Slides",
            product: "MxU Slides",
            apiVersion: OpenAPIDocument.apiVersion,
            schemaVersion: OpenAPIDocument.documentSchemaVersion(),
            stationHexId: ids.stationHexId,
            teamHexId: ids.teamHexId,
            stationName: ids.stationName
        )
        let server = LocalAPIServer(
            configuration: .init(
                port: port,
                serviceName: info.name,
                advertise: true,
                info: info,
                beat: { DiagnosticsStore.shared.mainBeat },
                hold: { route in FollowController.followedName.flatMap { FollowHold.error(for: route, following: $0) } },
                pair: { [followPairing, tokens, teamHexId] body in
                    followPairing.answer(body, teamHexId: teamHexId.withLock { $0 }, tokens: tokens)
                },
                blob: { [blobs = appModel.blobs] hash in blobs?.url(forHash: hash) },
                heard: { FollowController.presence.heard(tokenName: $0) },
                unpair: { [tokens] token in
                    guard FollowPresence.backupName(token.name) != nil else { return }
                    tokens.revoke(id: token.id)
                    Task { @MainActor in FollowController.shared.refreshBackups() }
                }
            ),
            routes: APIRouteTable.build(bridge: bridge) + Self.followRoutes(model: appModel),
            tokens: tokens
        )
        self.server = server
        running = true
        serverTask = Task { [weak self] in
            do {
                try await server.run()
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.server === server else { return }
                    self.lastError = "\(error)"
                    self.running = false
                    self.serverTask = nil
                    self.server = nil
                }
            }
        }
        armPublishers()
        pumpFires(to: server)
        observeIdentity()
    }

    func stop() {
        APIFireFeed.shared.sink = nil
        firesTask?.cancel()
        firesTask = nil
        serverTask?.cancel()
        serverTask = nil
        if let server {
            Task { await server.stop() }
        }
        server = nil
        running = false
        generation += 1
    }

    private func restart() {
        stop()
        start()
    }

    private func armPublishers() {
        observe(.show) { bridge in try? Self.encode(bridge.showStatus()) }
        observe(.timers) { bridge in try? Self.encode(bridge.timers()) }
        observe(.audio) { bridge in try? Self.encode(bridge.audioStatus()) }
        observe(.transport) { bridge in try? Self.encode(bridge.transportRows()) }
        observe(.outputs) { bridge in try? Self.encode(bridge.outputsStatus()) }
        observe(.library) { bridge in try? Self.encode(bridge.librarySummary()) }
        observe(.scheduler) { bridge in try? Self.encode(bridge.schedulerStatus()) }
        observe(.timecode) { bridge in try? Self.encode(bridge.timecodeStatus()) }
    }

    private func pumpFires(to server: LocalAPIServer) {
        let (stream, continuation) = AsyncStream<APIFireEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        APIFireFeed.shared.sink = { continuation.yield($0) }
        firesTask = Task.detached(priority: .userInitiated) {
            for await event in stream {
                if let payload = APIFireFeed.encode(event) {
                    await server.events.publish(APIEvent(topic: .fires, payload: payload))
                }
            }
        }
    }

    private func observeIdentity() {
        guard running, let server else { return }
        let armedGeneration = generation
        let ids = withObservationTracking { identity() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == armedGeneration else { return }
                self.observeIdentity()
            }
        }
        server.update(stationHexId: ids.stationHexId, teamHexId: ids.teamHexId, stationName: ids.stationName)
        teamHexId.withLock { $0 = ids.teamHexId }
        if pairingCode.isEmpty { pairingCode = followPairing.current ?? followPairing.refresh() }
    }

    private static func followRoutes(model: AppModel) -> [APIRoute] {
        let object: JSONValue = .object(["type": .string("object")])
        func act(_ path: String, _ id: String, _ summary: String, _ run: @escaping @Sendable @MainActor () async -> String?) -> APIRoute {
            APIRoute("POST", path, scope: .control, operationId: id, summary: summary, tag: "Follow", responseSchema: .ref("OK")) { _ in
                if let refused = await run() { throw APIError(status: 409, code: "follow", message: refused) }
                return .ok
            }
        }
        return [
            APIRoute("GET", "/v1/follow", scope: .view, operationId: "followStatus",
                     summary: "Follow mode: backing up, in charge or stepped down.", tag: "Follow", responseSchema: object) { _ in
                .json(await FollowController.shared.status)
            },
            act("/v1/follow/takeover", "followTakeOver", "A backup takes over.") { await FollowController.shared.takeOver(reason: "API") },
            act("/v1/follow/handback", "followHandBack", "A backup in charge hands back.") { await FollowController.shared.handBack() },
            act("/v1/follow/takeback", "followTakeBack", "A booth that stepped down takes back.") { FollowController.shared.takeBack() },

            APIRoute("GET", "/v1/follow/files", scope: .control, operationId: "followFiles",
                     summary: "This computer's library items, for its backup.", tag: "Follow", responseSchema: object) { _ in
                .json(try await FollowFileCopy.offered(model))
            },
            APIRoute("GET", "/v1/follow/files/{kind}/{id}", scope: .control, operationId: "followFile",
                     summary: "One library item's whole save.", tag: "Follow", responseSchema: object) { context in
                .json(try await FollowFileCopy.document(model, kind: context.pathParameters["kind"] ?? "", id: context.pathParameters["id"] ?? ""))
            },
            APIRoute("POST", "/v1/follow/role", scope: .control, operationId: "followRole",
                     summary: "A backup tells its booth who is in charge.", tag: "Follow", responseSchema: object) { context in
                let command = try context.decode(APIFollowRoleCommand.self)
                return .json(await FollowController.shared.receiveRole(command))
            },
        ]
    }

    func newPairingCode() {
        pairingCode = followPairing.refresh()
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func observe(
        _ topic: APITopic, snapshot: @escaping @MainActor (AppAPIBridge) -> Data?
    ) {
        guard running else { return }
        let armedGeneration = generation
        withObservationTracking { [bridge] in
            _ = snapshot(bridge)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == armedGeneration,
                      let server = self.server
                else { return }
                if let payload = snapshot(self.bridge) {
                    await server.events.publish(APIEvent(topic: topic, payload: payload))
                }
                self.observe(topic, snapshot: snapshot)
            }
        }
    }
}
