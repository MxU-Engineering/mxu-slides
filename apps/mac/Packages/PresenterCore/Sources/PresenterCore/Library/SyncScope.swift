import Foundation

public enum SyncScope: String, Codable, CaseIterable, Sendable {
    case team
    case station
    case local

    public static func scope(for kind: DocumentKind) -> SyncScope {
        switch kind {
        case .presentation, .service, .theme, .media, .audio, .playlist, .overlay,
             .alertPreset, .actionCombo, .scheduleTrigger, .confidenceLayout, .groupPalette,
             .effectPresetBoard, .animationPresetBoard, .serviceLinkRules, .note, .slideBuildingSettings, .font:
            .team
        case .outputPreset, .controlBoard, .schedulerBoard, .signageBoard, .midiDevice,
             .streamDestination, .streamRecordPreset, .stationSettings, .workspaceSettings:
            .station
        case .importLedger:
            .local
        }
    }

    public static func everyComputerHolds(_ kind: DocumentKind) -> Bool {
        kind == .slideBuildingSettings || kind == .font
    }

    public static func kinds(in scope: SyncScope) -> [DocumentKind] {
        DocumentKind.allCases.filter { self.scope(for: $0) == scope }
    }

    public static func entityType(for kind: DocumentKind) -> any DocumentEntity.Type {
        switch kind {
        case .presentation: Presentation.self
        case .service: Service.self
        case .theme: Theme.self
        case .media: MediaItem.self
        case .audio: AudioItem.self
        case .playlist: Playlist.self
        case .overlay: Overlay.self
        case .outputPreset: OutputPreset.self
        case .alertPreset: AlertPreset.self
        case .streamRecordPreset: StreamRecordPreset.self
        case .streamDestination: StreamDestination.self
        case .actionCombo: ActionCombo.self
        case .scheduleTrigger: ScheduleTrigger.self
        case .schedulerBoard: SchedulerBoard.self
        case .controlBoard: ControlBoard.self
        case .confidenceLayout: ConfidenceLayout.self
        case .groupPalette: GroupPalette.self
        case .signageBoard: SignageBoard.self
        case .effectPresetBoard: EffectPresetBoard.self
        case .animationPresetBoard: AnimationPresetBoard.self
        case .midiDevice: MIDIDevice.self
        case .importLedger: ImportLedger.self
        case .serviceLinkRules: ServiceLinkRules.self
        case .note: NoteDocument.self
        case .stationSettings: StationSettings.self
        case .slideBuildingSettings: SlideBuildingSettings.self
        case .font: FontFile.self
        case .workspaceSettings: WorkspaceSettings.self
        }
    }
}

public enum LibraryArea: String, Codable, CaseIterable, Sendable {
    case team
    case station
    case local

    public static let `default` = LibraryArea.station

    public static func resolve(row: LibraryArea?, entry: SyncLedger.Entry?) -> LibraryArea {
        if let row {
            row
        } else if let entry, entry.remoteSeq > 0 {
            .team
        } else {
            .default
        }
    }

    public static func namespace(kind: DocumentKind, area: LibraryArea) -> SyncScope? {
        switch SyncScope.scope(for: kind) {
        case .local: nil
        case .station: .station
        case .team:
            switch area {
            case .team: .team
            case .station: .station
            case .local: nil
            }
        }
    }
}

public protocol FolderedEntity {
    var folder: String? { get set }
}

public protocol TeamFolderedEntity: FolderedEntity {
    var folderId: String? { get set }
}

public enum TeamFoldered {

    public static let kinds: Set<DocumentKind> = [.presentation, .overlay, .media, .audio, .confidenceLayout]
}

public enum LibraryHome {
    public static let needsSorted = "Needs Sorted"

    public struct Viewed: Equatable, Sendable {
        public var kind: DocumentKind
        public var area: LibraryArea
        public var path: String

        public init(kind: DocumentKind, area: LibraryArea, path: String) {
            self.kind = kind
            self.area = area
            self.path = path
        }
    }

    public static func area(for kind: DocumentKind) -> LibraryArea? {
        SyncScope.scope(for: kind) == .team ? .team : nil
    }

