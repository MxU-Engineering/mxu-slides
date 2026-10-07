import CoreMIDI
import Foundation
import Observation
import PresenterCore
import SwiftUI

enum MIDIDeviceStore {

    static let legacyDefaultsKey = "midi.devices.inventory"
    static let bindingsKey = "midi.devices.bindings"
    static let mapDefaultsKey = "midi.map"
    static let cachedTargetsKey = "midi.out.targets"

    static func loadLegacyEntries() -> [MIDIDeviceEntry] {
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let stored = try? JSONDecoder().decode([MIDIDeviceEntry].self, from: data)
        else { return [] }
        return stored
    }

    static func loadBindings() -> [String: MIDIDeviceBinding] {
        guard let data = UserDefaults.standard.data(forKey: bindingsKey),
              let stored = try? JSONDecoder().decode([String: MIDIDeviceBinding].self, from: data)
        else { return [:] }
        return stored
    }

    static func saveBindings(_ bindings: [String: MIDIDeviceBinding]) {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: bindingsKey)
        }
    }

    static func loadCachedTargets() -> Set<Int32>? {
        guard let data = UserDefaults.standard.data(forKey: cachedTargetsKey),
              let stored = try? JSONDecoder().decode([Int32].self, from: data)
        else { return nil }
        return Set(stored)
    }

    static func saveCachedTargets(_ targets: Set<Int32>?) {
        if let targets, let data = try? JSONEncoder().encode(Array(targets)) {
            UserDefaults.standard.set(data, forKey: cachedTargetsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cachedTargetsKey)
        }
    }

    static func loadMap() -> MIDICommandMap {
        guard let data = UserDefaults.standard.data(forKey: mapDefaultsKey),
              let stored = try? JSONDecoder().decode(MIDICommandMap.self, from: data)
        else { return MIDICommandMap() }
        return stored
    }
}

@MainActor
@Observable
final class MIDIDeviceInventory {
    static let shared = MIDIDeviceInventory()

    private(set) var items: [ResolvedMIDIDevice] = []

    private(set) var discoveredDestinations: [MIDIEndpoint] = []
    private(set) var discoveredSources: [MIDIEndpoint] = []
    private var documents: [MIDIDevice] = []
    private var bindings: [String: MIDIDeviceBinding] = [:]

    private var table: ResidentDocuments<MIDIDevice>?
    private var client: LibraryClient?
    private var setupClient = MIDIClientRef()

    private init() {}

    func configure(model: AppModel) {
        table = model.resident.midiDevices
        client = model.client
        bindings = MIDIDeviceStore.loadBindings()
        migrateLegacyEntries()
        startSetupNotifications()
        reload()
        watchDocuments(model)
    }

    private func watchDocuments(_ model: AppModel) {
        withObservationTracking {
            _ = model.version(of: .midiDevice)
            _ = model.fillVersion(of: .midiDevice)
        } onChange: { [weak model] in
            Task { @MainActor [weak model] in
                if let model {
                    MIDIDeviceInventory.shared.reload()
                    MIDIDeviceInventory.shared.watchDocuments(model)
                }
            }
        }
    }

