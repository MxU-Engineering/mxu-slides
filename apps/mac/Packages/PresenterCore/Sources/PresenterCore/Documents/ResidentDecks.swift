import Foundation
import Observation

public struct ResidentDeckTable: Sendable {
    public struct Entry: Sendable {
        public var value: Presentation
        public var epoch: Int

        public var stamp: DocumentFileStamp?
    }

    public private(set) var entries: [String: Entry] = [:]

    public private(set) var absent: [String: Int] = [:]

    public private(set) var filling: [String: Int] = [:]

    public init() {}

    public var ids: [String] { Array(entries.keys) }

    public func value(_ id: String) -> Presentation? {
        entries[id]?.value
    }

    public func currentValue(_ id: String, at epoch: Int) -> Presentation? {
        if let entry = entries[id], entry.epoch == epoch {
            return entry.value
        } else {
            return nil
        }
    }

    public func isResolved(_ id: String, at epoch: Int) -> Bool {
        entries[id]?.epoch == epoch || absent[id] == epoch
    }

    public func isFilling(_ id: String) -> Bool {
        filling[id] != nil
    }

    public mutating func beginFill(_ ids: Set<String>, at epoch: Int) -> Set<String> {
        let started = ids.filter { !isResolved($0, at: epoch) && filling[$0] == nil }
        for id in started { filling[id] = epoch }
        return started
    }

    @discardableResult
    public mutating func land(id: String, value: Presentation?, stamp: DocumentFileStamp?) -> Bool {
        if let epoch = filling.removeValue(forKey: id), knownAt(id) <= epoch {
            let changed = value != nil || entries[id] != nil
            if let value {
                entries[id] = Entry(value: value, epoch: epoch, stamp: stamp)
                absent[id] = nil
            } else {
                entries[id] = nil
                absent[id] = epoch
            }
            return changed
        } else {
            return false
        }
    }

    public mutating func reseed(id: String, value: Presentation?, epoch: Int) {
        carryOver(to: epoch, except: id)
        if let value {
            entries[id] = Entry(value: value, epoch: epoch, stamp: nil)
            absent[id] = nil
        } else {
            entries[id] = nil
            absent[id] = epoch
        }
    }

    public mutating func carryOver(to epoch: Int, except id: String? = nil) {
        let prior = epoch - 1
        for (key, entry) in entries where entry.epoch == prior {
            entries[key]?.epoch = epoch
        }
        for (key, known) in absent where known == prior {
            absent[key] = epoch
        }
        for (key, started) in filling where started == prior && key != id {
            filling[key] = epoch
        }
    }

    public mutating func forget(id: String, epoch: Int) {
        reseed(id: id, value: nil, epoch: epoch)
        absent[id] = nil
    }

    private func knownAt(_ id: String) -> Int {
        max(entries[id]?.epoch ?? Int.min, absent[id] ?? Int.min)
    }
}

@MainActor
public final class ResidentDecks {
    public private(set) var table = ResidentDeckTable()

    public private(set) var pinned: Set<String> = []

    public var onFillLanded: ((String) -> Void)?

    public static let readyRounds = 3

    private let source: any DeckBundleSource
    private let epochs: DocumentKindVersions
    private let fills: DocumentKindVersions
    private let library: ResidentLibrary
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(source: any DeckBundleSource, epochs: DocumentKindVersions, fills: DocumentKindVersions, library: ResidentLibrary) {
        self.source = source
        self.epochs = epochs
        self.fills = fills
        self.library = library
    }

    private var epoch: Int { epochs.untracked(.presentation) }

    public var fillVersion: Int { fills[.presentation] }

    @Observable
    final class Signal {
        fileprivate(set) var version = 0
    }

    private var signals: [String: Signal] = [:]

    private func observe(_ id: String) {
        if let signal = signals[id] {
            _ = signal.version
        } else {
            let signal = Signal()
            signals[id] = signal
            _ = signal.version
        }
    }