    public static func folder(for kind: DocumentKind, named: String?, viewing: Viewed?) -> String? {
        if !TeamFoldered.kinds.contains(kind) {
            nil
        } else if let named, !named.isEmpty {
            named
        } else if let viewing, viewing.kind == kind, viewing.area == .team, !viewing.path.isEmpty {
            viewing.path
        } else {
            needsSorted
        }
    }

    public struct Placement: Equatable, Sendable {
        public var inDrive: Bool
        public var viewing: Viewed?

        public static let unplaced = Placement(inDrive: false, viewing: nil)

        public static func drive(viewing: Viewed?) -> Placement {
            Placement(inDrive: true, viewing: viewing)
        }

        public func folder(for kind: DocumentKind) -> String? {
            inDrive ? LibraryHome.folder(for: kind, named: nil, viewing: viewing) : nil
        }

        public func area(for kind: DocumentKind) -> LibraryArea? {
            inDrive ? LibraryHome.area(for: kind) : nil
        }
    }
}

extension Presentation: TeamFolderedEntity {}
extension MediaItem: TeamFolderedEntity {}
extension AudioItem: TeamFolderedEntity {}
extension Overlay: TeamFolderedEntity {}
extension ConfidenceLayout: TeamFolderedEntity {}
extension NoteDocument: FolderedEntity {}

public enum OfflineSetLogic {
    public struct Entry: Equatable, Sendable {
        public var kind: String
        public var ref: String

        public var library: String?
        public init(kind: String, ref: String, library: String? = nil) {
            self.kind = kind
            self.ref = ref
            self.library = library
        }
    }

    public static let onlineOnlyKind = "online_only"
    public static let onlineOnlyItemKind = "online_only_item"
    public static let scheduledServicesKind = "scheduled_services"
    public static let allDrivesKind = "all_drives"
    static let pathKinds: Set<String> = ["folder", onlineOnlyKind]

    public static let libraries = TeamFoldered.kinds.map(\.rawValue).sorted()

    public static func covers(
        _ entries: [Entry], docId: String, folder: String?, library: String? = nil, upcoming: Set<String> = []
    ) -> Bool {
        let path = folder ?? ""
        let depth: (String) -> Int = { $0.split(separator: "/").count }
        let inLibrary: (Entry) -> Bool = { $0.library == nil || $0.library == library }
        var keep = -1
        var drop = -1
        var dropped = false
        for entry in entries {
            switch entry.kind {
            case allDrivesKind: keep = max(keep, 0)
            case "item": if entry.ref == docId { keep = Int.max }
            case "folder": if !entry.ref.isEmpty, inLibrary(entry), TeamDriveLogic.isUnder(path, prefix: entry.ref) { keep = max(keep, depth(entry.ref)) }
            case onlineOnlyKind: if !entry.ref.isEmpty, inLibrary(entry), TeamDriveLogic.isUnder(path, prefix: entry.ref) { drop = max(drop, depth(entry.ref)) }
            case onlineOnlyItemKind: if entry.ref == docId { dropped = true }
            case scheduledServicesKind: if upcoming.contains(docId) { keep = Int.max }
            default: break
            }
        }
        return !dropped && keep > drop
    }

    public static func droppedItems(_ entries: [Entry]) -> Set<String> {
        Set(entries.filter { $0.kind == onlineOnlyItemKind }.map(\.ref))
    }

    static func splitting(_ entries: [Entry], folder: String) -> [Entry] {
        entries.flatMap { entry in
            pathKinds.contains(entry.kind) && entry.library == nil
                && (TeamDriveLogic.isUnder(entry.ref, prefix: folder) || TeamDriveLogic.isUnder(folder, prefix: entry.ref))
                ? libraries.map { Entry(kind: entry.kind, ref: entry.ref, library: $0) } : [entry]
        }
    }

    public static func keeping(_ entries: [Entry], folder: String, library: String) -> [Entry] {
        let kept = splitting(entries, folder: folder).filter {
            !($0.kind == onlineOnlyKind && $0.library == library && TeamDriveLogic.isUnder($0.ref, prefix: folder))
        }
        return covers(kept, docId: "", folder: folder, library: library) ? kept : kept + [Entry(kind: "folder", ref: folder, library: library)]
    }

