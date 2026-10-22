import Foundation
import Testing

@Suite struct SettingsWordingSweepTests {

    private static let pairs: [(settings: String, quick: String, file: String)] = [
        ("Slides across", "Slides Across", "AppShell.swift"),
        ("Continuous service view", "Continuous Service View", "AppShell.swift"),
        ("Rounded corners", "Rounded Corners", "AppShell.swift"),
        ("Transparency grid", "Transparency Grid", "AppShell.swift"),
        ("Backgrounds only on declaring slide", "Backgrounds Only on Declaring Slide", "AppShell.swift"),
        ("Fade in and out", "Fade in and out", "AudioModule.swift"),
    ]

    @Test func quickControlsUseTheSettingsWords() throws {
        let sweep = try SourceSweep.app()
        let settings = try #require(sweep.file("SettingsView.swift")).text
        for pair in Self.pairs {
            #expect(pair.settings.lowercased() == pair.quick.lowercased(), "\(pair.settings) vs \(pair.quick)")
            #expect(settings.contains("title: \"\(pair.settings)\""), "Settings row \(pair.settings)")
            let quick = try #require(sweep.file(pair.file)).text
            #expect(quick.contains("\"\(pair.quick)\""), "\(pair.file): \(pair.quick)")
        }
    }

    @Test func captionsPointAtPlacesThatExist() throws {
        let sweep = try SourceSweep.app()
        for file in sweep.files {
            #expect(!file.text.contains("Settings › Transitions"), "\(file.name)")
        }
        let settings = try #require(sweep.file("SettingsView.swift")).text
        #expect(!settings.contains("The footer chips"))
    }

    @Test func updatesRowStandsOnItsOwn() throws {
        let file = try #require(SourceSweep.app().file("SettingsView.swift"))
        let start = try #require(file.lines.firstIndex { $0.contains("private var apiRows") })
        let block = file.block(from: start)
        #expect(!file.lines[block].joined().contains("updates.automatic"))
        #expect(file.text.contains("rows.append(contentsOf: updatesRows)"))
    }
}
