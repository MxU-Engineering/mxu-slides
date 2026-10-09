import Foundation

public extension SlideBuildingSettings {

    static let designMapDefaultsKey = "makeSlides.designMap"
    static let messageNotesThemeDefaultsKey = "messageNotesThemeId"
    static let lyricsImportThemeDefaultsKey = "lyricsImportThemeId"

    static func fromDefaults(_ defaults: UserDefaults) -> SlideBuildingSettings {
        let map = defaults.data(forKey: designMapDefaultsKey).flatMap { String(data: $0, encoding: .utf8) }
        return SlideBuildingSettings(
            id: wellKnownID,
            designMap: map.flatMap { $0.isEmpty ? nil : $0 },
            messageNotesThemeId: defaults.string(forKey: messageNotesThemeDefaultsKey).flatMap { $0.isEmpty ? nil : $0 },
            lyricsImportThemeId: defaults.string(forKey: lyricsImportThemeDefaultsKey).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func effective(document: SlideBuildingSettings?, defaults: SlideBuildingSettings) -> SlideBuildingSettings {
        document ?? defaults
    }

    var isUnset: Bool {
        designMap == nil && messageNotesThemeId == nil && lyricsImportThemeId == nil && lyricsImportDesign == nil
    }

    var lyricsDesign: String {
        lyricsImportDesign.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultLyricsDesign
    }

    static let defaultLyricsDesign = "Lyrics"

    mutating func setLyricsLook(themeId: String, design: String?) {
        let themeChanged = themeId != (lyricsImportThemeId ?? "")
        lyricsImportThemeId = themeId.isEmpty ? nil : themeId
        if let design {
            lyricsImportDesign = design.isEmpty || themeId.isEmpty ? nil : design
        } else if themeChanged {
            lyricsImportDesign = nil
        }
    }

    mutating func fillUnset(from own: SlideBuildingSettings) {
        if designMap == nil { designMap = own.designMap }
        if messageNotesThemeId == nil { messageNotesThemeId = own.messageNotesThemeId }
        if lyricsImportThemeId == nil { lyricsImportThemeId = own.lyricsImportThemeId }
        if lyricsImportDesign == nil { lyricsImportDesign = own.lyricsImportDesign }
    }
}

public enum SlideBuildingSeed {
    public enum Step: Equatable, Sendable {

        case none

        case adopt

        case seed
    }

    public static func step(held: Bool, indexLoaded: Bool, inCloud: Bool, own: SlideBuildingSettings) -> Step {
        if held || !indexLoaded {
            .none
        } else if inCloud {
            .adopt
        } else if own.isUnset {
            .none
        } else {
            .seed
        }
    }
}