    public static func droppingFolder(_ entries: [Entry], folder: String, library: String) -> [Entry] {
        let rest = splitting(entries, folder: folder).filter {
            !(pathKinds.contains($0.kind) && $0.library == library && TeamDriveLogic.isUnder($0.ref, prefix: folder))
        }
        return covers(rest, docId: "", folder: folder, library: library) ? rest + [Entry(kind: onlineOnlyKind, ref: folder, library: library)] : rest
    }

    public static func keepingItems(_ entries: [Entry], ids: [(id: String, folder: String?, library: String?)], upcoming: Set<String> = []) -> [Entry] {
        let asked = Set(ids.map(\.id))
        let rest = entries.filter { !($0.kind == onlineOnlyItemKind && asked.contains($0.ref)) }
        let adding = ids.filter { !covers(rest, docId: $0.id, folder: $0.folder, library: $0.library, upcoming: upcoming) }
        return rest + adding.map { Entry(kind: "item", ref: $0.id) }
    }

    public static func droppingItems(_ entries: [Entry], ids: [(id: String, folder: String?, library: String?)], upcoming: Set<String> = []) -> [Entry] {
        let asked = Set(ids.map(\.id))
        let rest = entries.filter { !(["item", onlineOnlyItemKind].contains($0.kind) && asked.contains($0.ref)) }
        return rest + ids.map { Entry(kind: onlineOnlyItemKind, ref: $0.id) }
    }

    public static func unfinished(
        _ items: [(id: String, folder: String?, library: String, fileHere: Bool)],
        entries: [Entry], upcoming: Set<String>, referenced: Set<String>
    ) -> [String] {
        items.filter { item in
            !item.fileHere && !referenced.contains(item.id)
                && !covers(entries, docId: item.id, folder: item.folder, library: item.library, upcoming: upcoming)
        }.map(\.id)
    }

    public static func upcomingServices(_ services: [(id: String, date: String?)], today: Date, calendar: Calendar = .current) -> [String] {
        let start = calendar.startOfDay(for: today)
        return services.filter { service in
            service.date.flatMap { ServiceMenuLogic.parseISODate($0, calendar: calendar) }.map { $0 >= start } ?? false
        }.map(\.id)
    }

    public static func drive(ofFolder folder: String?) -> String? {
        folder?.split(separator: "/").first.map(String.init)
    }

    public static func firstSyncFolder(station: String, folder: String?) -> String {
        let name = station.trimmingCharacters(in: .whitespaces)
        guard let folder, !folder.isEmpty else { return name }
        return folder.hasPrefix(name + "/") || folder == name ? folder : "\(name)/\(folder)"
    }

    public static func referencedMedia(
        _ ids: Set<String>, held: (DocumentKind, String) -> Bool, inCloud: (DocumentKind, String) -> Bool
    ) -> (pull: [(kind: DocumentKind, id: String)], wanted: Set<String>) {
        var pull: [(kind: DocumentKind, id: String)] = []
        var wanted = Set<String>()
        for id in ids.sorted() where !held(.media, id) && !held(.audio, id) {
            if let kind = [DocumentKind.media, .audio].first(where: { inCloud($0, id) }) {
                pull.append((kind, id))
            } else {
                wanted.insert(id)
            }
        }
        return (pull, wanted)
    }
}

public enum SyncReconcileLogic {
    public enum Decision: Equatable, Sendable {
        case push
        case removeLocal
        case keep
    }

    public static func decision(entry: SyncLedger.Entry?, inCloud: Bool, localHeads: [String]?) -> Decision {
        guard let entry else { return inCloud ? .keep : .push }
        if inCloud { return entry.pending ? .push : .keep }
        if entry.lastPushedHeads.isEmpty { return .push }
        if let localHeads, localHeads != entry.lastPushedHeads { return .push }
        return .removeLocal
    }

    public static func afterTombstone(entry: SyncLedger.Entry?, localHeads: @autoclosure () -> [String]?) -> Decision {
        if let entry {
            let heads = localHeads()
            return heads != nil && heads != entry.lastPushedHeads ? .push : .removeLocal
        } else {
            return .keep
        }
    }
}
