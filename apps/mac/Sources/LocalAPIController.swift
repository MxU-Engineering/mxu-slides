import Foundation
import LocalAPI
import Observation
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
    private static let service = (Bundle.main.bundleIdentifier ?? "com.example.mxuslides") + ".localapi"
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
        let info = APIServerInfo(
            name: Host.current().localizedName ?? "MxU Slides",
            product: "MxU Slides",
            apiVersion: OpenAPIDocument.apiVersion,
            schemaVersion: OpenAPIDocument.documentSchemaVersion()
        )
        let server = LocalAPIServer(
            configuration: .init(
                port: port,
                serviceName: info.name,
                advertise: true,
                info: info
            ),
            routes: APIRouteTable.build(bridge: bridge),
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
    }

    func stop() {
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
