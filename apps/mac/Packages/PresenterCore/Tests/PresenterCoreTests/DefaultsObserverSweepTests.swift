import Foundation
import Testing

@Suite struct DefaultsObserverSweepTests {
    @Test func defaultsObserversNeverBlockThePostingThread() throws {
        let packages = SourceSweep.macRoot().appendingPathComponent("Packages", isDirectory: true)
        let packageSources = try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Sources", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = try SourceSweep.app().files + packageSources.flatMap { try SourceSweep(root: $0).files }
        var observers = 0
        for file in files {
            for index in file.codeLines.indices where file.code(index).contains("UserDefaults.didChangeNotification") {

                let call = file.codeLines[max(0, index - 2)...min(file.codeLines.count - 1, index + 2)].joined(separator: " ")
                guard call.contains("addObserver(") else { continue }
                observers += 1
                #expect(
                    !call.contains("queue: .main") && !call.contains("OperationQueue.main"),
                    "\(file.name):\(index + 1) observes defaults on the main queue; use `queue: nil` and hop to main")
            }
        }
        #expect(observers >= 2, "TracksController + WorkspaceSettingsMirror observe defaults")
    }
}
