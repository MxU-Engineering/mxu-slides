import Foundation

public extension Library {
    @discardableResult
    func normalizeMediaObjects() throws -> Int {
        var migrated = 0
        for id in try store.ids(of: .presentation) {
            let document = try open(Presentation.self, id: id)
            guard document.value.slides.contains(where: slideNeedsNormalization) else { continue }
            try document.update { presentation in
                for index in presentation.slides.indices {
                    presentation.slides[index].objects =
                        SlideObjectNormalization.normalized(presentation.slides[index].objects)
                }
            }
            try save(document)
            migrated += 1
        }
        for id in try store.ids(of: .theme) {
            let document = try open(Theme.self, id: id)
            guard document.value.slides?.contains(where: slideNeedsNormalization) == true else { continue }
            try document.update { theme in
                guard var slides = theme.slides else { return }
                for index in slides.indices {
                    slides[index].objects = SlideObjectNormalization.normalized(slides[index].objects)
                }
                theme.slides = slides
            }
            try save(document)
            migrated += 1
        }
        for id in try store.ids(of: .overlay) {
            let document = try open(Overlay.self, id: id)
            guard document.value.objects.contains(where: SlideObjectNormalization.needsNormalization)
            else { continue }
            try document.update { overlay in
                overlay.objects = SlideObjectNormalization.normalized(overlay.objects)
            }
            try save(document)
            migrated += 1
        }
        for id in try store.ids(of: .confidenceLayout) {
            let document = try open(ConfidenceLayout.self, id: id)
            guard document.value.objects.contains(where: SlideObjectNormalization.needsNormalization)
            else { continue }
            try document.update { layout in
                layout.objects = SlideObjectNormalization.normalized(layout.objects)
            }
            try save(document)
            migrated += 1
        }
        return migrated
    }
}

private func slideNeedsNormalization(_ slide: Slide) -> Bool {
    slide.objects.contains(where: SlideObjectNormalization.needsNormalization)
}
