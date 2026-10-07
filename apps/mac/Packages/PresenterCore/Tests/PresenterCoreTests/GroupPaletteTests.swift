import Testing

@testable import PresenterCore

struct GroupPaletteTests {
    @Test func normalizationIgnoresCaseAndPunctuation() {
        #expect(GroupPalette.normalizedName("Pre-Chorus") == "prechorus")
        #expect(GroupPalette.normalizedName("PreChorus") == "prechorus")
        #expect(GroupPalette.normalizedName("pre chorus") == "prechorus")
        #expect(GroupPalette.normalizedName("Verse 1") == "verse1")
    }

    @Test func paletteWinsOverStampedColor() {
        let colors = GroupPalette.defaults.colorsByNormalizedName
        let imported = PresentationSection(id: "s1", name: "Chorus", colorHex: "#123456FF")
        #expect(imported.resolvedColorHex(paletteColors: colors) == "#CC004EFF")
    }

    @Test func unknownNameFallsBackToStampedColor() {
        let colors = GroupPalette.defaults.colorsByNormalizedName
        let custom = PresentationSection(id: "s1", name: "Garcia Moment", colorHex: "#123456FF")
        #expect(custom.resolvedColorHex(paletteColors: colors) == "#123456FF")
        let bare = PresentationSection(id: "s2", name: "Garcia Moment")
        #expect(bare.resolvedColorHex(paletteColors: colors) == nil)
    }

    @Test func defaultsMatchProPresenterStockColors() {
        let colors = GroupPalette.defaults.colorsByNormalizedName

        #expect(colors["verse"] == "#0077CCFF")
        #expect(colors["chorus"] == "#CC004EFF")
        #expect(colors["bridge"] == "#7600CCFF")
        #expect(colors["prechorus"] == "#CC298BFF")
        #expect(colors["tag"] == "#CC2929FF")
        #expect(colors["interlude"] == "#24B34CFF")

        #expect(colors["blank"] == "#000000FF")
    }

    @Test func firstDefinitionWinsOnNormalizedCollision() {
        let palette = GroupPalette(id: GroupPalette.wellKnownID, groups: [
            GroupDefinition(id: "a", name: "Pre-Chorus", colorHex: "#111111FF"),
            GroupDefinition(id: "b", name: "PreChorus", colorHex: "#222222FF"),
        ])
        #expect(palette.colorsByNormalizedName["prechorus"] == "#111111FF")
    }
}
