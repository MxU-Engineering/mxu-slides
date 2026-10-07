import Darwin
import Foundation

public struct DocumentFileStamp: Equatable, Sendable {
    public var inode: UInt64
    public var size: Int64
    public var modifiedNanoseconds: Int64

    public init(inode: UInt64, size: Int64, modifiedNanoseconds: Int64) {
        self.inode = inode
        self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    public static func of(_ url: URL) -> DocumentFileStamp? {
        var info = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) == 0 } ?? false
        }
        if found {
            return DocumentFileStamp(
                inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(info.st_mtimespec.tv_nsec)
            )
        } else {
            return nil
        }
    }
}

public struct ResidentTableFill<Value: Sendable>: Sendable {
    public struct Decoded: Sendable {
        public var value: Value
        public var stamp: DocumentFileStamp?

        public init(value: Value, stamp: DocumentFileStamp?) {
            self.value = value
            self.stamp = stamp
        }
    }

    public var epoch: Int
    public var decoded: [String: Decoded]
    public var unchanged: [String: DocumentFileStamp]

    public init(epoch: Int, decoded: [String: Decoded] = [:], unchanged: [String: DocumentFileStamp] = [:]) {
        self.epoch = epoch
        self.decoded = decoded
        self.unchanged = unchanged
    }
}

public protocol ResidentFillSource: Sendable {
    @concurrent
    func fillResidentTable<Entity: DocumentEntity>(
        _ type: Entity.Type, epoch: Int, known: [String: DocumentFileStamp]
    ) async -> ResidentTableFill<Entity>
}

extension DocumentStore: ResidentFillSource {}

public extension DocumentStore {

    @concurrent
    func fillResidentTable<Entity: DocumentEntity>(
        _ type: Entity.Type, epoch: Int, known: [String: DocumentFileStamp]
    ) async -> ResidentTableFill<Entity> {
        var fill = ResidentTableFill<Entity>(epoch: epoch)
        var changed: [String] = []
        var stamps: [String: DocumentFileStamp] = [:]
        for id in (try? ids(of: Entity.documentKind)) ?? [] {
            let stamp = DocumentFileStamp.of(url(kind: Entity.documentKind, id: id))
            if let stamp, known[id] == stamp {
                fill.unchanged[id] = stamp
            } else {
                changed.append(id)
                stamps[id] = stamp
            }
        }
        for (id, value) in await loadValues(type, ids: changed).values {
            fill.decoded[id] = .init(value: value, stamp: stamps[id])
        }
        return fill
    }
}

public struct ResidentTable<Value: Sendable>: Sendable {
    public struct Entry: Sendable {
        public var value: Value
        public var epoch: Int
        public var stamp: DocumentFileStamp?
    }

    public private(set) var entries: [String: Entry] = [:]

    public private(set) var coveredEpoch: Int?

    public private(set) var fillingEpoch: Int?

    public init() {}

    public var isFilled: Bool { coveredEpoch != nil }
    public var ids: [String] { Array(entries.keys) }
    public var values: [Value] { entries.values.map(\.value) }

    public func value(_ id: String) -> Value? {
        entries[id]?.value
    }

    public func currentValue(_ id: String, at epoch: Int) -> Value? {
        if let entry = entries[id], entry.epoch == epoch {
            return entry.value
        } else {
            return nil
        }
    }

    public func isCovered(at epoch: Int) -> Bool {
        coveredEpoch == epoch
    }

    public func isCovered(since epoch: Int) -> Bool {
        coveredEpoch.map { $0 >= epoch } ?? false
    }

    public mutating func beginFill(at epoch: Int) -> [String: DocumentFileStamp]? {
        if fillingEpoch == nil, coveredEpoch != epoch {
            fillingEpoch = epoch
            return entries.compactMapValues(\.stamp)
        } else {
            return nil
        }
    }

    public mutating func land(_ fill: ResidentTableFill<Value>) {
        if fillingEpoch == fill.epoch { fillingEpoch = nil }
        if coveredEpoch.map({ $0 <= fill.epoch }) ?? true {
            var next = entries.filter { $0.value.epoch > fill.epoch }
            for (id, decoded) in fill.decoded where next[id] == nil {
                next[id] = Entry(value: decoded.value, epoch: fill.epoch, stamp: decoded.stamp)
            }
            for (id, stamp) in fill.unchanged where next[id] == nil {
                if let kept = entries[id] {
                    next[id] = Entry(value: kept.value, epoch: fill.epoch, stamp: stamp)
                }
            }
            entries = next
            coveredEpoch = fill.epoch
        }
    }

