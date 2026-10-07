import Foundation
import PresenterCore
import RenderEngine

extension SlideSceneBuilder {

    public typealias MediaFacts = (kind: MediaKind, classification: MediaClassification)

    public static func carriedMedia(
        for slide: Slide,
        presentation: Presentation?,
        arrangementId: String? = nil,
        item: (String) -> MediaFacts?
    ) -> [LayerKind: String] {
        var live: [LayerKind: CueMedia] = [:]
        let sequence = presentation.map { arrangedSlides(for: $0, arrangementId: arrangementId) } ?? []
        let walk: [Slide] = if let index = sequence.firstIndex(where: { $0.id == slide.id }) {
            Array(sequence[...index])
        } else {
            [slide]
        }

        let sources = presentation.map { backgroundSources(for: $0, arrangementId: arrangementId) } ?? [:]
        let deckIDs = Set(presentation?.slides.map(\.id) ?? [])
        for fired in walk {
            let background = if deckIDs.contains(fired.id) {
                sources[fired.id]?.media
            } else {
                effectiveBackground(slide: fired, presentation: presentation, arrangementId: arrangementId)
            }
            simulateFire(of: fired, background: background, item: item, live: &live)
        }
        return live.compactMapValues { $0.mediaId.isEmpty ? nil : $0.mediaId }
    }

    public static func carriedMediaMap(
        for presentation: Presentation,
        arrangementId: String? = nil,
        item: (String) -> MediaFacts?
    ) -> [String: [LayerKind: String]] {
        let sources = backgroundSources(for: presentation, arrangementId: arrangementId)
        var result: [String: [LayerKind: String]] = [:]
        var live: [LayerKind: CueMedia] = [:]
        for fired in arrangedSlides(for: presentation, arrangementId: arrangementId) {
            simulateFire(of: fired, background: sources[fired.id]?.media, item: item, live: &live)
            if result[fired.id] == nil {
                result[fired.id] = live.compactMapValues { $0.mediaId.isEmpty ? nil : $0.mediaId }
            }
        }
        for slide in presentation.slides where result[slide.id] == nil {
            var alone: [LayerKind: CueMedia] = [:]
            simulateFire(of: slide, background: sources[slide.id]?.media, item: item, live: &alone)
            result[slide.id] = alone.compactMapValues { $0.mediaId.isEmpty ? nil : $0.mediaId }
        }
        return result
    }

    private static func simulateFire(
        of slide: Slide,
        background: CueMedia?,
        item: (String) -> MediaFacts?,
        live: inout [LayerKind: CueMedia]
    ) {
        let backgroundLayer = background.map { layerKind($0.layer) }
        let actions = slide.actions ?? []

        for layer in [LayerKind.videos, .stillGraphics] where backgroundLayer != layer {
            if let cue = live[layer], cue.resolvedClassification == .foreground,
               !(layer == .stillGraphics && actions.contains { $0.kind == .fireMedia && $0.mediaId == cue.mediaId }) {
                live[layer] = nil
            }
        }
        if let background, let backgroundLayer {
            live[backgroundLayer] = background
        }
        let protected = protectedLayers(for: slide) { id in
            item(id).map { layerKind(CueMedia.firedLayer(kind: $0.kind, classification: $0.classification)) }
        }
        for action in fireActions(for: slide, protected: protected) where !waitsBeforeFiring(action) {
            switch action.kind {
            case .fireMedia:
                if let id = action.mediaId, let facts = item(id) {
                    let layer = layerKind(CueMedia.firedLayer(kind: facts.kind, classification: facts.classification))
                    live[layer] = CueMedia(mediaId: id, classification: facts.classification)
                }
            case .clearLayer:
                if let layer = action.layer.flatMap(LayerKind.init(rawValue:)) {
                    live[layer] = nil
                }
            case .clearAll:
                for layer in live.keys where !protected.contains(layer) {
                    live[layer] = nil
                }
            default:
                break
            }
        }
    }
}
