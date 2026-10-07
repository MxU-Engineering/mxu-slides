import AppKit
import Foundation
import PresenterCore

@MainActor
@Observable
final class FeedbackController {
    static let shared = FeedbackController()

    enum Phase: Equatable {
        case idle, working(String), saved(URL), failed(String)
    }

    private(set) var phase: Phase = .idle

    private(set) var lastRunCrashed = false

    private static let lastLaunchKey = "diagnostics.lastLaunchAt"
    private nonisolated static var crashReportsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    func activate() {
        let stored = UserDefaults.standard.double(forKey: Self.lastLaunchKey)
        let previousLaunch = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastLaunchKey)
        Task.detached(priority: .utility) {
            let crashes = DiagnosticsBundle.crashReports(
                in: DiagnosticsBundle.candidates(in: Self.crashReportsFolder), since: previousLaunch)
            let expired = DiagnosticsBundle.expired(
                from: DiagnosticsBundle.candidates(in: DiagnosticsStore.folder), now: Date())
            for file in expired { try? FileManager.default.removeItem(at: file.url) }
            if !expired.isEmpty {
                DiagnosticsStore.shared.note("diagnostics.pruned", detail: "\(expired.count) files")
            }
            if !crashes.isEmpty {
                DiagnosticsStore.shared.note("diagnostics.lastRunCrashed", detail: crashes[0].url.lastPathComponent)
                await MainActor.run { self.lastRunCrashed = true }
            }
        }
    }

    func reset() {
        phase = .idle
        lastRunCrashed = false
    }

    func systemInfo(model: AppModel?) -> [String: String] {
        let info = Bundle.main.infoDictionary
        let disk = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])

        var result: [String: String] = BuildIdentity(info: info).reportFields.merging([
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "mac_model": Self.sysctl("hw.model"),
            "chip": Self.sysctl("machdep.cpu.brand_string"),
            "memory_gb": "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)",
            "free_disk_gb": "\((disk?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824)",
            "displays": NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: ", "),
        ]) { build, _ in build }
        if let model {
            result["library_counts"] = [LibrarySection.presentations, .services, .media, .themes]
                .map { "\($0.rawValue.lowercased()) \(model.entries(in: $0).count)" }.joined(separator: ", ")
        }
        return result
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    func saveReport(message: String, model: AppModel?) async {
        phase = .working("Collecting diagnostics…")
        do {
            let zip = try await Self.buildZip(message: message, systemInfo: systemInfo(model: model))
            saveLocally(zip: zip)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func saveLocally(zip: URL) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = downloads.appendingPathComponent(zip.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: zip, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            phase = .saved(destination)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func buildZip(message: String, systemInfo: [String: String]) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let staging = files.temporaryDirectory
                .appendingPathComponent("MxU Slides Diagnostics \(stamp)", isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: staging) }

            let crashes = DiagnosticsBundle.candidates(in: crashReportsFolder)
                .filter { DiagnosticsBundle.isCrashReport(fileName: $0.url.lastPathComponent) }
            let chosen = DiagnosticsBundle.selection(
                from: DiagnosticsBundle.candidates(in: DiagnosticsStore.folder) + crashes, now: Date())
            for file in chosen {
                try? files.copyItem(at: file.url, to: staging.appendingPathComponent(file.url.lastPathComponent))
            }
            let report: [String: Any] = ["message": message, "system_info": systemInfo, "files": chosen.map(\.url.lastPathComponent)]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent("report.json"))

            let zip = files.temporaryDirectory.appendingPathComponent("\(staging.lastPathComponent).zip")
            try? files.removeItem(at: zip)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--norsrc", "--keepParent", staging.path, zip.path]
            try ditto.run()
            ditto.waitUntilExit()
            if ditto.terminationStatus == 0 {
                return zip
            } else {
                throw NSError(domain: "FeedbackController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not zip the diagnostics"])
            }
        }.value
    }
}
