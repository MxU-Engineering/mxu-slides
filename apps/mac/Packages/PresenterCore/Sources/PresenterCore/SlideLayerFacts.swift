import Foundation

extension CueMedia {

    public var storedRoutingLayerId: String? {
        if let layerId, !layerId.isEmpty { layerId } else { layer?.rawValue }
    }

    public func defaultLayer(kind: MediaKind) -> CueMediaLayer {
        Self.firedLayer(kind: kind, classification: resolvedClassification)
    }

    public mutating func setRoutingLayer(_ id: String?) {
        if let id, !id.isEmpty {
            if let builtIn = CueMediaLayer(rawValue: id) {
                layer = builtIn
                layerId = nil
            } else {
                layer = nil
                layerId = id
            }
        } else {
            layer = nil
            layerId = nil
        }
    }
}

extension OutputPreset {

    @discardableResult
    public mutating func addLayer(named name: String, id: String = UUID().uuidString) -> CustomLayer {
        let layer = CustomLayer(id: id, name: name, above: "slide")
        layers = (layers ?? []) + [layer]
        for index in assignments.indices where !assignments[index].enabledLayers.contains(id) {
            assignments[index].enabledLayers = (assignments[index].enabledLayers + [id]).sorted()
        }
        return layer
    }

    public mutating func removeLayer(id: String) {
        layers?.removeAll { $0.id == id }
        if layers?.isEmpty == true { layers = nil }
        for index in assignments.indices {
            assignments[index].enabledLayers.removeAll { $0 == id }
        }
        placements?.removeAll { $0.layerId == id }
        if placements?.isEmpty == true { placements = nil }
    }
}

public enum SlideLayerFacts {
    public struct Chip: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case layer
            case preset
        }

        public var kind: Kind
        public var id: String

        public var label: String

        public var targetId: String

        public var itemName: String
    }

    public static func chips(
        for slide: Slide,
        item: (String) -> (name: String, kind: MediaKind)?,
        layerName: (String) -> String?,
        presetName: (String) -> String?
    ) -> [Chip] {
        var chips: [Chip] = []
        if let cue = slide.background, let stored = cue.storedRoutingLayerId,
           let item = item(cue.mediaId),
           stored != cue.defaultLayer(kind: item.kind).rawValue,
           let name = layerName(stored) {
            chips.append(Chip(
                kind: .layer, id: "layer:\(cue.mediaId)", label: name,
                targetId: stored, itemName: item.name))
        }

        if let action = (slide.actions ?? []).last(where: {
            $0.kind == .switchOutputPreset && !($0.presetId?.isEmpty ?? true)
        }), let presetID = action.presetId {
            chips.append(Chip(
                kind: .preset, id: "preset:\(presetID)",
                label: "→ \(presetName(presetID) ?? "Preset")",
                targetId: presetID, itemName: ""))
        }
        return chips
    }
}
