import Foundation
import Observation
import OutputEngine

enum DeckLinkAlphaKey: Int32, Codable, CaseIterable {
    case off = 0
    case internalKey = 1
    case externalKey = 2

    var label: String {
        switch self {
        case .off: "Off"
        case .internalKey: "Internal"
        case .externalKey: "External"
        }
    }
}

@MainActor
@Observable
final class DeckLinkScreenOutputs {
    static let shared = DeckLinkScreenOutputs()

    struct Backing: Codable, Equatable {
        var devicePersistentID: Int64
        var deviceName: String
        var keying: DeckLinkAlphaKey

        var mode: DeckLinkHelperDisplayMode?
    }

    private(set) var controllers: [Int64: DeckLinkOutputController] = [:]
    private(set) var backings: [UUID: Backing] = [:]
    private static let defaultsKey = "decklink.screenBackings"

    private init() {}

    private func controller(for screenID: UUID) -> DeckLinkOutputController? {
        backings[screenID].flatMap { controllers[$0.devicePersistentID] }
    }

    func members(onDevice devicePersistentID: Int64) -> [UUID] {
        backings.filter { $0.value.devicePersistentID == devicePersistentID }
            .keys.sorted { $0.uuidString < $1.uuidString }
    }

    func status(for screenID: UUID) -> DeckLinkOutputController.Status? {
        controller(for: screenID)?.status
    }

    func isCarrying(_ screenID: UUID) -> Bool {
        backings[screenID] != nil && (controller(for: screenID)?.isActive ?? false)
    }

    func wireDetail(for screenID: UUID) -> String {
        controller(for: screenID)?.wireDetail ?? ""
    }

    func backing(for screenID: UUID) -> Backing? {
        backings[screenID]
    }

    func enable(
        screenID: UUID, device: DeckLinkHelperDevice, keying: DeckLinkAlphaKey,
        mode: DeckLinkHelperDisplayMode? = nil, joining: Bool = false,
        render: RenderContext
    ) {
        guard render.outputs.sliceInfo(for: screenID) != nil else { return }
        if backings[screenID] != nil {
            backings.removeValue(forKey: screenID)
        }

        NDIScreenOutputs.shared.disable(screenID: screenID)
        if !joining {

            for otherID in members(onDevice: device.persistentID) where otherID != screenID {
                backings.removeValue(forKey: otherID)
            }
        }
        render.outputs.assignPlaceholderDevice(placeholderID: screenID, displayUUID: nil)
        let incumbent = members(onDevice: device.persistentID)
            .compactMap { backings[$0] }.first
        backings[screenID] = Backing(
            devicePersistentID: device.persistentID,
            deviceName: device.name,
            keying: joining ? incumbent?.keying ?? keying : keying,
            mode: joining ? incumbent?.mode ?? mode : mode)
        rebuildCarry(devicePersistentID: device.persistentID, render: render)
        persist()
    }

    private func rebuildCarry(devicePersistentID: Int64, render: RenderContext) {
        let memberIDs = members(onDevice: devicePersistentID)
        guard let firstID = memberIDs.first, let backing = backings[firstID] else {
            controllers[devicePersistentID]?.stop()
            controllers.removeValue(forKey: devicePersistentID)
            return
        }
        let mode = backing.mode
        let controller = controllers[devicePersistentID]
            ?? DeckLinkOutputController(render: render)
        controllers[devicePersistentID] = controller
        let infos = memberIDs.compactMap { id -> (id: UUID, screenID: UUID, sourceRect: CGRect, width: Int, height: Int, name: String?)? in
            render.outputs.sliceInfo(for: id).map { (id, $0.screenID, $0.sourceRect, $0.width, $0.height, $0.name) }
        }
        guard let first = infos.first else { return }
        let firstScreen = render.outputs.placeholderScreens
            .first { $0.id == first.screenID }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        if infos.count == 1 {
            controller.start(
                targetID: first.id.uuidString,
                targetName: first.name.map { "\(firstScreen?.name ?? "Screen") — \($0)" }
                    ?? firstScreen?.name ?? "Screen",
                devicePersistentID: devicePersistentID,
                deviceName: backing.deviceName,
                keying: backing.keying,
                width: mode?.width
                    ?? render.outputs.placement(forSlice: first.id)?.frameWidth ?? first.width,
                height: mode?.height
                    ?? render.outputs.placement(forSlice: first.id)?.frameHeight ?? first.height,
                frameRate: mode?.mirrorFramesPerSecond ?? firstScreen?.framesPerSecond ?? 30,
                modeID: mode?.modeID ?? 0,
                sourceRect: first.sourceRect == full ? nil : first.sourceRect,
                placement: render.outputs.placement(forSlice: first.id)?.unitRect
            )
            return
        }
        let layers = infos.map { info in
            OutputMirror.CompositeLayer(
                provider: render.outputs.previewProvider(for: info.screenID.uuidString),
                sourceRect: info.sourceRect == full ? nil : info.sourceRect,
                placement: render.outputs.placement(forSlice: info.id)?.unitRect,
                adjustments: render.outputs.adjustmentsProvider(for: info.id.uuidString),
                mask: render.outputs.maskProvider(for: info.id.uuidString)
            )
        }
        let frame = render.outputs.placement(forSlice: first.id)
        controller.start(
            targetID: first.id.uuidString,
            targetName: "\(backing.deviceName) — packed frame (\(infos.count))",
            devicePersistentID: devicePersistentID,
            deviceName: backing.deviceName,
            keying: backing.keying,
            width: mode?.width ?? frame?.frameWidth ?? 1920,
            height: mode?.height ?? frame?.frameHeight ?? 1080,
            frameRate: mode?.mirrorFramesPerSecond ?? firstScreen?.framesPerSecond ?? 30,
            modeID: mode?.modeID ?? 0,
            composite: layers
        )
    }

