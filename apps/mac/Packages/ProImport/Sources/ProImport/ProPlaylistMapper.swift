import Foundation
import PresenterCore

public struct ProPlaylistPresentationRef: Sendable, Equatable {
    public var absolutePath: String?
    public var relativePath: String?

    public init(absolutePath: String? = nil, relativePath: String? = nil) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
    }
}

public struct ProMappedService: Sendable {
    public var service: Service
    public var warnings: [String]
}

public struct ProMediaBinFolder: Sendable, Equatable {
    public var path: String
    public var wantIDs: [String]
}

public enum ProPlaylistMapper {

    public static func mapPresentationPlaylists(
        _ doc: RVData_PlaylistDocument,
        resolvePresentation: (ProPlaylistPresentationRef) -> String?
    ) -> (services: [ProMappedService], mediaWants: [ProMediaWant]) {
        var state = ProDocumentMapper.MapState()
        var services: [ProMappedService] = []

        for node in leafPlaylists(under: doc.rootNode) {
            var warnings: [String] = []
            var items: [ServiceItem] = []

            func append(_ item: RVData_PlaylistItem, depth: Int = 0) {
                guard depth < 4 else { return }
                let itemID = identity(item.uuid, fallbackPrefix: "item")
                switch item.itemType {
                case .header(let header):
                    items.append(ServiceItem(
                        id: itemID, itemKind: .header,
                        name: item.name.isEmpty ? "Header" : item.name, refId: "",
                        colorHex: header.hasColor ? ProDocumentMapper.hexColor(header.color) : nil
                    ))
                case .presentation(let presentation):
                    guard let presentationID = resolvePresentation(pathRef(presentation.documentPath)) else {
                        warnings.append("\"\(itemName(item, of: presentation))\" was not found in the import and was skipped")
                        return
                    }
                    let arrangement = presentation.arrangement.string.lowercased()
                    items.append(ServiceItem(
                        id: itemID, itemKind: .presentation,
                        name: itemName(item, of: presentation), refId: presentationID,
                        arrangementId: arrangement.isEmpty ? nil : arrangement
                    ))
                case .cue(let cue):
                    if let media = firstMediaElement(of: cue) {

                        items.append(ServiceItem(
                            id: itemID, itemKind: .media,
                            name: item.name.isEmpty ? cue.name : item.name,
                            refId: state.want(for: media)
                        ))
                    } else {
                        warnings.append("\"\(item.name)\" is a cue with no media and was skipped")
                    }
                case .placeholder(let placeholder):
                    append(placeholder.linkedData, depth: depth + 1)
                case .planningCenter(let planningCenter):
                    append(planningCenter.linkedData, depth: depth + 1)
                case nil:
                    warnings.append("\"\(item.name)\" carries no content and was skipped")
                }
            }
            for item in playlistItems(of: node) where !item.isHidden {
                append(item)
            }
            let service = Service(
                id: identity(node.uuid, fallbackPrefix: "service"),
                name: node.name.isEmpty ? "Imported Playlist" : node.name,

                serviceDate: "",
                items: items
            )
            services.append(ProMappedService(service: service, warnings: warnings))
        }
        return (services, state.wants)
    }

    public static func mapMediaBinFolders(
        _ doc: RVData_PlaylistDocument
    ) -> (folders: [ProMediaBinFolder], mediaWants: [ProMediaWant], warnings: [String]) {
        var state = ProDocumentMapper.MapState()
        var folders: [ProMediaBinFolder] = []
        var warnings: [String] = []
        for (node, path) in leafPlaylistPaths(under: doc.rootNode) {
            var wantIDs: [String] = []
            for item in playlistItems(of: node) where !item.isHidden {
                if case .cue(let cue) = item.itemType, let media = firstMediaElement(of: cue) {
                    wantIDs.append(state.want(for: media))
                } else {
                    warnings.append("media playlist \"\(path)\": \"\(item.name)\" is not a media item and was skipped")
                }
            }
            folders.append(ProMediaBinFolder(path: path, wantIDs: wantIDs))
        }
        return (folders, state.wants, warnings)
    }