    private func changed(_ ids: some Sequence<String>) {
        for id in ids {
            signals[id]?.version &+= 1
        }
    }

    private func changedAll() {
        for signal in signals.values {
            signal.version &+= 1
        }
    }

    public func value(_ id: String) -> Presentation? {
        observe(id)
        fill([id])
        return table.value(id)
    }

    public func currentValue(_ id: String) -> Presentation? {
        observe(id)
        return table.currentValue(id, at: epoch)
    }

    public func fill(_ ids: Set<String>) {
        let started = table.beginFill(ids, at: epoch)
        if !started.isEmpty {
            let kinds: [DocumentKind: Int] = [
                .theme: epochs.untracked(.theme), .media: epochs.untracked(.media), .audio: epochs.untracked(.audio),
            ]
            let source = source
            Task(priority: .userInitiated) { [weak self] in
                let bundles = await source.deckBundles(ids: Array(started), priority: .userInitiated)
                self?.land(bundles, ids: started, kinds: kinds)
            }
        }
    }

    private func land(_ bundles: DeckBundles, ids: Set<String>, kinds: [DocumentKind: Int]) {
        var changedIDs: [String] = []
        var landed: [String] = []
        for id in ids.sorted() {
            let bundle = bundles.bundles[id]
            if table.land(id: id, value: bundle?.presentation, stamp: bundle?.stamp) {
                changedIDs.append(id)
                if bundle != nil { landed.append(id) }
            }
        }
        seedTables(bundles.bundles.values, kinds: kinds)
        if !changedIDs.isEmpty {
            fills.bump(.presentation)
            changed(changedIDs)
        }
        for id in landed { onFillLanded?(id) }
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
        fill(pinned)
    }

    private func seedTables(_ bundles: some Sequence<DeckBundle>, kinds: [DocumentKind: Int]) {
        let themes = epochs.untracked(.theme) == kinds[.theme]
        let media = epochs.untracked(.media) == kinds[.media]
        let audio = epochs.untracked(.audio) == kinds[.audio]
        for bundle in bundles {
            if themes {
                for (id, value) in bundle.themes {
                    library.themes.seed(id: id, value: value, stamp: bundle.stamps[SyncLedger.Key(kind: .theme, id: id)])
                }
            }
            if media {
                for (id, value) in bundle.media {
                    library.media.seed(id: id, value: value, stamp: bundle.stamps[SyncLedger.Key(kind: .media, id: id)])
                }
            }
            if audio {
                for (id, value) in bundle.audio {
                    library.audio.seed(id: id, value: value, stamp: bundle.stamps[SyncLedger.Key(kind: .audio, id: id)])
                }
            }
        }
    }

    public func reseed(id: String, value: Presentation?) {
        table.reseed(id: id, value: value, epoch: epoch)
        changed([id])
        fill(pinned)
    }

    public func carryOver() {
        table.carryOver(to: epoch)
        fill(pinned)
    }

    public func writeRefused(id: String) {
        table.forget(id: id, epoch: epoch)
        changed([id])
        fill(pinned)
    }

    public func libraryWideBump() {
        changedAll()
        fill(pinned)
    }

    public func kindWideBump() {
        changedAll()
    }

    public func pin(_ ids: Set<String>) {
        pinned = ids
        fill(ids)
    }

    nonisolated public static func liveSet(runOfShow: [ServiceItem], onAir: String?) -> Set<String> {
        var ids = Set(runOfShow.filter { $0.itemKind == .presentation && !$0.refId.isEmpty }.map(\.refId))
        if let onAir, !onAir.isEmpty {
            ids.insert(onAir)
        }
        return ids
    }

    public func ready(_ ids: [String]) async -> [String: Presentation] {
        let wanted = Set(ids)
        var seen = epoch
        var rounds = 0
        fill(wanted)
        while !isSettled(wanted, retrying: rounds < Self.readyRounds) {
            await withCheckedContinuation { waiters.append($0) }
            if epoch != seen {
                rounds += 1
                seen = epoch
            }
            if rounds < Self.readyRounds { fill(wanted) }
        }
        return wanted.reduce(into: [:]) { values, id in values[id] = table.value(id) }
    }

