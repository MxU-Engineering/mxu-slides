import Foundation
import Testing

@Suite struct AutomergePinSweepTests {
    private var packages: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
    }

    private func packageFiles(named name: String) -> [URL] {
        let all = FileManager.default.enumerator(
            at: packages, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []
        return all.filter { $0.lastPathComponent == name && !$0.path.contains("/automerge-swift/") }
    }

    private func vendoredSource(_ file: String) throws -> String {
        try String(
            contentsOf: packages.appendingPathComponent("automerge-swift/Sources/Automerge/Codable/\(file)"),
            encoding: .utf8
        )
    }

    @Test func tracePrintTakesItsMessageAsAnAutoclosure() throws {
        let declarations = try vendoredSource("Document+retrieveObjectId.swift")
            .split(separator: "\n").map(String.init)
            .filter { $0.contains("func tracePrint(") }
        #expect(declarations.count == 1, "\(declarations)")
        #expect(
            declarations.allSatisfy { $0.contains("_ stringval: @autoclosure () -> String") },
            "tracePrint must take @autoclosure () -> String: \(declarations)"
        )
    }

    @Test func nestedDecodersStartFromTheirParentsObjectId() throws {
        #expect(try vendoredSource("Document+retrieveObjectId.swift").contains("parentObjectId: ObjId? = nil"))
        #expect(try vendoredSource("Decoding/AutomergeDecoderImpl.swift").contains("parentObjectId: parentObjectId"))
        #expect(try vendoredSource("Decoding/AutomergeKeyedDecodingContainer.swift").contains("parentObjectId: objectId"))
        #expect(try vendoredSource("Decoding/AutomergeUnkeyedDecodingContainer.swift").contains("parentObjectId: objectId"))
    }

    @Test func decodeIfPresentReadsTheValueOnce() throws {
        let keyed = try vendoredSource("Decoding/AutomergeKeyedDecodingContainer.swift")
        #expect(keyed.contains("private func decodeOnceIfPresent<T>("))
        #expect(keyed.contains("func decodeIfPresent<T>(_ type: T.Type, forKey key: K) throws -> T? where T: Decodable"))
        #expect(try vendoredSource("Decoding/AutomergeDecoderImpl.swift").contains("if let prefetchedValue {"))
    }

    @Test func containersReadTheirValuesInOneCall() throws {
        #expect(try vendoredSource("Decoding/AutomergeKeyedDecodingContainer.swift")
            .contains("try? impl.doc.mapEntries(obj: objectId)"))
        #expect(try vendoredSource("Decoding/AutomergeUnkeyedDecodingContainer.swift")
            .contains("try? impl.doc.values(obj: objectId)"))
    }

    @Test func everyManifestThatNamesAutomergeUsesTheVendoredCopy() throws {
        let manifests = packageFiles(named: "Package.swift")
        try #require(manifests.count >= 10, "package manifests not found under \(packages.path)")
        var dependents: [String] = []
        var violations: [String] = []
        for manifest in manifests {
            let lines = try String(contentsOf: manifest, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let name = manifest.deletingLastPathComponent().lastPathComponent
            if lines.contains(where: { $0.lowercased().contains("automerge") }) {
                dependents.append(name)
                for line in lines where line.contains(".package(") && line.lowercased().contains("automerge") {
                    if !line.contains(#".package(path: "../automerge-swift")"#) {
                        violations.append("\(name)/Package.swift: \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
                if !lines.contains(where: { $0.contains(#".package(path: "../automerge-swift")"#) }) {
                    violations.append("\(name)/Package.swift names automerge without the vendored path dependency")
                }
            }
        }
        #expect(dependents.contains("PresenterCore"), "\(dependents)")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func noResolvedFilePinsUpstreamAutomerge() throws {
        let resolved = packageFiles(named: "Package.resolved")
        try #require(!resolved.isEmpty, "Package.resolved files not found under \(packages.path)")
        let pinned = try resolved.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("automerge-swift")
        }
        #expect(pinned.isEmpty, "\(pinned.map { $0.deletingLastPathComponent().lastPathComponent })")
    }
}
