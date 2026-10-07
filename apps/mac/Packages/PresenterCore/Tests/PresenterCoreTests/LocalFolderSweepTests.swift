import Foundation
import Testing

@Suite struct LocalFolderSweepTests {
    private func body(_ file: SourceSweep.File, _ signature: String) throws -> String {
        let start = try #require(file.lines.firstIndex { $0.contains(signature) }, "\(signature)")
        return file.block(from: start).map { file.code($0) }.joined(separator: "\n")
    }

    @Test func newFolderRenameAndMoveIgnoreTheTeamTreeAndArea() throws {
        let sweep = try SourceSweep.app()
        let model = try #require(sweep.file("AppModel.swift"))
        let folders = try body(model, "func folders(in section: LibrarySection) -> [String] {")
        #expect(folders.contains("let empties = isFiltered(section) ? [] : pendingFolders[section.rawValue] ?? []"))
        let rename = try body(model, "func renameFolder(in section: LibrarySection, path: [String], to name: String) {")
        #expect(rename.contains("refileFolder(in: section, from: path) { TeamDriveLogic.renamed(folder: $0, from: path, to: trimmed) }"))
        let move = try body(model, "func moveFolder(in section: LibrarySection, from: [String], into destination: [String]) {")
        #expect(move.contains("refileFolder(in: section, from: from) { TeamDriveLogic.rebased(folder: $0, from: from, into: destination) }"))
        let refile = try body(model, "private func refileFolder(in section: LibrarySection, from path: [String], to folder: (String) -> String) {")
        #expect(refile.contains("file(entries(in: section).filter { TeamDriveLogic.isUnder($0.subkind, prefix: fromPath) }.compactMap {"))
        for (name, text) in [("folders", folders), ("renameFolder", rename), ("moveFolder", move), ("refileFolder", refile)] {
            #expect(!text.contains("teamFolderTree") && !text.contains("showsTeamDrives") && !text.contains("showing:"), "\(name)")
        }

        let library = try #require(sweep.file("LibraryView.swift"))
        let drop = try body(library, "private func handleDrop(_ payloads: [String], into path: [String]) -> Bool {")
        #expect(drop.contains("model.moveFolder(in: model.selectedSection, from: folder.path, into: destination)"))
        #expect(drop.contains("model.moveToFolder(entry, folder: target.isEmpty ? nil : target.joined(separator:"))
        #expect(!drop.contains("model.area("), "a drop files, never changes an area")
    }

    @Test func newFolderNeverFilesUnderTheUnfiledRowOrAFlatView() throws {
        let library = try #require(try SourceSweep.app().file("LibraryView.swift"))
        #expect(!library.text.contains("parentPath: folderPath"))
        for entry in ["entry", "nil"] {
            #expect(library.text.contains("NewFolderSheet(model: model, entry: \(entry), parentPath: realPath(folderPath ?? []))"), "\(entry)")
        }
        let opens = try #require(library.lines.firstIndex { $0.contains("creatingFolder = true") })
        let button = library.block(from: opens - 1)
        #expect(library.code(button.lowerBound).contains("Button {"))
        #expect(library.code(button.upperBound + 1).contains(".disabled(folderPath == nil || (folderPath.map(isUnfiled) ?? false))"))
    }

    @Test func filingPrunesEmptyFoldersOnlyInItsOwnSection() throws {
        let model = try #require(SourceSweep.app().file("AppModel.swift"))
        let file = try body(model, "func file(_ refiles: [LibraryRefile]) -> Task<LibraryEngine.Refiled, any Error> {")
        #expect(file.contains("let filled = Dictionary(grouping: refiles, by: \\.kind).mapValues { Set($0.compactMap(\\.folder)) }"))
        #expect(file.contains("guard let done = LibrarySection(rawValue: key).flatMap({ filled[$0.kind] }), !done.isDisjoint(with: folders) else { continue }"))
        #expect(file.contains("pendingFolders[key] = folders.filter { !done.contains($0) }"))
        #expect(!file.contains("pendingFolders.mapValues"), "filing in one section never prunes another section's empty folders")
    }
}
