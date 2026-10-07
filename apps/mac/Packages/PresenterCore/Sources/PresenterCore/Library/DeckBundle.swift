import Foundation

public struct DeckBundle: Sendable {
    public var presentation: Presentation

    public var stamp: DocumentFileStamp?

    public var themes: [String: Theme]

    public var media: [String: MediaItem]
    public var audio: [String: AudioItem]

    public var missingThemes: Set<String>
    public var missingMedia: Set<String>

    public var stamps: [SyncLedger.Key: DocumentFileStamp]

    public init(
        presentation: Presentation, stamp: DocumentFileStamp? = nil, themes: [String: Theme] = [:],
        media: [String: MediaItem] = [:], audio: [String: AudioItem] = [:],
        missingThemes: Set<String> = [], missingMedia: Set<String> = [],
        stamps: [SyncLedger.Key: DocumentFileStamp] = [:]
    ) {
        self.presentation = presentation
        self.stamp = stamp
        self.themes = themes
        self.media = media
        self.audio = audio
        self.missingThemes = missingThemes
        self.missingMedia = missingMedia
        self.stamps = stamps
    }

    public static func themeIds(in presentation: Presentation) -> Set<String> {
        var ids: Set<String> = [presentation.themeId]
        for slide in presentation.slides { ids.insert(presentation.themeId(for: slide)) }
        return ids.filter { !$0.isEmpty }
    }

    public static func mediaIds(in presentation: Presentation, themes: some Sequence<Theme>) -> Set<String> {
        var ids = MediaReferences.ids(in: presentation)
        for theme in themes { ids.formUnion(MediaReferences.ids(in: theme)) }
        return ids.filter { !$0.contains("::") }
    }
}

public struct DeckBundles: Sendable {
    public var bundles: [String: DeckBundle]
    public var failed: Set<String>

    public init(bundles: [String: DeckBundle] = [:], failed: Set<String> = []) {
        self.bundles = bundles
        self.failed = failed
    }
}

public protocol DeckBundleSource: Sendable {
    @concurrent
    func deckBundles(ids: [String], priority: TaskPriority?) async -> DeckBundles
}

extension LibraryReader: DeckBundleSource {

    @concurrent
    public func deckBundles(ids: [String], priority: TaskPriority? = nil) async -> DeckBundles {
        let decks = await loadStampedValues(Presentation.self, ids: ids, priority: priority)
        let themeIds = decks.values.values.reduce(into: Set<String>()) { $0.formUnion(DeckBundle.themeIds(in: $1.value)) }
        let themes = await loadStampedValues(Theme.self, ids: Array(themeIds), priority: priority)
        let mediaIds = decks.values.values.reduce(into: Set<String>()) { ids, deck in
            let used = DeckBundle.themeIds(in: deck.value).compactMap { themes.values[$0]?.value }
            ids.formUnion(DeckBundle.mediaIds(in: deck.value, themes: used))
        }
        let media = await loadStampedValues(MediaItem.self, ids: Array(mediaIds), priority: priority)
        let audio = await loadStampedValues(AudioItem.self, ids: Array(media.failed), priority: priority)

        var bundles: [String: DeckBundle] = [:]
        for (id, deck) in decks.values {
            var bundle = DeckBundle(presentation: deck.value, stamp: deck.stamp)
            for themeId in DeckBundle.themeIds(in: deck.value) {
                if let theme = themes.values[themeId] {
                    bundle.themes[themeId] = theme.value
                    bundle.stamps[SyncLedger.Key(kind: .theme, id: themeId)] = theme.stamp
                } else {
                    bundle.missingThemes.insert(themeId)
                }
            }
            for mediaId in DeckBundle.mediaIds(in: deck.value, themes: bundle.themes.values) {
                if let item = media.values[mediaId] {
                    bundle.media[mediaId] = item.value
                    bundle.stamps[SyncLedger.Key(kind: .media, id: mediaId)] = item.stamp
                } else if let item = audio.values[mediaId] {
                    bundle.audio[mediaId] = item.value
                    bundle.stamps[SyncLedger.Key(kind: .audio, id: mediaId)] = item.stamp
                } else {
                    bundle.missingMedia.insert(mediaId)
                }
            }
            bundles[id] = bundle
        }
        return DeckBundles(bundles: bundles, failed: decks.failed)
    }

    @concurrent
    public func deckBundle(id: String) async throws -> DeckBundle {
        if let bundle = await deckBundles(ids: [id]).bundles[id] {
            return bundle
        } else {
            throw DocumentStore.StoreError.documentNotFound(kind: .presentation, id: id)
        }
    }
}

extension LibraryClientFillSource: DeckBundleSource {
    @concurrent
    public func deckBundles(ids: [String], priority: TaskPriority?) async -> DeckBundles {
        if let reader = try? await reader() {
            await reader.deckBundles(ids: ids, priority: priority)
        } else {
            DeckBundles(failed: Set(ids))
        }
    }
}