    public mutating func reseed(id: String, value: Value?, epoch: Int) {
        let prior = epoch - 1
        for (key, entry) in entries where entry.epoch == prior {
            entries[key]?.epoch = epoch
        }
        entries[id] = value.map { Entry(value: $0, epoch: epoch, stamp: nil) }
        if coveredEpoch == prior { coveredEpoch = epoch }
    }

    public mutating func seed(id: String, value: Value, epoch: Int, stamp: DocumentFileStamp? = nil) {
        if (entries[id]?.epoch ?? Int.min) <= epoch {
            entries[id] = Entry(value: value, epoch: epoch, stamp: stamp)
        }
    }
}

public enum ResidentFireRead<Value> {

    case now(Value?)

    case afterFill

    public init(id: String, current: Value?, covered: Bool) {
        if id.isEmpty {
            self = .now(nil)
        } else if let current {
            self = .now(current)
        } else if covered {
            self = .now(nil)
        } else {
            self = .afterFill
        }
    }
}

@MainActor
public final class ResidentDocuments<Entity: DocumentEntity> {
    public private(set) var table = ResidentTable<Entity>()
    private let source: any ResidentFillSource
    private let epochs: DocumentKindVersions
    private let fills: DocumentKindVersions
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(source: any ResidentFillSource, epochs: DocumentKindVersions, fills: DocumentKindVersions) {
        self.source = source
        self.epochs = epochs
        self.fills = fills
    }

    public convenience init(store: DocumentStore, epochs: DocumentKindVersions, fills: DocumentKindVersions) {
        self.init(source: store, epochs: epochs, fills: fills)
    }

    public var kind: DocumentKind { Entity.documentKind }
    private var epoch: Int { epochs[kind] }

    private func observe() {
        _ = epochs[kind]
        _ = fills[kind]
    }

    public func value(_ id: String) -> Entity? {
        observe()
        refillIfBehind()
        return table.value(id)
    }

    public var values: [Entity] {
        observe()
        refillIfBehind()
        return table.values
    }

    public var ids: [String] {
        observe()
        refillIfBehind()
        return table.ids
    }

    public func currentValue(_ id: String) -> Entity? {
        table.currentValue(id, at: epoch)
    }

    public var isCovered: Bool { table.isCovered(at: epoch) }
    public var isFilled: Bool { table.isFilled }

    public func refillIfBehind() {
        let epoch = epoch
        if let known = table.beginFill(at: epoch) {
            let source = source
            Task(priority: .userInitiated) { [weak self] in
                let fill = await source.fillResidentTable(Entity.self, epoch: epoch, known: known)
                self?.land(fill)
            }
        }
    }

    private func land(_ fill: ResidentTableFill<Entity>) {
        table.land(fill)
        fills.bump(kind)
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
        refillIfBehind()
    }

