import Foundation
import Testing
@testable import PresenterCore

private func item(_ kind: MediaKind, _ classification: MediaClassification) -> MediaItem {
    MediaItem(
        id: "m1", name: "Item", mediaKind: kind, classification: classification,
        fileHash: "abc123", fileName: "item.bin", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: false
    )
}

@Test func backgroundStillRoutesToBackgroundMedia() {
    let media = CueMedia.dropped(for: item(.image, .background))
    #expect(media.layer == .loopingVideos, "a background still replaces/persists like a background video")
    #expect(media.mode == .untilReplaced)
}

@Test func foregroundStillRoutesToStillGraphicsSlideScoped() {
    let media = CueMedia.dropped(for: item(.image, .foreground))
    #expect(media.layer == .stillGraphics)
    #expect(media.mode == nil, "foreground media is slide-scoped, never until-replaced")
}

@Test func videoRoutingUnchangedByTheRevision() {
    let background = CueMedia.dropped(for: item(.video, .background))
    #expect(background.layer == .loopingVideos)
    #expect(background.mode == .untilReplaced)
    let foreground = CueMedia.dropped(for: item(.video, .foreground))
    #expect(foreground.layer == .videos)
    #expect(foreground.mode == nil)
}

@Test func dropOnSlideIsABackgroundWhateverTheLibrarySays() {
    let media = CueMedia.droppedOnSlide(for: item(.video, .foreground))
    #expect(media.layer == .loopingVideos)
    #expect(media.mode == .untilReplaced)
    #expect(media.loops == true, "on-slide drops loop by default")
    #expect(media.classification == .background, "stamped, so the layer never decides")
    let still = CueMedia.droppedOnSlide(for: item(.image, .foreground))
    #expect(still.layer == .loopingVideos)
    #expect(still.loops == nil, "looping means nothing for a still")
}

@Test func dropBetweenSlidesIsForegroundWhateverTheLibrarySays() {
    let media = CueMedia.droppedAsNewSlide(for: item(.video, .background))
    #expect(media.layer == .videos)
    #expect(media.mode == nil, "slide-scoped: the next fire sweeps it")
    #expect(media.loops == false, "a new-slide video plays once")
    #expect(media.classification == .foreground)
    let still = CueMedia.droppedAsNewSlide(for: item(.image, .background))
    #expect(still.layer == .stillGraphics)
    #expect(still.loops == nil)
    #expect(still.classification == .foreground, "a foreground still on Still Graphics")
}

@Test func unstampedCuesReadTheirClassificationByLayer() {

    #expect(CueMedia(mediaId: "m", layer: .videos).resolvedClassification == .foreground)
    #expect(CueMedia(mediaId: "m", layer: .stillGraphics).resolvedClassification == .background)
    #expect(CueMedia(mediaId: "m", layer: .loopingVideos).resolvedClassification == .background)
    #expect(CueMedia(mediaId: "m").resolvedClassification == .background)
    let stamped = CueMedia(mediaId: "m", layer: .stillGraphics, classification: .foreground)
    #expect(stamped.resolvedClassification == .foreground, "the stamp outranks the layer")
    #expect(CueMedia.dropped(for: item(.image, .foreground)).classification == .foreground, "fires carry the item's own")
}

@Test func firedLayerMatchesDroppedRouting() {
    for kind in MediaKind.allCases {
        for classification in MediaClassification.allCases {
            #expect(CueMedia.firedLayer(kind: kind, classification: classification) == CueMedia.dropped(for: item(kind, classification)).layer)
        }
    }
}
