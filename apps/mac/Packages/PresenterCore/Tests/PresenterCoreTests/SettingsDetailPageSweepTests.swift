import Foundation
import Testing

@Suite struct SettingsDetailPageSweepTests {
    private static let pages: [(file: String, type: String)] = [
        ("SettingsPanes.swift", "VideoInputDetail"),
        ("SettingsPanes.swift", "AudioInputDetail"),
        ("SettingsPanes.swift", "AudioOutputDetail"),
        ("SettingsPanes.swift", "MIDIDeviceDetail"),
        ("StreamRecordPane.swift", "DestinationDetail"),
        ("StreamRecordPane.swift", "PresetDetail"),
    ]

    private func body(_ file: String, _ type: String) throws -> [String] {
        let source = try #require(SourceSweep.app().file(file))
        let declaration = try #require(source.typeDeclarations.first { $0.name == type }, "\(type)")
        return Array(source.lines[declaration.lines])
    }

    @Test func removeOrDeleteIsTheLastSection() throws {
        for page in Self.pages {
            let lines = try body(page.file, page.type)
            let formEnd = try #require(lines.firstIndex { $0.contains(".settingsForm()") || $0.contains(".formStyle(.grouped)") }, "\(page.type)")
            let lastSection = try #require(lines[..<formEnd].lastIndex { $0.contains("Section {") || $0.contains("Section(") }, "\(page.type)")
            #expect(lines[lastSection..<formEnd].joined().contains("role: .destructive"), "\(page.type): Remove / Delete sits alone at the bottom")
        }
    }

    @Test func noParagraphsUnderTheForm() throws {
        for page in Self.pages {
            let lines = try body(page.file, page.type)
            for (index, line) in lines.enumerated() where line.contains("footer: {") {
                let footer = lines[index...].prefix(6).joined()
                let texts = footer.matches(of: /Text\("([^"]*)"\)/).map(\.output.1)
                #expect(texts.allSatisfy { $0.count <= 80 }, "\(page.type): a footer is one short line; the rest goes on hover")
            }
        }
    }

    @Test func inputsAndOutputsSayWhatTheyreConnectedTo() throws {
        for type in ["VideoInputDetail", "AudioInputDetail", "AudioOutputDetail", "MIDIDeviceDetail"] {
            #expect(try body("SettingsPanes.swift", type).joined().contains("Connected to"), "\(type)")
        }
    }

    @Test func advancedStartsClosedAndRowsHaveNoInlineMenus() throws {
        let destination = try body("StreamRecordPane.swift", "DestinationDetail").joined(separator: "\n")
        #expect(destination.contains("advancedOpen.toggle()") && destination.contains("if advancedOpen {"))
        #expect(destination.contains("@State private var advancedOpen = false"))
        let presets = try body("StreamRecordPane.swift", "PresetsList").joined(separator: "\n")
        #expect(!presets.contains("ellipsis.circle\").foregroundStyle"), "a preset row's verbs are its right-click")
        #expect(presets.contains("Button(\"Delete Preset\\u{2026}\", role: .destructive) { deletingPresetID = id }"))
    }
}
