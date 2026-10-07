import Foundation

public enum BackupSettings {
    static let fileName = "settings.plist"
    static let pendingKey = "backup.pendingSettings"

    static let portableKeys: Set<String> = [
        "keyboard.map", "midi.map", "midi.out.targets",
        "audio.mixes", "audio.fadeEnabled", "audio.fadeSeconds", "audio.crossfadeSeconds",
        "serviceControls.timers", "serviceControls.timerBoard",
        "serviceControls.moduleOrder", "serviceControls.hiddenModules",
        "serviceControls.clearAllIncludesAudio",
        "present.layouts", "present.activeLayoutID", "present.continuous",
        "transition.slide.kind", "transition.slide.duration",
        "transition.media.kind", "transition.media.duration",
        "transport.skipToEndOffset",
        "library.tabOrder", "library.hiddenTabs",
        "overlays.pinnedIDs", "mixer.stripColors",
        "confidence.nextSkipsBlankSlides",
        "lyricsImportThemeId", "messageNotesThemeId", "makeSlides.designMap",
    ]
    static let portablePrefixes = ["audio.mix.", "audio.playlist.", "audio.media."]

    public static func isPortable(_ key: String) -> Bool {
        portableKeys.contains(key) || portablePrefixes.contains { key.hasPrefix($0) }
    }

    public static func snapshot(defaults: UserDefaults = .standard) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { isPortable($0.key) }
    }

    public static func read(fromBundle bundleURL: URL) -> [String: Any] {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: bundleURL.appendingPathComponent(fileName)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            settings = dictionary.filter { isPortable($0.key) }
        }
        return settings
    }

    @discardableResult
    public static func stage(
        _ settings: [String: Any], policy: BackupConflictPolicy,
        defaults: UserDefaults = .standard
    ) -> Int {
        let landing = settings.filter { key, _ in
            isPortable(key) && (policy != .keepMine || defaults.object(forKey: key) == nil)
        }
        if !landing.isEmpty {
            let pending = (defaults.dictionary(forKey: pendingKey) ?? [:])
                .merging(landing) { _, new in new }
            defaults.set(pending, forKey: pendingKey)
        }
        return landing.count
    }

    public static func applyPending(defaults: UserDefaults = .standard) {
        if let pending = defaults.dictionary(forKey: pendingKey) {
            for (key, value) in pending where isPortable(key) {
                defaults.set(value, forKey: key)
            }
            defaults.removeObject(forKey: pendingKey)
        }
    }
}
