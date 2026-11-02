import AppKit
import Foundation
import Observation
import PresenterCore
import SwiftUI

@MainActor
@Observable
final class ScheduledBackupController {
    static let shared = ScheduledBackupController()

    private(set) var folder = UserDefaults.standard.string(forKey: ScheduledBackup.folderKey)
    private(set) var lastRun = UserDefaults.standard.object(forKey: ScheduledBackup.lastRunKey) as? Date
    private(set) var problem = UserDefaults.standard.string(forKey: ScheduledBackup.lastProblemKey)
    private(set) var running = false

    private var model: AppModel?
    private var task: Task<Void, Never>?

    var caption: String { ScheduledBackup.caption(folder: folder, lastRun: lastRun, problem: problem) }

    func start(model: AppModel) {
        self.model = model
        schedule()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose a folder or drive for the nightly library backup."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.use(folder: url.path) }
        }
    }

    func turnOff() {
        use(folder: nil)
    }

    func backUpNow() {
        Task { await run() }
    }

    private func use(folder: String?) {
        self.folder = folder
        UserDefaults.standard.set(folder, forKey: ScheduledBackup.folderKey)
        problem = nil
        UserDefaults.standard.removeObject(forKey: ScheduledBackup.lastProblemKey)
        DiagnosticsStore.shared.note("backup.scheduled", detail: folder.map { "to \($0)" } ?? "off")
        schedule()
    }

    private func schedule() {
        task?.cancel()
        task = nil
        guard folder != nil, model != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled, let self {
                let now = Date()
                if ScheduledBackup.due(lastRun: self.lastRun, now: now) {
                    await self.run()
                }
                let wait = min(ScheduledBackup.nextSlot(after: .now).timeIntervalSinceNow, 3600)
                try? await Task.sleep(for: .seconds(max(wait, 60)))
            }
        }
    }

    private func run() async {
        guard !running, let folder, let model else { return }
        running = true
        defer { running = false }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let now = Date()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await BackupBundle.export(client: model.client, to: directory.appendingPathComponent(ScheduledBackup.fileName(for: now)))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in ScheduledBackup.pruned(names) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            lastRun = now
            problem = nil
            UserDefaults.standard.set(now, forKey: ScheduledBackup.lastRunKey)
            UserDefaults.standard.removeObject(forKey: ScheduledBackup.lastProblemKey)
            DiagnosticsStore.shared.note("backup.nightly", detail: "saved to \(folder)")
        } catch {
            problem = error.localizedDescription
            UserDefaults.standard.set(problem, forKey: ScheduledBackup.lastProblemKey)
            DiagnosticsStore.shared.note("backup.nightlyFailed", detail: "\(error)")
        }
    }
}

struct ScheduledBackupControl: View {
    let backup: ScheduledBackupController

    var body: some View {
        HStack(spacing: 8) {
            if backup.running {
                ProgressView().controlSize(.small)
            }
            if backup.folder != nil {
                Button("Back Up Now") { backup.backUpNow() }
                    .disabled(backup.running)
                Button("Change Folder\u{2026}") { backup.chooseFolder() }
                Button("Turn Off") { backup.turnOff() }
            } else {
                Button("Choose Folder\u{2026}") { backup.chooseFolder() }
            }
        }
    }
}
