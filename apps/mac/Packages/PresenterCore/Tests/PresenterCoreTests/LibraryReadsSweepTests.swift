import Foundation
import Testing

@testable import PresenterCore

@Suite struct LibraryReadsSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func swiftFiles() throws -> [URL] {
        let all = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "app sources not found at \(appSources.path)")
        return files
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    private func body(of signature: String, in text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try #require(lines.firstIndex { $0.contains(signature) }, "\(signature) expected")
        var depth = 0
        var started = false
        var cursor = start
        var collected: [String] = []
        while cursor < lines.count {
            collected.append(lines[cursor])
            for character in lines[cursor] {
                if character == "{" { depth += 1; started = true }
                if character == "}" { depth -= 1 }
            }
            if started, depth <= 0 { break }
            cursor += 1
        }
        return collected.joined(separator: "\n")
    }

    private let oldLibraryReads = ["LibraryReads", "library.index", "library.open(", "library.store"]

    @Test func noFileReadsTheOldLibrary() throws {
        var violations: [String] = []
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if oldLibraryReads.contains(where: { code.contains($0) }) {
                    violations.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(violations.isEmpty, "read through the client (snapshot, sync, resident tables, reader): \(violations)")
    }

    @Test func noFileNamesTheWrapper() throws {
        let packages = appSources.deletingLastPathComponent().appendingPathComponent("Packages", isDirectory: true)
        let all = FileManager.default.enumerator(at: packages, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let packageSources = all.filter {
            $0.pathExtension == "swift" && $0.path.contains("/Sources/") && !$0.path.contains("/.build/")
        }
        try #require(!packageSources.isEmpty, "package sources not found at \(packages.path)")
        var named: [String] = []
        for file in try swiftFiles() + packageSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("LibraryReads") || text.contains("LibraryIndexReads") || text.contains("DocumentStoreReads") {
                named.append(file.lastPathComponent)
            }
        }
        #expect(named.isEmpty, "\(named)")
        let model = try source("AppModel.swift")
        #expect(!model.contains("let library:"), "AppModel holds the client only")
        #expect(!model.contains("index.connect()"), "no second index connection")
    }

    @Test func theLaunchPathReadsResidentTables() throws {
        let presets = try source("OutputPresetsController.swift")
        let preset = try body(of: "func preset(_ id: String) -> OutputPreset?", in: presets)
        #expect(preset.contains("appModel.resident.outputPresets.value(id)"))
        #expect(!presets.contains("library."), "presets read the table and write through the client")
        let apply = try body(of: "func applyActivePreset()", in: presets)
        #expect(apply.contains("await table.ready()"), "an unresolved preset waits for the fill")
        #expect(!apply.contains("Task.sleep"))

        let midi = try source("MIDIDeviceInventory.swift")
        let reload = try body(of: "func reload()", in: midi)
        #expect(reload.contains("table.values"))
        #expect(!midi.contains("library.") && !midi.contains("LibraryReads"))
        #expect(midi.contains("model.resident.midiDevices"))
    }

    @Test func thereIsNoSynchronousDoor() throws {
        var found: [String] = []
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where line.contains("loadValueNow(") || line.contains("allowingMainThreadOpens") {
                found.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(found.isEmpty, "\(found)")
        let model = try source("AppModel.swift")
        let wait = try body(of: "func themesFilled(_ ids: [String]) async", in: model)
        #expect(wait.contains("await client.loadValues(Theme.self"))
        for file in ["ServiceControls.swift", "OutputPresetsController.swift"] {
            #expect(try source(file).contains("appModel.resident.themes.fireRead("), "\(file)")
        }
    }

    @Test func theEditorOpensOffMain() throws {
        let editor = try source("SlideEditorModel.swift")
        for signature in ["presentationID: String) async", "themeID: String) async", "overlayID: String) async", "confidenceLayoutID: String) async"] {
            #expect(editor.contains("init?(appModel: AppModel, render: RenderContext?, \(signature)"), "\(signature)")
        }
        #expect(editor.contains("client.checkout("), "entry is a checkout")
        #expect(editor.contains("history: .parked"), "entry takes a deck's parked undo history")
        #expect(!editor.contains("loadDocument("), "no private copy of the document")
        let view = try source("SlideEditorView.swift")
        #expect(view.contains("await SlideEditorModel(appModel: appModel, render: render, presentationID: presentationID)"))
        #expect(!view.contains("settled()"), "the checkout is after-queued: no settle before entry")
    }

    @Test func searchesAreTasks() throws {
        for (file, call) in [
            ("LibraryView.swift", "searchHits = await model.search(searchText)"),
            ("ServicePlannerView.swift", "searchHits = await model.search(searchText)"),
            ("SlideEditorView.swift", "queryHits = await appModel.search(query)"),
        ] {
            let text = try source(file)
            #expect(text.contains(call), "\(file)")
            #expect(!text.contains(".search(trimmed)") && !text.contains("index.searchHits("), "\(file)")
        }
        let search = try body(of: "func search(_ text: String) async", in: try source("AppModel.swift"))
        #expect(search.contains("client.search("))
    }
}