    public static func replacingMediaIDs(
        _ service: Service, with map: [String: String], audioIDs: Set<String>
    ) -> (service: Service, warnings: [String]) {
        var service = service
        var warnings: [String] = []
        service.items = service.items.compactMap { item in
            var item = item
            guard item.refId.hasPrefix(ProDocumentMapper.placeholderPrefix) else { return item }
            guard let resolved = map[item.refId] else {
                warnings.append("\"\(item.name)\": its media file was not found — the item was dropped")
                return nil
            }
            item.refId = resolved
            if item.itemKind == .media, audioIDs.contains(resolved) { item.itemKind = .audio }
            return item
        }
        return (service, warnings)
    }

    static func leafPlaylists(under node: RVData_Playlist) -> [RVData_Playlist] {
        if case .items = node.childrenType { return [node] }
        var children = node.children
        if case .playlists(let array)? = node.childrenType {
            children.append(contentsOf: array.playlists)
        }
        if children.isEmpty {
            return node.type == .playlist ? [node] : []
        }
        return children.flatMap { leafPlaylists(under: $0) }
    }

    static func leafPlaylistPaths(under node: RVData_Playlist) -> [(node: RVData_Playlist, path: String)] {
        func walk(_ node: RVData_Playlist, above: [String]) -> [(node: RVData_Playlist, path: String)] {
            if case .items = node.childrenType {
                let name = node.name.isEmpty ? "Playlist" : node.name
                return [(node, (above + [name]).joined(separator: "/"))]
            }
            var children = node.children
            if case .playlists(let array)? = node.childrenType {
                children.append(contentsOf: array.playlists)
            }
            if children.isEmpty {
                let name = node.name.isEmpty ? "Playlist" : node.name
                return node.type == .playlist ? [(node, (above + [name]).joined(separator: "/"))] : []
            }
            let path = node.name.isEmpty ? above : above + [node.name]
            return children.flatMap { walk($0, above: path) }
        }
        var roots = node.children
        if case .playlists(let array)? = node.childrenType {
            roots.append(contentsOf: array.playlists)
        }
        if case .items = node.childrenType {
            return walk(node, above: [])
        }
        return roots.flatMap { walk($0, above: []) }
    }

    private static func playlistItems(of node: RVData_Playlist) -> [RVData_PlaylistItem] {
        guard case .items(let items)? = node.childrenType else { return [] }
        return items.items
    }

    private static func identity(_ uuid: RVData_UUID, fallbackPrefix: String) -> String {
        let raw = uuid.string.lowercased()
        return raw.isEmpty ? "\(fallbackPrefix)-\(UUID().uuidString.lowercased())" : raw
    }

    private static func itemName(_ item: RVData_PlaylistItem, of presentation: RVData_PlaylistItem.Presentation) -> String {
        if !item.name.isEmpty { return item.name }
        let path = pathRef(presentation.documentPath)
        let file = (path.relativePath ?? path.absolutePath).map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
        return file ?? "Presentation"
    }

    static func pathRef(_ url: RVData_URL) -> ProPlaylistPresentationRef {
        var ref = ProPlaylistPresentationRef()
        if case .absoluteString(let string)? = url.storage, !string.isEmpty {
            ref.absolutePath = URL(string: string)?.path
        }
        if case .local(let local)? = url.relativeFilePath, !local.path.isEmpty {
            ref.relativePath = local.path
        } else if case .relativePath(let path)? = url.storage, !path.isEmpty {
            ref.relativePath = path
        }
        return ref
    }

    static func firstMediaElement(of cue: RVData_Cue) -> RVData_Media? {
        for action in cue.actions {
            if case .media(let media)? = action.actionTypeData {
                return media.element
            }
        }
        return nil
    }
}
