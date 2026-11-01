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

        var automatic: Bool?

        var role: FollowRole?

        var tookOverAt: Date?
    }

    struct SteppedDown: Codable, Equatable {
        var backupName: String
        var role: FollowRole
    }

    nonisolated static let held = OSAllocatedUnfairLock<String?>(initialState: nil)
    nonisolated static var followedName: String? { held.withLock { $0 } }
    nonisolated static var isBackingUp: Bool { followedName != nil }

    private static let pairingKey = "follow.pairing"
    private static let steppedDownKey = "follow.steppedDown"

    private static let boothRoleKey = "follow.boothRole"

    private(set) var pairing: Pairing?
    private(set) var steppedDown: SteppedDown?
    private(set) var state: Follow.State = .connecting
    private(set) var lastFire: Date?
    private(set) var problem: String?

    private var bridge: (any LocalAPIBridge)?
    private weak var station: StationSyncController?
    private var client: LocalAPIClient?
    private var endpoint: LocalAPIClient.Endpoint?
    private var task: Task<Void, Never>?

    private init() {
        pairing = Self.load(Pairing.self, Self.pairingKey)
        steppedDown = Self.load(SteppedDown.self, Self.steppedDownKey)
    }

    private var me: String? { station?.stationHexId }

    var backingUp: Bool { pairing != nil && !inCharge }

    var inCharge: Bool { pairing?.role.map { $0.inCharge != pairing?.stationHexId } ?? false }

    func configure(bridge: any LocalAPIBridge, station: StationSyncController) {
        self.bridge = bridge
        self.station = station
        if let steppedDown { Self.held.withLock { $0 = steppedDown.backupName } }
        if let pairing {
            if let key = FollowKeyKeychain.load(account: pairing.stationHexId) {
                start(pairing, key: key)
            } else {
                state = .gaveUp
                problem = "This computer lost its key for \(pairing.name). Stop Backing Up, then pair again."
            }
        }
    }

    func pair(with peer: BonjourBrowser.Peer, name: String, code: String, automatic: Bool, teamHexId: String, station: StationSyncController) async -> String? {
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
        let pairing = Pairing(
            stationHexId: peer.stationHexId, name: name, host: peer.host, port: peer.port,
            automatic: automatic, role: FollowRole(term: 0, inCharge: peer.stationHexId))
        FollowKeyKeychain.save(key, account: pairing.stationHexId)
        save(pairing)
        _ = try? await client.setFollow(hexId: stationHexId, followsStationHexId: pairing.stationHexId)
        DiagnosticsStore.shared.note("follow.paired", detail: "\(pairing.name) at \(pairing.host):\(pairing.port)")
        start(pairing, key: key)
        return nil
    }

    func unpair(station: StationSyncController) async {
        stopClient()
        if let pairing { FollowKeyKeychain.clear(account: pairing.stationHexId) }
        save(nil)
        Self.held.withLock { $0 = nil }
        if let stationHexId = station.stationHexId, let client = MxUAccountController.shared.client {
            _ = try? await client.setFollow(hexId: stationHexId, followsStationHexId: nil)
        }
        DiagnosticsStore.shared.note("follow.unpaired")
    }

    @discardableResult
    func takeOver(reason: String = "by hand") async -> String? {
        guard var pairing, let me, !inCharge else { return pairing == nil ? "This computer isn't backing up another." : nil }
        let role = (pairing.role ?? FollowRole(term: 0, inCharge: pairing.stationHexId)).handed(to: me)
        pairing.role = role
        pairing.tookOverAt = .now
        save(pairing)
        Self.held.withLock { $0 = nil }
        DiagnosticsStore.shared.note("follow.tookOver", detail: "\(reason), term \(role.term)")
        await tellBooth()
        return nil
    }

    @discardableResult
    func handBack() async -> String? {
        guard var pairing, let role = pairing.role, inCharge else { return "This computer isn't in charge." }
        let handed = role.handed(to: pairing.stationHexId)
        guard let answer = await post(role: handed, for: pairing), answer.term >= handed.term else {
            problem = "\(pairing.name) isn't answering, so it can't take back yet."
            return problem
        }
        pairing.role = handed
        pairing.tookOverAt = nil
        save(pairing)
        let name = pairing.name
        Self.held.withLock { $0 = name }
        problem = nil
        DiagnosticsStore.shared.note("follow.handedBack", detail: "term \(handed.term)")
        if let endpoint { await catchUp(endpoint) }
        return nil
    }

    private func tellBooth() async {
        guard let pairing, let role = pairing.role else { return }
        if let answer = await post(role: role, for: pairing), let newer = role.newer(FollowRole(term: answer.term, inCharge: answer.inCharge)) {
            adopt(newer)
        }
    }

    private func post(role: FollowRole, for pairing: Pairing) async -> APIFollowRoleCommand? {
        guard let endpoint else { return nil }
        let command = APIFollowRoleCommand(term: role.term, inCharge: role.inCharge, name: station?.stationName ?? "Backup")
        return await Self.postRole(command, endpoint: endpoint)
    }

    private func adopt(_ role: FollowRole) {
        guard var pairing else { return }
        pairing.role = role
        if role.inCharge == pairing.stationHexId { pairing.tookOverAt = nil }
        save(pairing)
        let heldBy: String? = role.inCharge == me ? nil : pairing.name
        Self.held.withLock { $0 = heldBy }
        DiagnosticsStore.shared.note("follow.role", detail: "term \(role.term), in charge \(role.inCharge == me ? "here" : pairing.name)")
    }

    func receiveRole(_ command: APIFollowRoleCommand) -> APIFollowRoleCommand {
        let mine = boothRole
        let incoming = FollowRole(term: command.term, inCharge: command.inCharge)
        guard let newer = mine.newer(incoming) else {
            return APIFollowRoleCommand(term: mine.term, inCharge: mine.inCharge, name: station?.stationName ?? "")
        }
        boothRole = newer
        if newer.inCharge == me {
            steppedDown = nil
            Self.held.withLock { $0 = nil }
        } else {
            steppedDown = SteppedDown(backupName: command.name, role: newer)
            Self.held.withLock { $0 = command.name }
        }
        Self.store(steppedDown, Self.steppedDownKey)
        DiagnosticsStore.shared.note("follow.role", detail: "term \(newer.term): \(newer.inCharge == me ? "this computer" : command.name) in charge")
        return command
    }

    @discardableResult
    func takeBack() -> String? {
        guard steppedDown != nil, let me else { return "This computer is in charge already." }
        let role = boothRole.handed(to: me)
        boothRole = role
        steppedDown = nil
        Self.store(steppedDown, Self.steppedDownKey)
        Self.held.withLock { $0 = nil }
        APIFireFeed.shared.publish(APIFireEvent(kind: .role, term: role.term, inCharge: me))
        DiagnosticsStore.shared.note("follow.tookBack", detail: "term \(role.term)")
        return nil
    }

    private var boothRole: FollowRole {
        get { Self.load(FollowRole.self, Self.boothRoleKey) ?? FollowRole(term: 0, inCharge: me ?? "") }
        set { Self.store(newValue, Self.boothRoleKey) }
    }

    var status: APIFollowStatus {
        if let steppedDown {
            return APIFollowStatus(role: "steppedDown", name: steppedDown.backupName, term: steppedDown.role.term)
        }
        guard let pairing else { return APIFollowStatus(role: "none", term: boothRole.term) }
        let health = switch state {
        case .connecting: "connecting"
        case .live: "live"
        case .lost(let frozen): frozen ? "frozen" : "lost"
        case .gaveUp: "gaveUp"
        }
        return APIFollowStatus(role: inCharge ? "inCharge" : "backingUp", name: pairing.name, health: health, term: pairing.role?.term)
    }

    private func start(_ pairing: Pairing, key: String) {
        stopClient()
        if !inCharge { Self.held.withLock { $0 = pairing.name } }
        state = .connecting
        problem = nil
        let endpoint = LocalAPIClient.Endpoint(host: pairing.host, port: pairing.port, token: key)
        self.endpoint = endpoint
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
        endpoint = nil
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
            if Follow.takesOverOnItsOwn(automatic: pairing?.automatic ?? true, backingUp: backingUp, wasLive: wasLive, now: state) {
                await takeOver(reason: "the booth stopped answering")
            } else if state == .live, !wasLive {
                if inCharge { await tellBooth() } else { await catchUp(endpoint) }
            }
        case .event(.fires, let data):
            guard let event = APIFireFeed.decode(data) else { return }
            if event.kind == .role, let term = event.term, let inChargeID = event.inCharge,
               let newer = pairing?.role?.newer(FollowRole(term: term, inCharge: inChargeID)) {
                adopt(newer)
                if backingUp { await catchUp(endpoint) }
            } else if backingUp, FollowReplay.replays(event) {
                await replay(event)
            }
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

    private func save(_ pairing: Pairing?) {
        self.pairing = pairing
        Self.store(pairing, Self.pairingKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store(_ value: (some Encodable)?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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

    private nonisolated static func postRole(_ command: APIFollowRoleCommand, endpoint: LocalAPIClient.Endpoint) async -> APIFollowRoleCommand? {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)/v1/follow/role")!, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(command)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(APIFollowRoleCommand.self, from: data)
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
        if let steppedDown = follow.steppedDown {
            let line = Follow.steppedDownBanner(backup: steppedDown.backupName)
            bar(color: .orange, title: line.title, detail: follow.problem ?? line.detail) {
                Button("Take Back") { follow.takeBack() }
            }
        } else if let pairing = follow.pairing {
            if follow.inCharge {
                let line = Follow.inChargeBanner(over: pairing.name, since: pairing.tookOverAt ?? .now)
                bar(color: .blue, title: line.title, detail: follow.problem ?? line.detail) {
                    Button("Hand Back to \(pairing.name)") { Task { await follow.handBack() } }
                }
            } else {
                let line = Follow.banner(following: pairing.name, state: follow.state, lastFire: follow.lastFire)
                bar(color: color, title: line.title, detail: follow.problem ?? line.detail) {
                    Button("Take Over") { Task { await follow.takeOver() } }
                    if let station {
                        Button("Stop Backing Up") { Task { await follow.unpair(station: station) } }
                    }
                }
            }
        }
    }

    private func bar(color: Color, title: String, detail: String, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            buttons()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.18))
    }

    private var color: Color {
        switch follow.state {
        case .live: .green
        case .connecting: .blue
        case .lost, .gaveUp: .red
        }
    }
}
