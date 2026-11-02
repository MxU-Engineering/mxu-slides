import Foundation

public enum NoteSlides {
    public enum Resolution: Equatable, Sendable {
        case slide(presentation: Presentation, slide: Slide, index: Int)

        case missingPresentation

        case missingSlide(presentation: Presentation)

        case notPresenter
    }

    public static func resolve(
        _ ref: NoteSlideRef, presentation lookup: (String) -> Presentation?
    ) -> Resolution {
        guard let presentationId = ref.presentationId else { return .notPresenter }
        guard let presentation = lookup(presentationId) else { return .missingPresentation }
        if let slideId = ref.slideId,
           let index = presentation.slides.firstIndex(where: { $0.id == slideId }) {
            return .slide(presentation: presentation, slide: presentation.slides[index], index: index)
        }
        if let index = ref.slideIndex, presentation.slides.indices.contains(index) {
            return .slide(presentation: presentation, slide: presentation.slides[index], index: index)
        }
        return .missingSlide(presentation: presentation)
    }

    public static func blockIndex(ofLiveSlide slideId: String, in body: NoteBody) -> Int? {
        body.blocks.firstIndex { $0.type == .slideRef && $0.slide?.slideId == slideId }
    }
}

public extension NoteSlides {
    static func dropRef(
        presentationId: String, slideId: String, presentation lookup: (String) -> Presentation?
    ) -> NoteSlideRef? {
        guard let presentation = lookup(presentationId),
              let index = presentation.slides.firstIndex(where: { $0.id == slideId }) else { return nil }
        let slide = presentation.slides[index]
        var ref = NoteSlideRef(presentationId: presentationId, slideId: slideId, slideIndex: index)
        ref.presentationName = presentation.name
        ref.slideLabel = slide.name.isEmpty ? nil : slide.name
        let text = slide.objects.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        ref.slideText = text.isEmpty ? nil : text
        ref.showThumbnail = true
        ref.showText = false
        ref.showNotes = true
        ref.showLabels = true
        ref.showName = false
        ref.showNumber = true
        return ref
    }

    static func handRef(
        presentationId: String, slideId: String, presentation lookup: (String) -> Presentation?
    ) -> NoteSlideRef? {
        guard var ref = dropRef(presentationId: presentationId, slideId: slideId, presentation: lookup) else { return nil }
        ref.placedByHand = true
        return ref
    }
}

public extension NoteSlides {
    static let defaultMarker = "[slide]"

    static func markerBlockIndexes(in body: NoteBody, marker: String = defaultMarker) -> [Int] {
        body.blocks.indices.filter { isMarker(body.blocks[$0], marker: marker) }
    }

    static func isMarker(_ block: NoteBlock, marker: String) -> Bool {
        guard block.type == .paragraph else { return false }
        let text = NoteReading.text(of: block.runs).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare(marker) == .orderedSame { return true }

        return marker == defaultMarker && text.range(of: labelPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func inlineMarkerLabelLength(_ block: NoteBlock) -> Int? {
        guard block.type == .paragraph else { return nil }
        return inlineMarkerLabelLength(in: NoteReading.text(of: block.runs))
    }

    public static func inlineMarkerLabelLength(in text: String) -> Int? {
        guard let label = text.range(of: inlineLabelPattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rest = text[label.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, !(rest.hasPrefix("(") && rest.hasSuffix(")")) else { return nil }
        return text.distance(from: text.startIndex, to: label.upperBound)
    }

    static func startsSlide(_ block: NoteBlock) -> Bool {
        isMarker(block, marker: defaultMarker) || inlineMarkerLabelLength(block) != nil
    }

    private static let inlineLabelPattern = #"^\s*slides?(\s*#?\s*\d+)?\s*:\s*"#

    private static let labelPattern = #"^slides?(\s*#?\s*\d+)?\s*[:.\-–—]?(\s*\([^)]*\))?$"#

    static func placeSlides(
        at marker: String = defaultMarker, in body: NoteBody, from presentation: Presentation
    ) -> NoteBody {
        var slideIndex = 0
        var blocks = body.blocks
        for index in blocks.indices where isMarker(blocks[index], marker: marker) {
            guard slideIndex < presentation.slides.count else { break }
            let slide = presentation.slides[slideIndex]
            if let ref = dropRef(presentationId: presentation.id, slideId: slide.id, presentation: { _ in presentation }) {
                blocks[index] = NoteBlock(type: .slideRef, slide: ref)
            }
            slideIndex += 1
        }
        var placed = body
        placed.blocks = blocks
        placed.plainText = blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        return placed
    }
}
