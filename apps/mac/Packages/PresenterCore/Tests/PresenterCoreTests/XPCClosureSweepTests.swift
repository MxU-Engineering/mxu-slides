import Foundation
import Testing

@Suite struct XPCClosureSweepTests {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func xpcHandlerClosuresAreSendable() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: appSources, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        let registrations = [
            "interruptionHandler = {",
            "invalidationHandler = {",
            "remoteObjectProxyWithErrorHandler {",
            "remoteObjectProxyWithErrorHandler({",
        ]

        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("NSXPCConnection") else { continue }
            for (index, line) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                for pattern in registrations where line.contains(pattern) {
                    let after = line[line.range(of: pattern)!.upperBound...]
                    if !after.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("@Sendable") {
                        violations.append(
                            "\(file.lastPathComponent):\(index + 1) — \(pattern) missing @Sendable")
                    }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}
