import Foundation

public struct LibraryRefile: Sendable, Equatable {
    public var kind: DocumentKind
    public var id: String
    public var folder: String?
    public var folderId: String?

    public init(kind: DocumentKind, id: String, folder: String?, folderId: String?) {
        self.kind = kind
        self.id = id
        self.folder = folder
        self.folderId = folderId
    }

    public var key: SyncLedger.Key { SyncLedger.Key(kind: kind, id: id) }

    static let folderKey = "folder"
    static let folderIdKey = "folderId"

    func applied(to value: any TeamFolderedEntity & DocumentEntity) -> any DocumentEntity {
        var next = value
        next.folder = folder
        next.folderId = folderId
        return next
    }
}

extension LibraryEngine {

    public struct Refiled: Sendable {
        public let batch: LibraryBatch
        public let refused: [SyncLedger.Key: any Error]
    }

    @discardableResult
    public func refile(_ refiles: [LibraryRefile], origin: ChangeOrigin = .local) throws -> Refiled {
        var refused: [SyncLedger.Key: any Error] = [:]
        let batch = try publishing {
            for refile in refiles {
                do {
                    try refileDocument(refile, origin: origin)
                } catch {
                    refused[refile.key] = error
                }
            }
        }
        return Refiled(batch: batch, refused: refused)
    }

    private func refileDocument(_ refile: LibraryRefile, origin: ChangeOrigin) throws {
        switch refile.kind {
        case .presentation: try refileDocument(Presentation.self, refile, origin: origin)
        case .overlay: try refileDocument(Overlay.self, refile, origin: origin)
        case .media: try refileDocument(MediaItem.self, refile, origin: origin)
        case .audio: try refileDocument(AudioItem.self, refile, origin: origin)
        case .confidenceLayout: try refileDocument(ConfidenceLayout.self, refile, origin: origin)

        default: break
        }
    }

    private func refileDocument<E: TeamFolderedEntity & DocumentEntity>(
        _ type: E.Type, _ refile: LibraryRefile, origin: ChangeOrigin
    ) throws {
        let document = try replica(type, id: refile.id)
        do {
            try document.updateFields([
                .init(\E.folder, key: LibraryRefile.folderKey, to: refile.folder),
                .init(\E.folderId, key: LibraryRefile.folderIdKey, to: refile.folderId),
            ])
        } catch {

            dropReplica(kind: E.documentKind, id: refile.id)
            throw error
        }
        try persist(document, origin: origin)
    }
}

extension LibraryClient {

    public static let refileChunkSize = 25

    @discardableResult
    public func refile(_ refiles: [LibraryRefile]) -> Task<LibraryEngine.Refiled, any Error> {
        let changes = refiles.compactMap(optimisticRefile)
        for change in changes {
            readSide?.applyOptimistic(change)
        }
        let command = enqueue(nil) { [engine] in try engine.refile(refiles) }
        if !changes.isEmpty {
            Task { [weak self] in
                switch await command.result {
                case .success(let refiled):
                    for change in changes {
                        if let error = refiled.refused[change.key] {
                            self?.readSide?.optimisticWriteFailed(change, error: error)
                        }
                    }
                case .failure(let error):
                    for change in changes {
                        self?.readSide?.optimisticWriteFailed(change, error: error)
                    }
                }
            }
        }
        return command
    }

    private func optimisticRefile(_ refile: LibraryRefile) -> DocumentChange? {
        if let value = readSide?.currentValue(refile.kind, id: refile.id) as? any TeamFolderedEntity & DocumentEntity {
            DocumentChange(kind: refile.kind, id: refile.id, origin: .local, value: refile.applied(to: value))
        } else {
            nil
        }
    }
}
