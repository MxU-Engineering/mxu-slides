import Foundation
import PresenterCore

public struct WorkspaceImportOptions: Codable, Equatable, Sendable {
    public var policy: ImportConflictPolicy = .updateUnedited

    public var presentations = true

    public var presentationMedia = true

    public var media = true
    public var themes = true
    public var overlays = true
    public var alerts = true
    public var confidenceLayouts = true
    public var combos = true
    public var playlists = true
    public var schedules = true
    public var groupHotKeys = true

    public var screens = true
    public var screenCorrections = true
    public var screenSlices = true
    public var screenMasks = true
    public var looks = true
    public var stageAssignments = true
    public var timers = true
    public var videoInputs = true
    public var midiDevices = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? fallback
        }
        policy = try container.decodeIfPresent(ImportConflictPolicy.self, forKey: .policy) ?? .updateUnedited
        presentations = try flag(.presentations, presentations)
        presentationMedia = try flag(.presentationMedia, presentationMedia)
        media = try flag(.media, media)
        themes = try flag(.themes, themes)
        overlays = try flag(.overlays, overlays)
        alerts = try flag(.alerts, alerts)
        confidenceLayouts = try flag(.confidenceLayouts, confidenceLayouts)
        combos = try flag(.combos, combos)
        playlists = try flag(.playlists, playlists)
        schedules = try flag(.schedules, schedules)
        groupHotKeys = try flag(.groupHotKeys, groupHotKeys)
        screens = try flag(.screens, screens)
        screenCorrections = try flag(.screenCorrections, screenCorrections)
        screenSlices = try flag(.screenSlices, screenSlices)
        screenMasks = try flag(.screenMasks, screenMasks)
        looks = try flag(.looks, looks)
        stageAssignments = try flag(.stageAssignments, stageAssignments)
        timers = try flag(.timers, timers)
        videoInputs = try flag(.videoInputs, videoInputs)
        midiDevices = try flag(.midiDevices, midiDevices)
    }
}

public struct WorkspaceScan: Sendable {
    public var presentations = 0

    public var media = 0
    public var themes = 0
    public var props = 0
    public var messages = 0
    public var stageLayouts = 0
    public var macros = 0
    public var playlists = 0
    public var calendarEvents = 0
    public var groupHotKeys = 0
    public var timers = 0
    public var videoInputs = 0
    public var midiDevices = 0
    public var screens = 0
    public var looks = 0

    public init() {}
}

public enum ImportSkipReason: String, Sendable {

    case existing

    case edited
}

@MainActor
public final class ImportWriter {
    public let policy: ImportConflictPolicy
    private let client: LibraryClient

    private let placement: LibraryHome.Placement
    private var ledger: ImportLedger
    private var ledgerDirty = false
    public private(set) var skippedExisting = 0

    public private(set) var skippedEdited: [String] = []

    public init(client: LibraryClient, policy: ImportConflictPolicy, placement: LibraryHome.Placement = .unplaced) async {
        self.client = client
        self.policy = policy
        self.placement = placement
        await client.settled()
        ledger = (try? await client.loadValue(ImportLedger.self, id: ImportLedger.wellKnownID))
            ?? ImportLedger(id: ImportLedger.wellKnownID, entries: [])
    }

    public var ledgerSnapshot: ImportLedger { ledger }

    public func check<E: DocumentEntity>(
        _ type: E.Type, id: String, label: String
    ) async -> ImportSkipReason? {
        if let existing = try? await client.loadValue(E.self, id: id) {
            switch policy {
            case .keepMine:
                skippedExisting += 1
                return .existing
            case .updateUnedited:
                if ledger.isUnedited(
                    docId: id, currentHash: ImportFingerprint.hash(existing)
                ) {
                    return nil
                }
                skippedEdited.append(label)
                return .edited
            case .replace:
                return nil
            }
        } else {
            return nil
        }
    }

    public func write<E: DocumentEntity>(
        _ value: E, label: String, warnings: inout [String]
    ) async -> Bool {
        do {
            let batch = try await client.replace(value, area: placement.area(for: E.documentKind)).value
            let stored = batch.value(E.self, id: value.id) ?? value
            if let hash = ImportFingerprint.hash(stored) {
                ledger.stamp(value.id, hash)
                ledgerDirty = true
            }
            return true
        } catch {
            warnings.append("\(label) could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    public func stampHotKeys(_ stamps: [(docId: String, hash: String)]) {
        guard !stamps.isEmpty else { return }
        for stamp in stamps { ledger.stamp(stamp.docId, stamp.hash) }
        ledgerDirty = true
    }

    public func saveLedger() {
        if ledgerDirty {
            let entries = ledger.entries
            client.modify(
                ImportLedger.self, id: ImportLedger.wellKnownID,
                orMake: { ImportLedger(id: ImportLedger.wellKnownID, entries: []) }
            ) { $0.entries = entries }
            ledgerDirty = false
        }
    }
}
