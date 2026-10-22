import AppKit
import AVFoundation
import PresenterCore
import SwiftUI

@MainActor
final class WaveformStore {
    static let shared = WaveformStore()

    private var loaded: [String: Waveform] = [:]
    private var loading: [String: Task<Waveform?, Never>] = [:]

    private let limiter = AsyncLimiter(limit: 2)

    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MxU Slides", isDirectory: true)
        .appendingPathComponent("Waveforms", isDirectory: true)

    func waveform(hash: String, blobs: BlobStore?) async -> Waveform? {
        if let wave = loaded[hash] { return wave }
        if let task = loading[hash] { return await task.value }
        guard let blobs else { return nil }
        let limiter = limiter
        let task = Task.detached(priority: .utility) {
            await limiter.withPermit { Self.read(hash: hash, blobs: blobs) }
        }
        loading[hash] = task
        let wave = await task.value
        loading[hash] = nil
        if let wave { loaded[hash] = wave }
        return wave
    }

    nonisolated private static func read(hash: String, blobs: BlobStore) -> Waveform? {
        let cached = folder.appendingPathComponent(hash.replacingOccurrences(of: "/", with: "_") + ".peaks")
        if let data = try? Data(contentsOf: cached), let wave = Waveform(encoded: data) { return wave }
        guard let url = blobs.url(forHash: hash), let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)
        else { return nil }
        var bucketer = WaveformBucketer(sampleRate: file.processingFormat.sampleRate)
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let samples = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            bucketer.add(
                (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: samples[$0], count: frames) },
                frameCount: frames)
        }
        let wave = bucketer.finished()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? wave.encoded.write(to: cached, options: .atomic)
        return wave
    }
}

struct TimelineWaveformSource: Hashable, Sendable {
    let hash: String
    let at: Double
    let inPoint: Double
    let duration: Double?

    @MainActor static func of(_ cue: TimelineCue, model: AppModel) -> Self? {
        guard let id = cue.mediaId, let item = model.audio(id) else { return nil }
        return Self(hash: item.fileHash, at: cue.at, inPoint: item.inPoint ?? 0, duration: cue.duration)
    }
}

@MainActor
@Observable
final class TimelineVisibleWindow {
    var range: ClosedRange<Double>?
}

struct TimelineVisibleWindowTracker: NSViewRepresentable {
    let window: TimelineVisibleWindow

    final class TrackerView: NSView {
        var visible: TimelineVisibleWindow?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
            }
            update()
        }

        override func layout() {
            super.layout()
            update()
        }

        func update() {
            guard let clip = enclosingScrollView?.contentView else { return }
            let shown = convert(clip.bounds, from: clip)
            let next = Waveforms.drawnWindow(visibleMinX: shown.minX, visibleWidth: shown.width)
            if visible?.range != next { visible?.range = next }
        }
    }

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.visible = window
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.visible = window
    }
}

struct TimelineWaveform: View {
    let sources: [TimelineWaveformSource]
    let blobs: BlobStore?
    let origin: Double
    let length: Double
    let pointsPerSecond: Double
    let contentX: CGFloat
    var color: Color = .primary
    @Environment(TimelineVisibleWindow.self) private var visible: TimelineVisibleWindow?
    @State private var levels: WaveformLevels?

    private struct Key: Hashable {
        var sources: [TimelineWaveformSource]
        var origin: Double
        var length: Double
    }

    var body: some View {
        let width = CGFloat(max(length, 0) * pointsPerSecond)

        let window = visible?.range ?? 0...4000
        let from = max(CGFloat(window.lowerBound) - contentX, 0)
        let to = min(CGFloat(window.upperBound) - contentX, width)
        ZStack(alignment: .topLeading) {
            if let levels, to > from {
                let level = levels.level(forPointsPerSecond: pointsPerSecond)
                let scale = levels.fillScale
                let pps = pointsPerSecond
                Canvas { context, size in
                    context.fill(Self.path(level, scale: scale, from: from, size: size, pointsPerSecond: pps), with: .color(color))
                }
                .frame(width: to - from)
                .offset(x: from)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .task(id: Key(sources: sources, origin: origin, length: length)) {
            levels = await Self.levels(sources, blobs: blobs, origin: origin, length: length) ?? levels
        }
    }

    private static func levels(
        _ sources: [TimelineWaveformSource], blobs: BlobStore?, origin: Double, length: Double
    ) async -> WaveformLevels? {
        let parts = await withTaskGroup(of: WaveformPart?.self) { group in
            for source in sources {
                group.addTask {
                    await WaveformStore.shared.waveform(hash: source.hash, blobs: blobs).map {
                        WaveformPart(waveform: $0, at: source.at, inPoint: source.inPoint, duration: source.duration)
                    }
                }
            }
            var parts: [WaveformPart] = []
            for await part in group { if let part { parts.append(part) } }
            return parts
        }
        guard !parts.isEmpty, length > 0 else { return nil }
        return await Task.detached(priority: .utility) {
            WaveformLevels(Waveforms.combined(parts, from: origin, length: length))
        }.value
    }

    private static func path(
        _ level: Waveform, scale: Float, from: CGFloat, size: CGSize, pointsPerSecond: Double
    ) -> Path {
        let rate = level.bucketsPerSecond
        let first = max(Int((Double(from) / pointsPerSecond * rate).rounded(.down)), 0)
        let last = min(Int((Double(from + size.width) / pointsPerSecond * rate).rounded(.up)), level.count)
        guard first < last else { return Path() }
        let mid = size.height / 2
        let reach = max(mid - 1, 1)
        let x = { (index: Int) in CGFloat(Double(index) / rate * pointsPerSecond) - from }

        let y = { (value: Float, sign: CGFloat) in mid - sign * max(CGFloat(abs(value) * scale) * reach, 0.5) }
        var path = Path()
        path.move(to: CGPoint(x: x(first), y: y(level.maxs[first], 1)))
        for index in first..<last { path.addLine(to: CGPoint(x: x(index + 1), y: y(level.maxs[index], 1))) }
        for index in (first..<last).reversed() { path.addLine(to: CGPoint(x: x(index), y: y(level.mins[index], -1))) }
        path.closeSubpath()
        return path
    }
}
