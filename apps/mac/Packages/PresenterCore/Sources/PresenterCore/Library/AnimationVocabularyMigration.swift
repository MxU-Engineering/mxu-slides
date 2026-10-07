import Foundation

public extension Library {
    @discardableResult
    func normalizeAnimationVocabulary() throws -> Int {
        var migrated = 0
        var ledger = (try? store.load(ImportLedger.self, id: ImportLedger.wellKnownID))?.value
            ?? ImportLedger(id: ImportLedger.wellKnownID, entries: [])
        var ledgerDirty = false

        func restamp<E: DocumentEntity>(_ type: E.Type, id: String, preHash: String?) {
            guard let preHash, ledger.value(for: id) == preHash,
                  let stored = try? open(E.self, id: id).value,
                  let postHash = ImportFingerprint.hash(stored)
            else { return }
            ledger.stamp(id, postHash)
            ledgerDirty = true
        }

        for id in try store.ids(of: .presentation) {
            let document = try open(Presentation.self, id: id)
            guard document.value.slides.contains(where: SlideObjectNormalization.needsNormalization)
            else { continue }
            let preHash = ImportFingerprint.hash(document.value)
            try document.update { presentation in
                presentation.slides = presentation.slides.map(SlideObjectNormalization.normalized)
            }
            try save(document)
            restamp(Presentation.self, id: id, preHash: preHash)
            migrated += 1
        }
        for id in try store.ids(of: .theme) {
            let document = try open(Theme.self, id: id)
            guard document.value.slides?.contains(where: SlideObjectNormalization.needsNormalization) == true
            else { continue }
            let preHash = ImportFingerprint.hash(document.value)
            try document.update { theme in
                theme.slides = theme.slides.map { $0.map(SlideObjectNormalization.normalized) }
            }
            try save(document)
            restamp(Theme.self, id: id, preHash: preHash)
            migrated += 1
        }
        for id in try store.ids(of: .overlay) {
            let document = try open(Overlay.self, id: id)
            guard SlideObjectNormalization.needsNormalization(document.value) else { continue }
            let preHash = ImportFingerprint.hash(document.value)
            try document.update { overlay in
                overlay = SlideObjectNormalization.normalized(overlay)
            }
            try save(document)
            restamp(Overlay.self, id: id, preHash: preHash)
            migrated += 1
        }
        for id in try store.ids(of: .confidenceLayout) {
            let document = try open(ConfidenceLayout.self, id: id)
            guard SlideObjectNormalization.needsNormalization(document.value) else { continue }
            let preHash = ImportFingerprint.hash(document.value)
            try document.update { layout in
                layout = SlideObjectNormalization.normalized(layout)
            }
            try save(document)
            restamp(ConfidenceLayout.self, id: id, preHash: preHash)
            migrated += 1
        }

        migrated += migrateAnimationPresetBoard()

        if ledgerDirty {
            let entries = ledger.entries
            if let document = try? store.load(ImportLedger.self, id: ImportLedger.wellKnownID) {
                try? document.update { $0.entries = entries }
                try? store.save(document)
            } else {
                try? store.save(TypedDocument(ledger))
            }
        }
        return migrated
    }

    private func migrateAnimationPresetBoard() -> Int {
        let legacyDir = store.rootURL.appendingPathComponent("build-presets", isDirectory: true)
        let legacyURL = legacyDir
            .appendingPathComponent("build-preset-board")
            .appendingPathExtension("automerge")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let legacy = try? TypedDocument<AnimationPresetBoard>(data: data)
        else { return 0 }
        if let document = try? store.load(
            AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID
        ) {
            let existing = Set(document.value.presets.map(\.id))
            let extras = legacy.value.presets.filter { !existing.contains($0.id) }
            if !extras.isEmpty {
                try? document.update { $0.presets += extras }
                try? store.save(document)
            }
        } else {
            try? store.save(TypedDocument(AnimationPresetBoard(
                id: AnimationPresetBoard.wellKnownID, presets: legacy.value.presets
            )))
        }
        try? FileManager.default.removeItem(at: legacyURL)
        if let leftover = try? FileManager.default.contentsOfDirectory(atPath: legacyDir.path),
           leftover.isEmpty {
            try? FileManager.default.removeItem(at: legacyDir)
        }
        return 1
    }
}
