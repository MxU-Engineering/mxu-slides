import Foundation

public enum StreamDestinationLibrary {

    public static func displayName(_ destination: StreamDestination) -> String {
        destination.name.isEmpty ? destination.url : destination.name
    }

    public static func customKey(transport: StreamTransport, url: String, streamKey: String?) -> String {
        "\(transport.rawValue)|\(url.trimmingCharacters(in: .whitespaces))|\(streamKey ?? "")"
    }

    public static func hoisted(_ legacy: StreamPresetDestination) -> StreamDestination {
        StreamDestination(
            id: legacy.id, name: legacy.name, transport: legacy.transport, url: legacy.url,
            streamKey: legacy.streamKey, videoCodec: legacy.videoCodec, maxHeight: legacy.maxHeight,
            hdr: legacy.hdr, canvasScreenId: legacy.canvasScreenId, width: legacy.width,
            height: legacy.height, frameRate: legacy.frameRate)
    }

    public struct MigrationPlan: Equatable, Sendable {

        public var records: [StreamDestination] = []
        public var destinationIds: [String] = []
        public var kind: StreamPresetKind = .recordOnly

        public var dropped: [String] = []
        public init() {}
    }

    public static func plan(
        _ preset: StreamRecordPreset, existingCustomIDs: [String: String]
    ) -> MigrationPlan {
        var plan = MigrationPlan()
        var customIDs = existingCustomIDs
        for legacy in preset.destinations {
            if let problem = StreamDestinationReadiness.problem(legacy) {
                plan.dropped.append("\(preset.name): removed a destination that could not stream — \(problem)")
                continue
            }
            let record = hoisted(legacy)
            let key = customKey(transport: record.transport, url: record.url, streamKey: record.streamKey)
            if let existing = customIDs[key] {
                if !plan.destinationIds.contains(existing) { plan.destinationIds.append(existing) }
            } else {
                customIDs[key] = record.id
                plan.records.append(record)
                plan.destinationIds.append(record.id)
            }
        }

        plan.kind = preset.presetKind ?? (preset.destinations.isEmpty && (preset.destinationIds ?? []).isEmpty ? .recordOnly : .stream)
        return plan
    }

    public static func sessionDestination(_ destination: StreamDestination, displayName: String) -> StreamPresetDestination {
        StreamPresetDestination(
            id: destination.id,
            name: displayName,
            transport: destination.transport,
            url: destination.url,
            streamKey: destination.streamKey,
            videoCodec: destination.videoCodec,
            maxHeight: destination.maxHeight,
            hdr: destination.hdr,
            canvasScreenId: destination.canvasScreenId,
            width: destination.width,
            height: destination.height,
            frameRate: destination.frameRate)
    }
}

public extension StreamRecordPreset {

    var resolvedKind: StreamPresetKind {
        presetKind ?? ((destinationIds ?? []).isEmpty && destinations.isEmpty ? .recordOnly : .stream)
    }

    var isRecordOnly: Bool { resolvedKind == .recordOnly }
}

public extension Library {

    @discardableResult
    func migrateStreamDestinations() throws -> (presets: Int, dropped: [String]) {
        var existingCustomIDs: [String: String] = [:]
        for id in try store.ids(of: .streamDestination) {
            let record = try open(StreamDestination.self, id: id).value
            existingCustomIDs[StreamDestinationLibrary.customKey(
                transport: record.transport, url: record.url, streamKey: record.streamKey)] = record.id
        }
        var migrated = 0
        var dropped: [String] = []
        for id in try store.ids(of: .streamRecordPreset) {
            let document = try open(StreamRecordPreset.self, id: id)
            let preset = document.value
            guard !preset.destinations.isEmpty || preset.presetKind == nil else { continue }
            let plan = StreamDestinationLibrary.plan(preset, existingCustomIDs: existingCustomIDs)
            for record in plan.records {
                if (try? open(StreamDestination.self, id: record.id)) != nil { continue }
                _ = try create(record)
                existingCustomIDs[StreamDestinationLibrary.customKey(
                    transport: record.transport, url: record.url, streamKey: record.streamKey)] = record.id
            }
            try document.update { p in
                var ids = p.destinationIds ?? []
                for id in plan.destinationIds where !ids.contains(id) { ids.append(id) }
                p.destinationIds = ids
                p.presetKind = plan.kind
                p.destinations = []
            }
            try save(document)
            migrated += 1
            dropped.append(contentsOf: plan.dropped)
        }
        return (migrated, dropped)
    }
}