    private func startSetupNotifications() {
        guard setupClient == 0 else { return }
        MIDIClientCreateWithBlock(
            "MxU Slides Setup" as CFString, &setupClient
        ) { notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }

            Task { @MainActor in
                MIDIDeviceInventory.shared.reresolve()
                DiagnosticsStore.shared.note("midi.devices", detail: "setup changed")
            }
        }
    }

    func reload() {
        if let table, table.isFilled {
            documents = table.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            reresolve()
        } else {
            table?.refillIfBehind()
        }
    }

    func reresolve() {
        discoveredDestinations = Self.destinationEndpoints()
        discoveredSources = Self.sourceEndpoints()
        items = MIDIDeviceResolver.resolve(
            devices: documents,
            bindings: bindings,
            destinations: discoveredDestinations,
            sources: discoveredSources
        )
        let targets = items.outputTargetUIDs
        MIDIDeviceStore.saveCachedTargets(targets)
        MIDIOutService.shared.setTargets(targets)
        MIDIInService.shared.setSources(items.inputSourceUIDs)
    }

    func add(discovered device: MIDIDeviceEntry) {
        guard let client else { return }
        var doc = MIDIDevice(id: UUID().uuidString, name: device.name)
        if device.direction == .input { doc.direction = .input }
        wrote(client.create(doc)) { $0.append(doc) }
        bindings[doc.id] = MIDIDeviceBinding(
            destinationUID: device.direction == .input ? nil : device.uid,
            sourceUID: device.sourceUid
        )
        MIDIDeviceStore.saveBindings(bindings)
        reresolve()
        DiagnosticsStore.shared.note("midi.devices", detail: "added: \(device.name)")
    }

    func remove(_ item: ResolvedMIDIDevice) {
        guard let client else { return }
        wrote(client.delete(kind: .midiDevice, id: item.id)) { $0.removeAll { $0.id == item.id } }
        bindings[item.id] = nil
        MIDIDeviceStore.saveBindings(bindings)
        reresolve()
        DiagnosticsStore.shared.note("midi.devices", detail: "removed: \(item.device.name)")
    }

    private func wrote(_ write: Task<LibraryBatch, any Error>, _ change: (inout [MIDIDevice]) -> Void) {
        change(&documents)
        Task {
            _ = await write.result
            MIDIDeviceInventory.shared.reload()
        }
    }

    func setEnabled(_ item: ResolvedMIDIDevice, enabled: Bool) {
        updateDocument(item) { $0.enabled = enabled ? nil : false }
        DiagnosticsStore.shared.note(
            "midi.devices", detail: "\(enabled ? "enabled" : "disabled"): \(item.device.name)")
    }

    func setDirection(_ item: ResolvedMIDIDevice, direction: MIDIDeviceItemDirection) {
        updateDocument(item) { $0.direction = direction == .both ? nil : direction }
        DiagnosticsStore.shared.note(
            "midi.devices", detail: "\(direction.rawValue): \(item.device.name)")
    }

    func setChannel(_ item: ResolvedMIDIDevice, channel: Int?) {
        updateDocument(item) { $0.channel = channel }
        DiagnosticsStore.shared.note(
            "midi.devices", detail: "channel \(channel.map(String.init) ?? "any"): \(item.device.name)")
    }

    func setDestinationBinding(_ item: ResolvedMIDIDevice, uid: Int32?) {
        var binding = bindings[item.id] ?? MIDIDeviceBinding()
        binding.destinationUID = uid
        bindings[item.id] = (binding.destinationUID == nil && binding.sourceUID == nil) ? nil : binding
        MIDIDeviceStore.saveBindings(bindings)
        reresolve()
    }

    func setSourceBinding(_ item: ResolvedMIDIDevice, uid: Int32?) {
        var binding = bindings[item.id] ?? MIDIDeviceBinding()
        binding.sourceUID = uid
        bindings[item.id] = (binding.destinationUID == nil && binding.sourceUID == nil) ? nil : binding
        MIDIDeviceStore.saveBindings(bindings)
        reresolve()
    }

    private func updateDocument(_ item: ResolvedMIDIDevice, _ mutate: @escaping @Sendable (inout MIDIDevice) -> Void) {
        guard let client else { return }
        wrote(client.modify(MIDIDevice.self, id: item.id, mutate)) { documents in
            if let index = documents.firstIndex(where: { $0.id == item.id }) { mutate(&documents[index]) }
        }
        reresolve()
    }

    private func migrateLegacyEntries() {
        guard let client else { return }
        let legacy = MIDIDeviceStore.loadLegacyEntries()
        guard !legacy.isEmpty else { return }
        for entry in legacy {
            var device = MIDIDevice(id: UUID().uuidString, name: entry.name)
            device.direction = switch entry.effectiveDirection {
            case .output: MIDIDeviceItemDirection.output
            case .input: .input
            case .both: nil  
            }
            device.channel = entry.channel
            device.enabled = entry.enabled
            wrote(client.create(device)) { $0.append(device) }
            bindings[device.id] = MIDIDeviceBinding(
                destinationUID: entry.wantsOutput ? entry.uid : nil,
                sourceUID: entry.wantsInput ? (entry.sourceUid ?? entry.uid) : nil
            )
        }
        MIDIDeviceStore.saveBindings(bindings)
        UserDefaults.standard.removeObject(forKey: MIDIDeviceStore.legacyDefaultsKey)
        DiagnosticsStore.shared.note("midi.devices", detail: "migrated \(legacy.count) to documents")
    }

    static func destinationEndpoints() -> [MIDIEndpoint] {
        endpoints(count: MIDIGetNumberOfDestinations(), at: MIDIGetDestination)
    }

    static func sourceEndpoints() -> [MIDIEndpoint] {
        endpoints(count: MIDIGetNumberOfSources(), at: MIDIGetSource)
    }

    var discoveredDevices: [MIDIDeviceEntry] {
        MIDIDeviceResolver.discovered(
            destinations: discoveredDestinations, sources: discoveredSources)
    }

    private static func endpoints(
        count: Int, at endpoint: (Int) -> MIDIEndpointRef
    ) -> [MIDIEndpoint] {
        (0..<count).compactMap { index in
            let endpoint = endpoint(index)
            guard endpoint != 0 else { return nil }
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid) == noErr
            else { return nil }
            var nameRef: Unmanaged<CFString>?
            var name = "MIDI Device"
            if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &nameRef) == noErr,
               let value = nameRef?.takeRetainedValue() {
                name = value as String
            }
            return MIDIEndpoint(uid: uid, name: name)
        }
    }
}

@MainActor
@Observable
final class MIDICommandMapStore {
    static let shared = MIDICommandMapStore()

    var map: MIDICommandMap {
        didSet {
            guard map != oldValue else { return }
            if let data = try? JSONEncoder().encode(map) {
                UserDefaults.standard.set(data, forKey: MIDIDeviceStore.mapDefaultsKey)
            }
        }
    }

    private init() {
        map = MIDIDeviceStore.loadMap()
    }
}