    public enum WriteTurn<T: Sendable> {
        case now(T)
        case later(Task<T, Never>)
    }

    private var writesWaiting: [String: (count: Int, last: Task<Void, Never>)] = [:]

    private var writing: Set<String> = []

    public func isHeldForWrite(_ id: String) -> Bool {
        writing.contains(id) || (writesWaiting[id] == nil && table.isResolved(id, at: epoch))
    }

    @discardableResult
    public func write<T: Sendable>(_ id: String, _ body: @escaping @MainActor (Presentation?) -> T) -> WriteTurn<T> {
        if isHeldForWrite(id) {
            return .now(body(table.value(id)))
        } else {
            let previous = writesWaiting[id]?.last
            let task = Task { @MainActor in
                await previous?.value
                let deck = await self.ready([id])[id]
                self.writing.insert(id)
                let result = body(deck)
                self.writing.remove(id)
                self.writeLanded(id)
                return result
            }
            writesWaiting[id] = ((writesWaiting[id]?.count ?? 0) + 1, Task { _ = await task.value })
            return .later(task)
        }
    }

    private func writeLanded(_ id: String) {
        if let waiting = writesWaiting[id], waiting.count > 1 {
            writesWaiting[id] = (waiting.count - 1, waiting.last)
        } else {
            writesWaiting[id] = nil
        }
    }

    private func isSettled(_ ids: Set<String>, retrying: Bool) -> Bool {
        if retrying {
            ids.allSatisfy { table.isResolved($0, at: epoch) }
        } else {
            ids.allSatisfy { table.isResolved($0, at: epoch) || !table.isFilling($0) }
        }
    }
}

public struct ResidencyStage {
    public var name: String
    public var kinds: [DocumentKind]
    public var work: (@MainActor () async -> Void)?

    public init(name: String, kinds: [DocumentKind], work: (@MainActor () async -> Void)? = nil) {
        self.name = name
        self.kinds = kinds
        self.work = work
    }
}

public struct ResidencyStageTiming: Sendable, Equatable {
    public var name: String
    public var milliseconds: Int

    public init(name: String, milliseconds: Int) {
        self.name = name
        self.milliseconds = milliseconds
    }

    public static func detail(_ timings: [ResidencyStageTiming]) -> String {
        timings.map { "\($0.name)=\($0.milliseconds)" }.joined(separator: " ")
    }
}

public extension ResidentLibrary {

    static let setupKinds: [DocumentKind] =
        kinds.filter { [.station, .local].contains(SyncScope.scope(for: $0)) } + [.service]

    static func launchStages(
        setup: (@MainActor () async -> Void)? = nil,
        liveSet: @escaping @MainActor () async -> Void
    ) -> [ResidencyStage] {
        let media: [DocumentKind] = [.media, .audio]
        let themes: [DocumentKind] = [.theme]
        let earlier = Set(setupKinds + media + themes)
        return [
            ResidencyStage(name: "setup", kinds: setupKinds, work: setup),
            ResidencyStage(name: "live", kinds: [], work: liveSet),
            ResidencyStage(name: "media", kinds: media),
            ResidencyStage(name: "themes", kinds: themes),
            ResidencyStage(name: "rest", kinds: kinds.filter { !earlier.contains($0) }),
        ]
    }

    func warmStaged(_ stages: [ResidencyStage], report: ([ResidencyStageTiming]) -> Void) async {
        var timings: [ResidencyStageTiming] = []
        for stage in stages {
            let began = ContinuousClock.now
            for table in all where stage.kinds.contains(table.kind) {
                table.refillIfBehind()
            }
            if let work = stage.work {
                await work()
            }
            await ready(stage.kinds)
            let elapsed = began.duration(to: .now).components
            timings.append(ResidencyStageTiming(
                name: stage.name,
                milliseconds: Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            ))
        }
        report(timings)
    }
}
