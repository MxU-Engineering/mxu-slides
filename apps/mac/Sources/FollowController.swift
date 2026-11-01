import Foundation
import LocalAPI
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

        var tookOverOnItsOwn: Bool?

        var tookOverFrozen: Bool?

        var mirrors: Bool?
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

    private(set) var boothStream: String?

    private(set) var copiedItems = 0
    private(set) var copyProblem: String?

    private(set) var boothQuit = false

    private var watch: BonjourBrowser?
    private var watchTask: Task<Void, Never>?
    private var rewatches = 0
    private static let maxRewatches = 10

    private var boothLaunch: String?

    private(set) var cameBack: String?

    private(set) var standby: FollowStandby?
    private var standbyRead = 0

    private var standbyTask: Task<Void, Never>?

    nonisolated static let launch = UUID().uuidString
    nonisolated static let presence = FollowPresence { names in
        Task { @MainActor in FollowController.shared.backupsHeard(names) }
    }
    private(set) var backups: [String] = []
    private(set) var connectedBackups: Set<String> = []
    private(set) var droppedBackup: String?

    var pairedBackupNames: () -> [String] = { [] }
    var forgetBackupKeys: (String) -> Void = { _ in }
    var inServiceWindow: () -> Bool = { false }
    private var copyTask: Task<Void, Never>?
    private var copyRun = UUID()

    private var bridge: (any LocalAPIBridge)?
    private weak var controls: ServiceControls?
    private var client: LocalAPIClient?
    private var endpoint: LocalAPIClient.Endpoint?
    private var task: Task<Void, Never>?

    private init() {
        pairing = Self.load(Pairing.self, Self.pairingKey)
        steppedDown = Self.load(SteppedDown.self, Self.steppedDownKey)
    }

    var me: String? { controls?.appModel.machineID }

    private var myName: String { controls?.appModel.computerName() ?? "This Mac" }

    var backingUp: Bool { pairing != nil && !inCharge }

    var standingBy: Bool { backingUp && pairing?.mirrors == false }

    var inCharge: Bool { pairing?.role.map { $0.inCharge != pairing?.stationHexId } ?? false }

    func configure(bridge: any LocalAPIBridge, controls: ServiceControls?) {
        self.bridge = bridge
        self.controls = controls
        if let steppedDown { Self.held.withLock { $0 = steppedDown.backupName } }
        refreshBackups()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FollowController.shared.quitting() }
        }
        if let pairing {
            if let key = FollowKeyKeychain.load(account: pairing.stationHexId) {
                start(pairing, key: key)
            } else {
                state = .gaveUp
                problem = "This computer lost its key for \(pairing.name). Stop Backing Up, then pair again."
            }
        }
    }

    private func quitting() {
        guard pairing == nil, APIFireFeed.shared.sink != nil else { return }
        APIFireFeed.shared.publish(APIFireEvent(kind: .quit))
        Thread.sleep(forTimeInterval: 0.25)
    }

    func pair(with peer: BonjourBrowser.Peer, name: String, code: String, automatic: Bool, mirrors: Bool) async -> String? {
        guard let stationHexId = me else { return "This computer isn't ready yet." }
        let request = APIFollowPairRequest(code: code, stationHexId: stationHexId, name: myName)
        let key: String
        do {
            key = try await Self.requestKey(request, host: peer.host, port: peer.port)
        } catch {
            return error.localizedDescription
        }
        let pairing = Pairing(
            stationHexId: peer.stationHexId, name: name, host: peer.host, port: peer.port,
            automatic: automatic, role: .start(booth: peer.stationHexId), mirrors: mirrors)
        FollowKeyKeychain.save(key, account: pairing.stationHexId)
        save(pairing)
        DiagnosticsStore.shared.note("follow.paired", detail: "\(pairing.name) at \(pairing.host):\(pairing.port)")
        start(pairing, key: key)
        return nil
    }

    func unpair() async {
        if let endpoint { await Self.postUnpair(endpoint) }
        stopClient()
        if let pairing { FollowKeyKeychain.clear(account: pairing.stationHexId) }
        save(nil)
        Self.held.withLock { $0 = nil }
        DiagnosticsStore.shared.note("follow.unpaired")
    }

    @discardableResult
    func takeOver(reason: String = "by hand", frozen: Bool = false) async -> String? {
        guard var pairing, let me, !inCharge else { return pairing == nil ? "This computer isn't backing up another." : nil }
        let role = (pairing.role ?? .start(booth: pairing.stationHexId)).handed(to: me)
        pairing.role = role
        pairing.tookOverAt = .now
        pairing.tookOverOnItsOwn = reason != "by hand"
        pairing.tookOverFrozen = frozen
        save(pairing)
        Self.held.withLock { $0 = nil }
        DiagnosticsStore.shared.note("follow.tookOver", detail: "\(reason), term \(role.term)")

        if !(pairing.tookOverOnItsOwn == true && !frozen) { await tellBooth() }
        if pairing.mirrors == false { await putUpBoothPicture() }
        return nil
    }

    func setMirrors(_ mirrors: Bool) async {
        guard var pairing, (pairing.mirrors ?? true) != mirrors else { return }
        pairing.mirrors = mirrors
        save(pairing)
        DiagnosticsStore.shared.note("follow.mode", detail: mirrors ? "live" : "standby")
        if backingUp, let endpoint { await catchUp(endpoint) }
    }

    private func putUpBoothPicture() async {
        guard let bridge, let standby else { return }
        let events = standby.takeover(here: bridge.showStatus(), now: .now)
        await APIFireSource.$current.withValue(APIFireSource(kind: .follow, name: pairing?.name)) {
            for event in events {

                for attempt in 0..<10 {
                    do {
                        try await FollowReplay.apply(event, to: bridge)
                        break
                    } catch {
                        guard [.mediaTransport, .audioTransport].contains(event.kind), attempt < 9 else { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
        DiagnosticsStore.shared.note("follow.putUp", detail: "\(standby.show.liveSlide?.slideId ?? "no slide"), \(standby.transport.count) videos, read \(Int(Date.now.timeIntervalSince(standby.at)))s before")
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

    var offersStream: Bool { inCharge && boothStream != nil && controls?.streaming.isLive == false }

    func startStreamHere() {
        guard offersStream, let boothStream else { return }
        controls?.startCapture(presetID: boothStream)
        DiagnosticsStore.shared.note("follow.streamHere", detail: boothStream)
    }

    private func boothReturned(_ endpoint: LocalAPIClient.Endpoint) async {
        let status = await Self.followStatus(endpoint)
        if let pairing, let since = pairing.tookOverAt, Follow.handsBackOnReturn(
            onItsOwn: pairing.tookOverOnItsOwn ?? false, frozen: pairing.tookOverFrozen ?? false,
            since: since, now: .now, launchThen: boothLaunch, launchNow: status?.launch) {
            let line = Follow.cameBackLine(pairing.name, after: Date.now.timeIntervalSince(since))
            if await handBack() == nil {
                cameBack = line
                DiagnosticsStore.shared.note("follow.gaveWay", detail: line)
                return
            }
        }
        await tellBooth()
    }

    private func tellBooth() async {
        guard let pairing, let role = pairing.role else { return }
        if let answer = await post(role: role, for: pairing), let newer = role.newer(FollowRole(term: answer.term, inCharge: answer.inCharge)) {
            adopt(newer)
        }
    }

    private func post(role: FollowRole, for pairing: Pairing) async -> APIFollowRoleCommand? {
        guard let endpoint else { return nil }
        let command = APIFollowRoleCommand(term: role.term, inCharge: role.inCharge, name: myName)
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
            return APIFollowRoleCommand(term: mine.term, inCharge: mine.inCharge, name: myName)
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
            return APIFollowStatus(role: "steppedDown", name: steppedDown.backupName, term: steppedDown.role.term, launch: Self.launch)
        }
        let stream = controls?.streaming.live?.presetID
        guard let pairing else { return APIFollowStatus(role: "none", term: boothRole.term, streamPresetId: stream, launch: Self.launch) }
        let health = switch state {
        case .connecting: "connecting"
        case .live: "live"
        case .lost(let frozen): frozen ? "frozen" : "lost"
        case .gaveUp: "gaveUp"
        }
        return APIFollowStatus(role: inCharge ? "inCharge" : "backingUp", name: pairing.name, health: health, term: pairing.role?.term, streamPresetId: stream, launch: Self.launch)
    }

    private func start(_ pairing: Pairing, key: String) {
        stopClient()
        if !inCharge { Self.held.withLock { $0 = pairing.name } }
        state = .connecting
        problem = nil
        var endpoint = LocalAPIClient.Endpoint(host: pairing.host, port: pairing.port, token: key)
        #if DEBUG

        if let via = ProcessInfo.processInfo.environment["MXU_QA_FOLLOW_VIA"]?.split(separator: ":"), via.count == 2, let port = UInt16(via[1]) {
            endpoint.host = String(via[0])
            endpoint.port = port
        }
        #endif
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
        stopWatching()
        task?.cancel()
        task = nil
        copyTask?.cancel()
        copyTask = nil
        standbyTask?.cancel()
        standbyTask = nil
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
            if state == .live {
                boothQuit = false
                rewatches = 0
            } else if state == .gaveUp {
                watchForBooth()
            }
            if Follow.takesOverOnItsOwn(automatic: pairing?.automatic ?? true, backingUp: backingUp, wasLive: wasLive, boothQuit: boothQuit, now: state) {
                await takeOver(reason: "the booth stopped answering", frozen: state == .lost(frozen: true))
            } else if state == .live, !wasLive {
                if inCharge { await boothReturned(endpoint) } else { await catchUp(endpoint) }
                copyFiles(from: endpoint)
            }
        case .event(.fires, let data):
            guard let event = APIFireFeed.decode(data) else { return }
            if event.kind == .role, let term = event.term, let inChargeID = event.inCharge, let pairing,
               let newer = (pairing.role ?? .start(booth: pairing.stationHexId)).newer(FollowRole(term: term, inCharge: inChargeID)) {
                adopt(newer)
                if backingUp { await catchUp(endpoint) }
            } else if event.kind == .capture {
                if backingUp { boothStream = event.id }
            } else if event.kind == .quit {
                boothQuit = true
                DiagnosticsStore.shared.note("follow.boothQuit", detail: pairing?.name ?? "")
            } else if backingUp, FollowReplay.replays(event) {
                if standingBy {
                    lastFire = .now
                    await readStandby(endpoint)
                } else {
                    await replay(event)
                }
            }
        case .event:
            break
        }
    }

    private func copyFiles(from endpoint: LocalAPIClient.Endpoint) {
        guard copyTask == nil, let model = controls?.appModel else { return }
        let run = UUID()
        copyRun = run
        copyTask = Task { [weak self] in
            while let self, self.endpoint == endpoint, self.state == .live, !Task.isCancelled {
                do {
                    self.copiedItems += try await FollowFileCopy.copy(from: endpoint, model: model)
                    self.copyProblem = nil
                } catch {
                    self.copyProblem = "Couldn't copy \(self.pairing?.name ?? "the other computer")'s items: \(error.localizedDescription)"
                    DiagnosticsStore.shared.note("follow.copyFailed", detail: "\(error)")
                }
                try? await Task.sleep(for: .seconds(300))
            }
            if self?.copyRun == run { self?.copyTask = nil }
        }
    }

    private func replay(_ event: APIFireEvent) async {
        guard let bridge, let name = pairing?.name else { return }
        lastFire = .now
        cameBack = nil
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

    private func readStandby(_ endpoint: LocalAPIClient.Endpoint) async {
        standbyRead += 1
        let read = standbyRead
        guard let show = await Self.showStatus(endpoint) else { return }
        async let transport: [APITransportRow]? = Self.get("/v1/transport", endpoint)
        async let audio: APIAudioStatus? = Self.get("/v1/audio", endpoint)
        let (rows, sound) = await (transport, audio)
        guard read == standbyRead else { return }
        standby = FollowStandby(show: show, transport: rows ?? [], audio: sound, at: .now)
    }

    private func catchUp(_ endpoint: LocalAPIClient.Endpoint) async {
        if let status = await Self.followStatus(endpoint) {
            boothStream = status.streamPresetId
            boothLaunch = status.launch

            if status.role == "none", let term = status.term, let pairing,
               let newer = (pairing.role ?? .start(booth: pairing.stationHexId)).newer(FollowRole(term: term, inCharge: pairing.stationHexId)) {
                adopt(newer)
            }
        }
        if standingBy {
            await readStandby(endpoint)
            if standbyTask == nil {
                standbyTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard let self, !Task.isCancelled, self.standingBy, self.endpoint == endpoint, self.state == .live else { break }
                        await self.readStandby(endpoint)
                    }
                    self?.standbyTask = nil
                }
            }
            if let bridge, FollowStandby.showsAnything(bridge.showStatus(), audio: bridge.audioStatus()) {
                await APIFireSource.$current.withValue(APIFireSource(kind: .follow, name: pairing?.name)) {
                    for event in [APIFireEvent(kind: .clearAll), APIFireEvent(kind: .stopAudio)] { try? await FollowReplay.apply(event, to: bridge) }
                }
            }
            DiagnosticsStore.shared.note("follow.standingBy", detail: standby?.show.liveSlide?.slideId ?? "no slide")
            return
        }
        guard let bridge, let show = await Self.showStatus(endpoint) else { return }
        let differences = FollowReplay.catchUp(booth: show, here: bridge.showStatus())
        await APIFireSource.$current.withValue(APIFireSource(kind: .follow, name: pairing?.name)) {
            for event in differences { try? await FollowReplay.apply(event, to: bridge) }
            if let live = show.liveSlide {
                try? await bridge.fireSlide(FollowReplay.command(for: APIFireSlideCommand(
                    presentationId: live.presentationId, slideId: live.slideId,
                    serviceItemId: live.serviceItemId, occurrence: live.occurrence)))
            }
        }
        DiagnosticsStore.shared.note("follow.caughtUp", detail: "\(show.liveSlide?.slideId ?? "no slide"), \(differences.count) layers")
    }

    func useKeys(of api: LocalAPIController) {
        pairedBackupNames = { [tokens = api.tokens] in
            Set(tokens.all.compactMap { FollowPresence.backupName($0.name) }).sorted()
        }
        forgetBackupKeys = { [weak api] name in
            for token in api?.tokens.all ?? [] where FollowPresence.backupName(token.name) == name { api?.revokeKey(id: token.id) }
        }
    }

    func refreshBackups() {
        let names = pairedBackupNames()
        if names != backups { backups = names }
    }

    private func backupsHeard(_ names: Set<String>) {
        refreshBackups()

        if let gone = connectedBackups.subtracting(names).first, backups.contains(gone), inServiceWindow() {
            droppedBackup = gone
            DiagnosticsStore.shared.note("follow.backupDropped", detail: gone)
        }
        if let droppedBackup, names.contains(droppedBackup) { self.droppedBackup = nil }
        if names != connectedBackups { connectedBackups = names }
    }

    func hideDroppedBackup() {
        droppedBackup = nil
    }

    func forget(backup name: String) {
        forgetBackupKeys(name)
        connectedBackups.remove(name)
        if droppedBackup == name { droppedBackup = nil }
        refreshBackups()
        DiagnosticsStore.shared.note("follow.forgotBackup", detail: name)
    }

    func tryAgain() {
        rewatches = 0
        reconnect(to: nil)
    }

    private func watchForBooth() {
        guard watch == nil, rewatches < Self.maxRewatches, let pairing else { return }
        let browser = BonjourBrowser(ownStationHexId: me)
        watch = browser
        let booth = pairing.stationHexId
        watchTask = Task { [weak self] in
            for await peers in browser.start() {
                guard let peer = peers.first(where: { $0.stationHexId == booth }) else { continue }
                self?.rewatches += 1
                DiagnosticsStore.shared.note("follow.boothSeen", detail: "\(peer.host):\(peer.port)")
                self?.reconnect(to: peer)
                return
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        watch?.stop()
        watch = nil
    }

    private func reconnect(to peer: BonjourBrowser.Peer?) {
        guard var pairing, let key = FollowKeyKeychain.load(account: pairing.stationHexId) else { return }
        if let peer, peer.host != pairing.host || peer.port != pairing.port {
            pairing.host = peer.host
            pairing.port = peer.port
            save(pairing)
        }
        start(pairing, key: key)
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

    private nonisolated static func postUnpair(_ endpoint: LocalAPIClient.Endpoint) async {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)/v1/follow/unpair")!, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    private nonisolated static func followStatus(_ endpoint: LocalAPIClient.Endpoint) async -> APIFollowStatus? {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)/v1/follow")!, timeoutInterval: 5)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(APIFollowStatus.self, from: data)
    }

    private nonisolated static func get<T: Decodable>(_ path: String, _ endpoint: LocalAPIClient.Endpoint) async -> T? {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)\(path)")!, timeoutInterval: 5)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func showStatus(_ endpoint: LocalAPIClient.Endpoint) async -> APIShowStatus? {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)/v1/status")!, timeoutInterval: 5)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(APIShowStatus.self, from: data)
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
    private static let skips = ProcessInfo.processInfo.environment["MXU_SKIP_KEYCHAIN"] == "1"
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

    var body: some View {
        if let steppedDown = follow.steppedDown {
            let line = Follow.steppedDownBanner(backup: steppedDown.backupName)
            bar(color: .orange, title: line.title, detail: follow.problem ?? line.detail) {
                Button("Take Back") { follow.takeBack() }
            }
        } else if follow.pairing == nil, let dropped = follow.droppedBackup {
            let line = Follow.backupDroppedBanner(dropped)
            bar(color: .orange, title: line.title, detail: line.detail) {
                Button("Hide") { follow.hideDroppedBackup() }
            }
        } else if let pairing = follow.pairing {
            if follow.inCharge {
                let line = Follow.inChargeBanner(over: pairing.name, since: pairing.tookOverAt ?? .now, onItsOwn: pairing.tookOverOnItsOwn ?? false, boothStreamed: follow.offersStream)
                bar(color: .blue, title: line.title, detail: follow.problem ?? line.detail) {
                    if follow.offersStream {
                        Button("Start Stream Here") { follow.startStreamHere() }
                    }
                    Button("Hand Back to \(pairing.name)") { Task { await follow.handBack() } }
                }
            } else {
                let line = Follow.banner(following: pairing.name, state: follow.state, lastFire: follow.lastFire, boothQuit: follow.boothQuit, standby: follow.standingBy)
                bar(color: color, title: line.title, detail: follow.problem ?? follow.copyProblem ?? follow.cameBack ?? line.detail) {
                    if follow.state == .gaveUp {
                        Button("Try Again") { follow.tryAgain() }
                    }
                    Button("Take Over") { Task { await follow.takeOver() } }
                    Button("Stop Backing Up") { Task { await follow.unpair() } }
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
        if follow.boothQuit, follow.state != .live { return .gray }
        return switch follow.state {
        case .live: .green
        case .connecting: .blue
        case .lost, .gaveUp: .red
        }
    }
}

struct BackupStatusChip: View {
    let follow: FollowController
    @State private var open = false
    @State private var forgetting: String?

    var body: some View {
        let connected = !follow.connectedBackups.isEmpty
        Button {
            open = true
        } label: {
            Image(systemName: "display.2")
                .font(.system(size: 13))
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(connected ? "Backed up by \(follow.connectedBackups.sorted().joined(separator: ", "))" : "Backup not connected")
        .accessibilityLabel("Backup")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(follow.backups, id: \.self) { name in
                    let on = follow.connectedBackups.contains(name)
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(on ? Color.green : Color.secondary).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.callout.weight(.semibold))
                            Text(Follow.boothBackupLine(name, connected: on, inCharge: follow.steppedDown?.backupName == name))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Forget \(name)\u{2026}") { forgetting = name }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
            .confirmationDialog("Forget \(forgetting ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
                Button("Forget", role: .destructive) {
                    if let forgetting { follow.forget(backup: forgetting) }
                    open = follow.backups.isEmpty ? false : open
                }
            } message: {
                Text("It stops following this computer until it pairs again with this computer's code.")
            }
        }
    }
}