    func setKeying(screenID: UUID, keying: DeckLinkAlphaKey, render: RenderContext) {
        guard let backing = backings[screenID] else { return }
        for member in members(onDevice: backing.devicePersistentID) {
            backings[member]?.keying = keying
        }
        rebuildCarry(devicePersistentID: backing.devicePersistentID, render: render)
        persist()
    }

    func setMode(
        screenID: UUID, mode: DeckLinkHelperDisplayMode?, render: RenderContext
    ) {
        guard let backing = backings[screenID] else { return }
        for member in members(onDevice: backing.devicePersistentID) {
            backings[member]?.mode = mode
        }
        rebuildCarry(devicePersistentID: backing.devicePersistentID, render: render)
        persist()
    }

    func refreshCarry(for screenID: UUID, render: RenderContext) {
        guard let backing = backings[screenID] else { return }
        rebuildCarry(devicePersistentID: backing.devicePersistentID, render: render)
    }

    private func device(for backing: Backing) -> DeckLinkHelperDevice {
        DeckLinkHelperDevice(
            name: backing.deviceName,
            persistentID: backing.devicePersistentID,
            supportsPlayback: true,
            supportsInternalKeying: true,
            supportsExternalKeying: true)
    }

    func disable(screenID: UUID, render: RenderContext? = nil) {
        guard let backing = backings.removeValue(forKey: screenID) else {
            persist()
            return
        }
        if let render {

            rebuildCarry(devicePersistentID: backing.devicePersistentID, render: render)
        } else if members(onDevice: backing.devicePersistentID).isEmpty {
            controllers[backing.devicePersistentID]?.stop()
            controllers.removeValue(forKey: backing.devicePersistentID)
        }
        persist()
    }

    func restore(render: RenderContext) {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode([String: Backing].self, from: data)
        else { return }
        for (raw, backing) in stored {
            guard let id = UUID(uuidString: raw) else { continue }

            enable(
                screenID: id, device: device(for: backing),
                keying: backing.keying, mode: backing.mode, joining: true,
                render: render)
        }
    }

    private func persist() {
        let stored = Dictionary(
            uniqueKeysWithValues: backings.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(
            try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class DeckLinkDeviceCatalog {
    static let shared = DeckLinkDeviceCatalog()

    private(set) var devices: [DeckLinkHelperDevice] = []
    private(set) var hasFetched = false

    private(set) var runtimeVersionLabel = ""
    private(set) var runtimeTooOld = false
    private var modesFetchInFlight: Set<Int64> = []

    private(set) var displayModes: [Int64: [DeckLinkHelperDisplayMode]] = [:]

    private init() {}

    func refresh() {
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            connection.invalidate()
        }) as? DeckLinkHelperProtocol else {
            connection.invalidate()
            return
        }

        nonisolated(unsafe) let replyConnection = connection
        proxy.runtimeVersion { @Sendable version, tooOld in
            Task { @MainActor [weak self] in
                self?.runtimeVersionLabel = version
                self?.runtimeTooOld = tooOld
            }
        }
        proxy.listDevices { @Sendable data in
            let devices = (try? JSONDecoder().decode(
                [DeckLinkHelperDevice].self, from: data)) ?? []
            Task { @MainActor [weak self] in
                self?.devices = devices.filter(\.supportsPlayback)
                self?.hasFetched = true
                replyConnection.invalidate()

                for device in self?.devices ?? [] {
                    self?.refreshModes(devicePersistentID: device.persistentID)
                }
            }
        }
    }

    func refreshModes(devicePersistentID: Int64) {

        guard !modesFetchInFlight.contains(devicePersistentID) else { return }
        modesFetchInFlight.insert(devicePersistentID)
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            connection.invalidate()
        }) as? DeckLinkHelperProtocol else {
            connection.invalidate()
            modesFetchInFlight.remove(devicePersistentID)
            return
        }
        nonisolated(unsafe) let replyConnection = connection
        proxy.listDisplayModes(devicePersistentID: devicePersistentID) { @Sendable data in
            let modes = (try? JSONDecoder().decode(
                [DeckLinkHelperDisplayMode].self, from: data)) ?? []

            DiagnosticsStore.shared.note(
                "decklink.modes",
                detail: "device \(devicePersistentID): \(modes.count) modes")
            Task { @MainActor [weak self] in
                self?.displayModes[devicePersistentID] = modes
                self?.modesFetchInFlight.remove(devicePersistentID)
                replyConnection.invalidate()
            }
        }
    }
}
