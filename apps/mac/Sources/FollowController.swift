import Foundation
import LocalAPI
import MxUAPI
import os
import PresenterCore
import SwiftUI

@MainActor
@Observable
final class FollowController {
    static let shared = FollowController()

    struct Pairing: Codable, Equatable {
        var stationHexId: String
        var name: String
        var host: String
        var port: UInt16
    }

    nonisolated static let held = OSAllocatedUnfairLock<String?>(initialState: nil)
    nonisolated static var followedName: String? { held.withLock { $0 } }
    nonisolated static var isBackingUp: Bool { followedName != nil }

    private static let pairingKey = "follow.pairing"

    private(set) var pairing: Pairing?
    private(set) var state: Follow.State = .connecting
    private(set) var lastFire: Date?
    private(set) var problem: String?

    private var bridge: (any LocalAPIBridge)?
    private var client: LocalAPIClient?
    private var task: Task<Void, Never>?

    private init() {
        pairing = UserDefaults.standard.data(forKey: Self.pairingKey).flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) }
    }

    func configure(bridge: any LocalAPIBridge) {
        self.bridge = bridge
        if let pairing {
            if let key = FollowKeyKeychain.load(account: pairing.stationHexId) {
                start(pairing, key: key)
            } else {
                state = .gaveUp
                problem = "This computer lost its key for \(pairing.name). Stop Backing Up, then pair again."
            }
        }
    }

    func pair(with peer: BonjourBrowser.Peer, name: String, code: String, teamHexId: String, station: StationSyncController) async -> String? {
        guard let stationHexId = station.stationHexId, let client = MxUAccountController.shared.client else {
            return "Sign in first."
        }
        let request = APIFollowPairRequest(code: code, teamHexId: teamHexId, stationHexId: stationHexId, name: station.stationName)
        let key: String
        do {
            key = try await Self.requestKey(request, host: peer.host, port: peer.port)
        } catch {
            return error.localizedDescription
        }
        let pairing = Pairing(stationHexId: peer.stationHexId, name: name, host: peer.host, port: peer.port)
        FollowKeyKeychain.save(key, account: pairing.stationHexId)
        UserDefaults.standard.set(try? JSONEncoder().encode(pairing), forKey: Self.pairingKey)
        self.pairing = pairing
        _ = try? await client.setFollow(hexId: stationHexId, followsStationHexId: pairing.stationHexId)
        DiagnosticsStore.shared.note("follow.paired", detail: "\(pairing.name) at \(pairing.host):\(pairing.port)")
        start(pairing, key: key)
        return nil
    }

    func unpair(station: StationSyncController) async {
        stopClient()
        if let pairing { FollowKeyKeychain.clear(account: pairing.stationHexId) }
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
        pairing = nil
        if let stationHexId = station.stationHexId, let client = MxUAccountController.shared.client {
            _ = try? await client.setFollow(hexId: stationHexId, followsStationHexId: nil)
        }
        DiagnosticsStore.shared.note("follow.unpaired")
    }

    private nonisolated static func requestKey(_ request: APIFollowPairRequest, host: String, port: UInt16) async throws -> String {
        var http = URLRequest(url: URL(string: "http://\(host):\(port)/v1/follow/pair")!, timeoutInterval: 10)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await URLSession.shared.data(for: http)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            return try JSONDecoder().decode(APIFollowPairResponse.self, from: data).token
        }
        let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message ?? "That computer didn't answer."
        throw APIError(status: 403, code: "pair_refused", message: message)
    }

    private func start(_ pairing: Pairing, key: String) {
        stopClient()
        Self.held.withLock { $0 = pairing.name }
        state = .connecting
        problem = nil
        let endpoint = LocalAPIClient.Endpoint(host: pairing.host, port: pairing.port, token: key)
        let client = LocalAPIClient(endpoint: endpoint, topics: [.fires])
        self.client = client
        task = Task { [weak self] in
            await client.start()
            for await update in client.updates {
                guard let self else { return }
                await self.handle(update, endpoint: endpoint)
            }
        }
    }

    private func stopClient() {
        task?.cancel()
        task = nil
        if let client { Task { await client.stop() } }
        client = nil
        Self.held.withLock { $0 = nil }
    }

    private func handle(_ update: LocalAPIClient.Update, endpoint: LocalAPIClient.Endpoint) async {
        switch update {
        case .health(let health):
            let wasLive = state == .live
            state = switch health {

            case .connecting: if case .lost = state { state } else { .connecting }
            case .live: .live
            case .lost(.frozen): .lost(frozen: true)
            case .lost: .lost(frozen: false)
            case .gaveUp: .gaveUp
            }
            DiagnosticsStore.shared.note("follow.health", detail: "\(health)")
            if state == .live, !wasLive { await catchUp(endpoint) }
        case .event(.fires, let data):
            guard let event = APIFireFeed.decode(data), FollowReplay.replays(event) else { return }
            await replay(event)
        case .event:
            break
        }
    }

    private func replay(_ event: APIFireEvent) async {
        guard let bridge, let name = pairing?.name else { return }
        lastFire = .now
        do {
            try await APIFireSource.$current.withValue(APIFireSource(kind: .follow, name: name)) {
                try await FollowReplay.apply(event, to: bridge)
            }
            problem = nil
        } catch {
            problem = "Couldn't run \(event.kind.rawValue): \(error.localizedDescription)"
            DiagnosticsStore.shared.note("follow.replayFailed", detail: "\(event.kind.rawValue) seq \(event.seq): \(error)")
        }
    }

    private func catchUp(_ endpoint: LocalAPIClient.Endpoint) async {
        guard let bridge, let live = await Self.liveSlide(endpoint) else { return }
        let command = FollowReplay.command(for: APIFireSlideCommand(
            presentationId: live.presentationId, slideId: live.slideId,
            serviceItemId: live.serviceItemId, occurrence: live.occurrence))
        try? await APIFireSource.$current.withValue(APIFireSource(kind: .follow, name: pairing?.name)) {
            try await bridge.fireSlide(command)
        }
        DiagnosticsStore.shared.note("follow.caughtUp", detail: live.slideId)
    }

    private nonisolated static func liveSlide(_ endpoint: LocalAPIClient.Endpoint) async -> APIShowStatus.LiveSlide? {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)/v1/status")!, timeoutInterval: 5)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(APIShowStatus.self, from: data).liveSlide
        } catch {
            DiagnosticsStore.shared.note("follow.catchUpFailed", detail: "\(error)")
            return nil
        }
    }
}

enum FollowKeyKeychain {
    private static let service = "com.example.mxuslides.follow"
    private static let memory = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    #if DEBUG || MXU_PERF_HOOKS
    private static let skips = KeychainTokenStore.skips(isDebug: true, envValue: ProcessInfo.processInfo.environment[KeychainTokenStore.environmentKey])
    #else
    private static let skips = false
    #endif

    static func load(account: String) -> String? {
        if skips { return memory.withLock { $0[account] } }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String, account: String) {
        if skips { return memory.withLock { $0[account] = secret } }
        clear(account: account)
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear(account: String) {
        if skips { return memory.withLock { $0[account] = nil } }
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

struct FollowBanner: View {
    let follow: FollowController
    let station: StationSyncController?

    var body: some View {
        if let pairing = follow.pairing {
            let line = Follow.banner(following: pairing.name, state: follow.state, lastFire: follow.lastFire)
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title).font(.callout.weight(.semibold))
                    Text(follow.problem ?? line.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let station {
                    Button("Stop Backing Up") { Task { await follow.unpair(station: station) } }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.18))
        }
    }

    private var color: Color {
        switch follow.state {
        case .live: .green
        case .connecting: .blue
        case .lost, .gaveUp: .red
        }
    }
}
