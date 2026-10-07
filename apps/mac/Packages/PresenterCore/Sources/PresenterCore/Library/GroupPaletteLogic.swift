import Foundation

public extension GroupPalette {

    static var defaults: GroupPalette {
        GroupPalette(id: wellKnownID, groups: [
            GroupDefinition(id: "verse", name: "Verse", colorHex: "#0077CCFF"),
            GroupDefinition(id: "verse-1", name: "Verse 1", colorHex: "#0077CCFF"),
            GroupDefinition(id: "verse-2", name: "Verse 2", colorHex: "#005999FF"),
            GroupDefinition(id: "verse-3", name: "Verse 3", colorHex: "#003C66FF"),
            GroupDefinition(id: "verse-4", name: "Verse 4", colorHex: "#0068B3FF"),
            GroupDefinition(id: "verse-5", name: "Verse 5", colorHex: "#004A80FF"),
            GroupDefinition(id: "verse-6", name: "Verse 6", colorHex: "#002D4DFF"),
            GroupDefinition(id: "chorus", name: "Chorus", colorHex: "#CC004EFF"),
            GroupDefinition(id: "chorus-1", name: "Chorus 1", colorHex: "#CC004EFF"),
            GroupDefinition(id: "chorus-2", name: "Chorus 2", colorHex: "#99003BFF"),
            GroupDefinition(id: "chorus-3", name: "Chorus 3", colorHex: "#660027FF"),
            GroupDefinition(id: "chorus-4", name: "Chorus 4", colorHex: "#B30044FF"),
            GroupDefinition(id: "bridge", name: "Bridge", colorHex: "#7600CCFF"),
            GroupDefinition(id: "bridge-1", name: "Bridge 1", colorHex: "#7600CCFF"),
            GroupDefinition(id: "bridge-2", name: "Bridge 2", colorHex: "#590099FF"),
            GroupDefinition(id: "bridge-3", name: "Bridge 3", colorHex: "#3B0066FF"),
            GroupDefinition(id: "pre-chorus", name: "Pre-Chorus", colorHex: "#CC298BFF"),
            GroupDefinition(id: "tag", name: "Tag", colorHex: "#CC2929FF"),
            GroupDefinition(id: "intro", name: "Intro", colorHex: "#B3A724FF"),
            GroupDefinition(id: "ending", name: "Ending", colorHex: "#998F1FFF"),
            GroupDefinition(id: "outro", name: "Outro", colorHex: "#7E7619FF"),
            GroupDefinition(id: "interlude", name: "Interlude", colorHex: "#24B34CFF"),
            GroupDefinition(id: "vamp", name: "Vamp", colorHex: "#24B34CFF"),
            GroupDefinition(id: "turnaround", name: "Turnaround", colorHex: "#24B34CFF"),

            GroupDefinition(id: "blank", name: "Blank", colorHex: "#000000FF"),
        ])
    }

    static func normalizedName(_ name: String) -> String {
        String(name.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }).lowercased()
    }

    var colorsByNormalizedName: [String: String] {
        var table: [String: String] = [:]
        for group in groups {

            let key = GroupPalette.normalizedName(group.name)
            if table[key] == nil { table[key] = group.colorHex }
        }
        return table
    }
}

public extension PresentationSection {

    func resolvedColorHex(paletteColors: [String: String]) -> String? {
        paletteColors[GroupPalette.normalizedName(name)] ?? colorHex
    }
}
