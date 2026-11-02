import Foundation

public enum NoteDeckCards {
    public static func unplaced(deck: Presentation, in body: NoteBody) -> [Slide] {
        let carded = Set(body.blocks.compactMap { block -> String? in
            guard block.type == .slideRef, let slide = block.slide, slide.presentationId == deck.id else { return nil }
            return slide.slideId
        })
        return deck.slides.filter { !carded.contains($0.id) }
    }

    public static func syncing(deck: Presentation, added: Set<String>, removed: Set<String>, in body: NoteBody) -> NoteBody {
        var blocks = body.blocks
        var changed = false

        if !removed.isEmpty {
            let before = blocks.count
            blocks.removeAll { block in
                guard let slide = block.slide, block.type == .slideRef, slide.presentationId == deck.id,
                      slide.placedByHand == true, let id = slide.slideId else { return false }
                return removed.contains(id)
            }
            changed = blocks.count != before
        }

        func cardIndexes(of slideId: String) -> [Int] {
            blocks.indices.filter { blocks[$0].type == .slideRef && blocks[$0].slide?.presentationId == deck.id && blocks[$0].slide?.slideId == slideId }
        }

        for (index, slide) in deck.slides.enumerated() where added.contains(slide.id) {
            guard cardIndexes(of: slide.id).isEmpty,
                  let ref = NoteSlides.handRef(presentationId: deck.id, slideId: slide.id, presentation: { _ in deck })
            else { continue }
            let card = NoteBlock(type: .slideRef, slide: ref)
            if let anchor = deck.slides[..<index].reversed().lazy.compactMap({ cardIndexes(of: $0.id).last }).first {
                blocks.insert(card, at: anchor + 1)
            } else if let first = blocks.firstIndex(where: { $0.type == .slideRef && $0.slide?.presentationId == deck.id }) {
                blocks.insert(card, at: first)
            } else {
                blocks.append(card)
            }
            changed = true
        }

        guard changed else { return body }
        var synced = body
        synced.blocks = blocks
        synced.plainText = blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        return synced
    }
}