    public func ready() async {
        let target = epoch
        while !table.isCovered(since: target) {
            refillIfBehind()
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    public func reseed(id: String, value: Entity?) {
        table.reseed(id: id, value: value, epoch: epoch)
    }

    public func seed(id: String, value: Entity, stamp: DocumentFileStamp? = nil) {
        table.seed(id: id, value: value, epoch: epoch, stamp: stamp)
    }

    public func anyValue(_ id: String) -> (any DocumentEntity)? {
        value(id)
    }

    public func fireRead(_ id: String) -> ResidentFireRead<Entity> {
        if !id.isEmpty { refillIfBehind() }
        return ResidentFireRead(id: id, current: id.isEmpty ? nil : currentValue(id), covered: isCovered)
    }

    public func reseed(id: String, anyValue: (any DocumentEntity)?) {
        if anyValue == nil || anyValue is Entity {
            reseed(id: id, value: anyValue as? Entity)
        }
    }
}

@MainActor
public protocol ResidentKindTable: AnyObject {
    var kind: DocumentKind { get }
    var isFilled: Bool { get }
    func refillIfBehind()
    func ready() async
    func anyValue(_ id: String) -> (any DocumentEntity)?
    func reseed(id: String, anyValue: (any DocumentEntity)?)
}

extension ResidentDocuments: ResidentKindTable {}

@MainActor
public final class ResidentLibrary {
    public let media: ResidentDocuments<MediaItem>
    public let audio: ResidentDocuments<AudioItem>
    public let themes: ResidentDocuments<Theme>
    public let services: ResidentDocuments<Service>
    public let playlists: ResidentDocuments<Playlist>
    public let overlays: ResidentDocuments<Overlay>
    public let alertPresets: ResidentDocuments<AlertPreset>
    public let streamPresets: ResidentDocuments<StreamRecordPreset>
    public let streamDestinations: ResidentDocuments<StreamDestination>
    public let actionCombos: ResidentDocuments<ActionCombo>
    public let scheduleTriggers: ResidentDocuments<ScheduleTrigger>
    public let confidenceLayouts: ResidentDocuments<ConfidenceLayout>
    public let schedulerBoards: ResidentDocuments<SchedulerBoard>
    public let controlBoards: ResidentDocuments<ControlBoard>
    public let groupPalettes: ResidentDocuments<GroupPalette>
    public let signageBoards: ResidentDocuments<SignageBoard>
    public let effectPresetBoards: ResidentDocuments<EffectPresetBoard>
    public let animationPresetBoards: ResidentDocuments<AnimationPresetBoard>
    public let serviceLinkRules: ResidentDocuments<ServiceLinkRules>
    public let slideBuildingSettings: ResidentDocuments<SlideBuildingSettings>
    public let outputPresets: ResidentDocuments<OutputPreset>
    public let midiDevices: ResidentDocuments<MIDIDevice>

    public let all: [any ResidentKindTable]

    public static let kinds: [DocumentKind] = [
        .media, .audio, .theme, .service, .playlist, .overlay,
        .alertPreset, .streamRecordPreset, .streamDestination, .actionCombo,
        .scheduleTrigger, .confidenceLayout, .schedulerBoard,
        .controlBoard, .groupPalette, .signageBoard, .effectPresetBoard,
        .animationPresetBoard, .serviceLinkRules, .slideBuildingSettings, .outputPreset, .midiDevice,
    ]

    public convenience init(store: DocumentStore, epochs: DocumentKindVersions, fills: DocumentKindVersions) {
        self.init(source: store, epochs: epochs, fills: fills)
    }

    public init(source: any ResidentFillSource, epochs: DocumentKindVersions, fills: DocumentKindVersions) {
        media = .init(source: source, epochs: epochs, fills: fills)
        audio = .init(source: source, epochs: epochs, fills: fills)
        themes = .init(source: source, epochs: epochs, fills: fills)
        services = .init(source: source, epochs: epochs, fills: fills)
        playlists = .init(source: source, epochs: epochs, fills: fills)
        overlays = .init(source: source, epochs: epochs, fills: fills)
        alertPresets = .init(source: source, epochs: epochs, fills: fills)
        streamPresets = .init(source: source, epochs: epochs, fills: fills)
        streamDestinations = .init(source: source, epochs: epochs, fills: fills)
        actionCombos = .init(source: source, epochs: epochs, fills: fills)
        scheduleTriggers = .init(source: source, epochs: epochs, fills: fills)
        confidenceLayouts = .init(source: source, epochs: epochs, fills: fills)
        schedulerBoards = .init(source: source, epochs: epochs, fills: fills)
        controlBoards = .init(source: source, epochs: epochs, fills: fills)
        groupPalettes = .init(source: source, epochs: epochs, fills: fills)
        signageBoards = .init(source: source, epochs: epochs, fills: fills)
        effectPresetBoards = .init(source: source, epochs: epochs, fills: fills)
        animationPresetBoards = .init(source: source, epochs: epochs, fills: fills)
        serviceLinkRules = .init(source: source, epochs: epochs, fills: fills)
        slideBuildingSettings = .init(source: source, epochs: epochs, fills: fills)
        outputPresets = .init(source: source, epochs: epochs, fills: fills)
        midiDevices = .init(source: source, epochs: epochs, fills: fills)
        all = [
            media, audio, themes, services, playlists, overlays,
            alertPresets, streamPresets, streamDestinations, actionCombos,
            scheduleTriggers, confidenceLayouts, schedulerBoards,
            controlBoards, groupPalettes, signageBoards, effectPresetBoards,
            animationPresetBoards, serviceLinkRules, slideBuildingSettings, outputPresets, midiDevices,
        ]
    }

    public func warmAll() {
        for table in all { table.refillIfBehind() }
    }

    public func table<Entity: DocumentEntity>(_ type: Entity.Type) -> ResidentDocuments<Entity>? {
        all.first { $0.kind == Entity.documentKind } as? ResidentDocuments<Entity>
    }

    public func reseed<Entity: DocumentEntity>(_ value: Entity) {
        table(Entity.self)?.reseed(id: value.id, value: value)
    }

    public func reseed(kind: DocumentKind, id: String, value: (any DocumentEntity)?) {
        all.first { $0.kind == kind }?.reseed(id: id, anyValue: value)
    }

    public func value(kind: DocumentKind, id: String) -> (any DocumentEntity)? {
        all.first { $0.kind == kind }?.anyValue(id)
    }

    public func isResident(_ kind: DocumentKind) -> Bool {
        all.contains { $0.kind == kind }
    }

    public func ready(_ kinds: [DocumentKind]) async {
        for table in all where kinds.contains(table.kind) {
            await table.ready()
        }
    }
}
