import AVFoundation
import Foundation
import Observation
import OutputEngine
import RenderEngine

@MainActor
@Observable
final class RecordingController {
    @MainActor
    struct Session: Identifiable {
        let id = UUID()
        let targetID: String
        let targetName: String

        let presetID: String?
        let recorder: Recorder
        let mirror: OutputMirror
        let audioFeed: SessionAudioFeed
        let startedAt: Date
        let url: URL

        let libraryFolder: String?

        let exportFolder: String?

        var status: Recorder.Status { recorder.status }
        var isRecording: Bool {
            if case .recording = recorder.status.state { return true }
            return false
        }
    }

    private(set) var sessions: [Session] = [] {
        didSet { onSessionsChanged?() }
    }

    var onSessionsChanged: (() -> Void)?

    struct LibraryAdoption {
        let spoolFolder: URL

        let adopt: (URL, String, String?, Date, String?) -> Void
    }
    var libraryAdoption: LibraryAdoption?

    private var adoptedSessions: Set<UUID> = []
    private let render: RenderContext

    init(render: RenderContext) {
        self.render = render
    }

    nonisolated static var recordingsFolder: URL {
        let folder = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MxU Slides", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var anyRecording: Bool { sessions.contains(where: \.isRecording) }

    var anyStoppedAbnormally: Bool {
        sessions.contains { session in
            switch session.recorder.status.state {
            case .finished(.diskFull), .finished(.writerFailed), .failed: true
            default: false
            }
        }
    }

    func isRecording(targetID: String) -> Bool {
        sessions.contains { $0.targetID == targetID && $0.isRecording }
    }

    func start(
        targetID: String,
        targetName: String,
        codec: RecordingConfiguration.Codec,
        width: Int,
        height: Int,
        frameRate: Int,
        folder: URL? = nil,
        audioMixId: String? = nil,
        audioInputId: String? = nil,
        audioInputUid: String? = nil,
        audioIncludesProgram: Bool = false,
        audioDelayMs: Int = 0,
        presetID: String? = nil,
        libraryFolder: String? = nil,
        exportFolder: String? = nil
    ) throws {
        let stamp = Self.fileStamp.string(from: Date())
        let adopting = libraryFolder != nil && libraryAdoption != nil
        let destination = adopting
            ? libraryAdoption!.spoolFolder
            : folder ?? Self.recordingsFolder
        try? FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let url = destination
            .appendingPathComponent("\(targetName) \(stamp).mov")
        let configuration = RecordingConfiguration(
            codec: codec, width: width, height: height, frameRate: frameRate,
            includesAudio: true)
        let recorder = try Recorder(url: url, configuration: configuration)

        guard !targetID.isEmpty else { return }
        let provider = render.outputs.previewProvider(for: targetID)

        guard let mirror = OutputMirror(
            compositor: render.compositor,
            width: width,
            height: height,
            framesPerSecond: frameRate,

            color: codec.wantsHDRSource ? .hlg2020 : .sdr,
            provider: provider,
            sink: { buffer, hostSeconds in
                recorder.append(buffer, atHostSeconds: hostSeconds)
            }
        ) else {
            throw CocoaError(.featureUnsupported)
        }

        mirror.start()

        let audioFeed = SessionAudioFeed.open(
            audioMixId: audioMixId,
            audioInputId: audioInputId,
            audioInputUid: audioInputUid,
            includeProgram: audioIncludesProgram,
            delayMilliseconds: audioDelayMs
        ) { buffer, _, hostSeconds in
            recorder.appendAudio(buffer, atHostSeconds: hostSeconds)
        }
        let session = Session(
            targetID: targetID, targetName: targetName, presetID: presetID,
            recorder: recorder, mirror: mirror, audioFeed: audioFeed,
            startedAt: Date(), url: url,
            libraryFolder: adopting ? libraryFolder : nil,
            exportFolder: adopting ? exportFolder : nil)
        sessions.append(session)
        DiagnosticsStore.shared.note(
            "recording.start",
            detail: "\(targetName) codec=\(codec.rawValue) \(width)x\(height)@\(frameRate)"
                + ((audioMixId ?? audioInputId ?? audioInputUid).map { " audio=\($0)" } ?? " audio=program")
                + (audioIncludesProgram ? "+program" : ""))
        startHeartbeat(session)
    }

    private func startHeartbeat(_ session: Session) {
        let id = session.id
        Task { [weak self] in
            while let self, let live = self.sessions.first(where: { $0.id == id }) {
                let status = live.recorder.status

                self.finalizeIfNeeded(live)
                DiagnosticsStore.shared.note(
                    "recording.heartbeat",
                    detail: "\(live.targetName) state=\(status.state) "
                        + "frames=\(status.appendedFrames) dropped=\(status.droppedFrames) "
                        + "audioDropped=\(status.droppedAudioBuffers) "
                        + (AudioMixerController.current?.worstFeedBacklogMilliseconds
                            .map { "mixBacklog=\(Int($0))ms " } ?? "")
                        + (AudioMixerController.current
                            .map { "mixTrimmed=\(Int($0.feedTrimmedMilliseconds))ms " } ?? "")
                        + "freeDiskMB=\(status.freeDiskBytes / 1_000_000)")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopAll(presetID: String) {
        for session in sessions where session.presetID == presetID && session.isRecording {
            stop(session)
        }
    }

    func stop(_ session: Session) {
        session.mirror.stop()
        session.audioFeed.close()
        Task {
            await session.recorder.finish()
            finalizeIfNeeded(session)
            sessions.removeAll { $0.id == session.id }
        }
    }

    private func finalizeIfNeeded(_ session: Session) {
        guard let adoption = libraryAdoption,
              let libraryFolder = session.libraryFolder,
              case .finished = session.recorder.status.state,
              !adoptedSessions.contains(session.id)
        else { return }
        adoptedSessions.insert(session.id)
        DiagnosticsStore.shared.note(
            "recording.adopt",
            detail: "\(session.url.lastPathComponent) → \(libraryFolder)"
                + (session.exportFolder.map { " (+ copy → \($0))" } ?? ""))
        adoption.adopt(
            session.url, libraryFolder, session.exportFolder,
            session.startedAt, session.presetID)
    }

    func dismiss(_ session: Session) {
        session.mirror.stop()
        session.audioFeed.close()
        finalizeIfNeeded(session)
        sessions.removeAll { $0.id == session.id }
    }

    func reapFinished() {
        for session in sessions where !session.isRecording {
            session.mirror.stop()
            session.audioFeed.close()
        }
    }

    private nonisolated static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter
    }()
}
