import AppKit
import Foundation
import MediaEngine

@MainActor
enum AutoSoak {
    static func runIfRequested(render: RenderContext) async {
        let args = CommandLine.arguments
        guard let minutes = value(after: "--soak-minutes", in: args).flatMap(Double.init) else { return }
        let logPath = value(after: "--soak-log", in: args)
            ?? NSTemporaryDirectory().appending("mxu-soak.log")
        let log = LogFile(path: logPath)

        log.append("soak: starting — \(Int(minutes)) minutes, gate = 0 dropped frames after settle")
        await render.soak.start(render: render)
        guard render.soak.isRunning else {
            log.append("RESULT: FAIL — soak did not start: \(render.soak.phase)")
            exit(2)
        }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: "MxU soak gate"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else {
            log.append("RESULT: FAIL — no app window to measure through")
            exit(2)
        }
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.orderFrontRegardless()

        try? await Task.sleep(for: .seconds(5))
        let alphaBase = render.soak.alphaStats
        let opaqueBase = render.soak.opaqueStats
        log.append("soak: baseline after settle — raw 4kAlpha dropped=\(alphaBase.framesDropped) "
            + "1080p60 dropped=\(opaqueBase.framesDropped); counting from zero now")

        let deadline = Date.now.addingTimeInterval(minutes * 60)
        log.append("soak: running, deadline \(deadline)")
        while Date.now < deadline {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled {
                log.append("RESULT: FAIL — soak aborted (window closed / app quitting)")
                exit(2)
            }
            if window.occlusionState.contains(.visible) == false {
                log.append("soak: WARNING window fully occluded — display link paused, run invalid")
            }
            log.append("soak: \(statusLine(render, alphaBase: alphaBase, opaqueBase: opaqueBase))")
        }

        let alpha = render.soak.alphaStats
        let opaque = render.soak.opaqueStats
        let dropped = (alpha.framesDropped - alphaBase.framesDropped)
            + (opaque.framesDropped - opaqueBase.framesDropped)
        log.append("RESULT: \(dropped == 0 ? "PASS" : "FAIL") — "
            + statusLine(render, alphaBase: alphaBase, opaqueBase: opaqueBase))
        render.soak.stop(render: render)
        exit(dropped == 0 ? 0 : 1)
    }

    private static func statusLine(
        _ render: RenderContext,
        alphaBase: PlaybackStats,
        opaqueBase: PlaybackStats
    ) -> String {
        let alpha = render.soak.alphaStats
        let opaque = render.soak.opaqueStats
        let elapsed = render.soak.startedAt.map { Int(Date.now.timeIntervalSince($0)) } ?? 0
        let canvas = render.canvasView
        return "elapsed=\(elapsed)s "
            + "4kAlpha displayed=\(alpha.framesDisplayed - alphaBase.framesDisplayed) "
            + "dropped=\(alpha.framesDropped - alphaBase.framesDropped) "
            + "(seam=\(alpha.framesDroppedAtSeam - alphaBase.framesDroppedAtSeam)) "
            + "1080p60 displayed=\(opaque.framesDisplayed - opaqueBase.framesDisplayed) "
            + "dropped=\(opaque.framesDropped - opaqueBase.framesDropped) "
            + "(seam=\(opaque.framesDroppedAtSeam - opaqueBase.framesDroppedAtSeam)) "
            + "canvasTicks=\(canvas?.tickCount ?? -1) missedTicks=\(canvas?.missedTickCount ?? -1)"
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
}

private struct LogFile {
    let path: String

    init(path: String) {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    func append(_ line: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
