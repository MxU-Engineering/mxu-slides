import AppKit
import Darwin
import Foundation
import MetricKit
import PresenterCore
import QuartzCore
import RenderEngine
import os

private let diagnosticsLog = Logger(
    subsystem: "com.example.mxuslides", category: "diagnostics")

final class DiagnosticsStore: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = DiagnosticsStore()

    nonisolated static var folder: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MxU Slides/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private override init() {
        super.init()
    }

    static let hitchNotification = Notification.Name("DiagnosticsStore.hitch")

    func activate() {
        MXMetricManager.shared.add(self)
        note("launch", detail: appVersionLine())
        UserDefaults.standard.register(defaults: [Self.stackCaptureKey: true])
        mainThreadStack = MainActor.assumeIsolated { ThreadStackCapture.mainThread() }
        Library.perfSink = { event, detail in
            DiagnosticsStore.shared.note(event, detail: detail)
        }
        MainActor.assumeIsolated { MainPassObserver.shared.start() }
        startPerfPulse()
        scheduleSyntheticStall()
        scheduleSyntheticSpin()
    }

    private let pulseQueue = DispatchQueue(
        label: "diagnostics.perfPulse", qos: .utility)
    private var pulseTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdogPingPending = false
    private var watchdogPingSentAt: Double = 0

    private var watchdogPing: UInt64 = 0

    private let answeredPing = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var lastHangSampleAt: Double = -1_000
    private var lastCPUTime: Double = -1

    private var mainThreadStack: ThreadStackCapture?
    private var hitchGate = HitchCaptureGate()
    private var pendingPingStack: RawStack?

    private let stackSymbolQueue = DispatchQueue(
        label: "diagnostics.hitchStacks", qos: .utility)

    static let stackCaptureKey = "MXUPerfStackCapture"

    let passMeter = OSAllocatedUnfairLock(initialState: MainPassMeter())

    let spin = OSAllocatedUnfairLock(initialState: SpinDetector())

    let bodyMeter = OSAllocatedUnfairLock(
        initialState: BodyStormMeter(limits: MeteredView.allCases.map(\.limit)))

    private static let pulseSeconds = 60.0
    private static let pingSeconds = 0.1
    private static let stackAfterSeconds = 0.12
    private static let stackFollowUpSeconds = 1.5

    private static let stackRetrySeconds = 0.5

    private func startPerfPulse() {
        let pulse = DispatchSource.makeTimerSource(queue: pulseQueue)
        pulse.schedule(deadline: .now() + Self.pulseSeconds, repeating: Self.pulseSeconds)
        pulse.setEventHandler { [weak self] in self?.emitPulse() }
        pulse.resume()
        pulseTimer = pulse

        let watchdog = DispatchSource.makeTimerSource(queue: pulseQueue)
        watchdog.schedule(deadline: .now() + 5, repeating: Self.pingSeconds)
        watchdog.setEventHandler { [weak self] in self?.pingMainThread() }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    private func emitPulse() {
        let snapshot = RenderPulse.shared.drain()
        let cpu = cpuPercentSinceLastPulse()
        var parts: [String] = [String(format: "cpu %.0f%%", cpu)]
        if snapshot.placeholderFrames > 0 || snapshot.placeholderSkips > 0 {
            let frames = max(snapshot.placeholderFrames, 1)
            parts.append(String(
                format: "screens %df (%d skip) avg %.1fms",
                snapshot.placeholderFrames, snapshot.placeholderSkips,
                snapshot.placeholderEncodeMS / Double(frames)))
        }
        if snapshot.mirrorFrames > 0 || snapshot.mirrorResends > 0 || snapshot.mirrorDrops > 0 {
            let frames = max(snapshot.mirrorFrames, 1)
            parts.append(String(
                format: "mirror %df (%d resent, %d drop) readback avg %.1fms convert avg %.1fms",
                snapshot.mirrorFrames, snapshot.mirrorResends, snapshot.mirrorDrops,
                snapshot.mirrorReadbackMS / Double(frames),
                snapshot.mirrorConvertMS / Double(frames)))
        }
        if snapshot.mirrorSteeredTicks > 0 {
            parts.append(String(
                format: "steer %dt avg edge %.1fms closest %.1fms near-edge %dt",
                snapshot.mirrorSteeredTicks,
                snapshot.mirrorEdgeMSTotal / Double(snapshot.mirrorSteeredTicks),
                snapshot.mirrorClosestEdgeMS, snapshot.mirrorNearEdgeTicks))
        }
        if !snapshot.captureFrames.isEmpty {
            let rates = snapshot.captureFrames.sorted { $0.key < $1.key }.map {
                String(format: "%@ %.2ffps", $0.key, Double($0.value) / Self.pulseSeconds)
            }
            parts.append("capture " + rates.joined(separator: ", "))
        }
        if snapshot.textRasterizations > 0 {
            parts.append(String(
                format: "textRaster %d avg %.1fms",
                snapshot.textRasterizations,
                snapshot.textRasterizeMS / Double(snapshot.textRasterizations)))
        }
        if snapshot.hitches > 0 {
            parts.append(String(
                format: "hitches %d worst %.0fms",
                snapshot.hitches, snapshot.worstHitchMS))
        }
        parts.append(passMeter.withLock { $0.drainPulse() })
        parts.append(bodyMeter.withLock { $0.drainPulse(names: MeteredView.allCases.map(\.name)) })
        note("perf.pulse", detail: parts.joined(separator: " | "))
    }

    private func sampleHang() {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard now - lastHangSampleAt > 20 else { return }
        lastHangSampleAt = now
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.folder.appendingPathComponent("hang-\(stamp).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "2", "-mayDie", "-file", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            note("perf.hang.sample", detail: url.lastPathComponent)
        } catch {
            note("perf.hang.sample.failed", detail: "\(error)")
        }
        #endif
    }

    private func cpuPercentSinceLastPulse() -> Double {
        var usage = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard status == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let seconds = Double(usage.ri_user_time + usage.ri_system_time)
            * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        defer { lastCPUTime = seconds }
        guard lastCPUTime >= 0 else { return 0 }
        return (seconds - lastCPUTime) / 60 * 100
    }

    private func pingMainThread() {
        checkForSpin()

        if !watchdogPingPending {
            watchdogPingPending = true
            watchdogPing &+= 1
            let ping = watchdogPing
            let sent = CACurrentMediaTime()
            watchdogPingSentAt = sent
            pendingPingStack = nil
            pulseQueue.asyncAfter(deadline: .now() + Self.stackAfterSeconds) { [weak self] in
                self?.captureStackIfStillBlocked(ping: ping, followUp: false)
            }

            pulseQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                if let self, self.watchdogPingPending, self.watchdogPing == ping {
                    self.sampleHang()
                }
            }
            DispatchQueue.main.async { [weak self] in
                let blockedMS = (CACurrentMediaTime() - sent) * 1000
                if let self {
                    self.answeredPing.withLock { $0 = ping }
                    self.pulseQueue.async { self.pingAnswered(blockedMS: blockedMS) }
                }
            }
        }
    }

    private func pingAnswered(blockedMS: Double) {
        watchdogPingPending = false
        pendingPingStack = nil
        if blockedMS > 250 {
            RenderPulse.shared.hitch(ms: blockedMS)
            NotificationCenter.default.post(name: Self.hitchNotification, object: nil)
            note(
                "perf.hitch",
                detail: String(format: "main thread blocked %.0fms", blockedMS))
        }
    }

    private func captureStackIfStillBlocked(ping: UInt64, followUp: Bool) {
        let now = CACurrentMediaTime()
        let stillBlocked = watchdogPingPending && watchdogPing == ping
            && answeredPing.withLock { $0 } != ping
        if stillBlocked, UserDefaults.standard.bool(forKey: Self.stackCaptureKey), let mainThreadStack {
            let admitted = followUp ? hitchGate.admitFollowUp(now: now) : hitchGate.admitFirst(now: now)
            if let dropped = admitted {
                let stack = mainThreadStack.capture()
                let blockedMS = (CACurrentMediaTime() - watchdogPingSentAt) * 1000

                let mode = RunLoopModeName.short(CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String })
                let previous = followUp ? pendingPingStack : nil
                pendingPingStack = stack
                stackSymbolQueue.async { [weak self] in
                    self?.writeStackLine(stack, previous: previous, mode: mode, blockedMS: blockedMS, dropped: dropped)
                }
                if !followUp {
                    pulseQueue.asyncAfter(deadline: .now() + Self.stackFollowUpSeconds) { [weak self] in
                        self?.captureStackIfStillBlocked(ping: ping, followUp: true)
                    }
                }
            } else if !followUp {

                pulseQueue.asyncAfter(deadline: .now() + Self.stackRetrySeconds) { [weak self] in
                    self?.captureStackIfStillBlocked(ping: ping, followUp: false)
                }
            }
        }
    }

    private func writeStackLine(_ stack: RawStack, previous: RawStack?, mode: String, blockedMS: Double, dropped: Int) {
        let frames = HitchStackLine.chosen(
            ThreadStackCapture.symbolicate(stack), isApp: ThreadStackCapture.isAppFrame)
        let detail = HitchStackLine.detail(
            mode: mode, blockedMS: blockedMS,
            loadAddress: ThreadStackCapture.ownImage.loadAddress,
            movement: previous.map { HitchStackLine.movement(from: $0, to: stack) },
            frames: frames)
        note("perf.hitch.stack", detail: PerfLineLimiter.annotate(detail, dropped: dropped))
    }

    private func checkForSpin() {
        let now = CACurrentMediaTime()
        switch spin.withLock({ $0.evaluate(at: now) }) {
        case .began(let found, let dropped)?:
            let capture = UserDefaults.standard.bool(forKey: Self.stackCaptureKey) ? mainThreadStack : nil
            let stack = capture?.capture()
            stackSymbolQueue.async { [weak self] in
                let frames = stack.map {
                    HitchStackLine.chosen(ThreadStackCapture.symbolicate($0), isApp: ThreadStackCapture.isAppFrame)
                } ?? []
                let head = "\(found.detail), load 0x\(String(ThreadStackCapture.ownImage.loadAddress, radix: 16))"
                let trace = frames.isEmpty ? "(no stack)" : frames.joined(separator: " ← ")
                self?.note("perf.spin", detail: PerfLineLimiter.annotate("\(head) | \(trace)", dropped: dropped))
            }
            Self.showSpinBadge(true)
        case .ended(let found)?:
            note("perf.spin.end", detail: found.endDetail)
            Self.showSpinBadge(false)
        case nil:
            break
        }
    }

    private static func showSpinBadge(_ shown: Bool) {
        #if DEBUG
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = shown ? "spin" : nil
        }
        #endif
    }

    private func scheduleSyntheticStall() {
        if let raw = ProcessInfo.processInfo.environment["MXU_SYNTHETIC_STALL_MS"],
           let milliseconds = Double(raw), milliseconds > 0
        {
            note("perf.syntheticStall", detail: String(format: "%.0f ms in 8 s", milliseconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                syntheticMainThreadStall(milliseconds: milliseconds)
            }
        }
    }

    private func scheduleSyntheticSpin() {
        if let raw = ProcessInfo.processInfo.environment["MXU_SYNTHETIC_SPIN_S"],
           let seconds = Double(raw), seconds > 0
        {
            note("perf.syntheticSpin", detail: String(format: "%.0f s in 8 s", seconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                syntheticSpinPass(until: CACurrentMediaTime() + seconds)
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            write(payload.jsonRepresentation(), kind: "diagnostic")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            write(payload.jsonRepresentation(), kind: "metrics")
        }
    }

    private let noteQueue = DispatchQueue(label: "diagnostics.notes", qos: .utility)

    func note(_ event: String, detail: String = "") {

        if detail.isEmpty {
            diagnosticsLog.info("\(event, privacy: .public)")
        } else {
            diagnosticsLog.info("\(event, privacy: .public) — \(detail, privacy: .public)")
        }
        let stamp = Self.noteStamp.string(from: Date())
        let line = detail.isEmpty ? "\(stamp) \(event)\n" : "\(stamp) \(event) — \(detail)\n"
        let day = Self.dayStamp.string(from: Date())
        noteQueue.async {
            let url = Self.folder.appendingPathComponent("breadcrumbs-\(day).log")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private func write(_ json: Data, kind: String) {
        let stamp = Self.fileStamp.string(from: Date())
        let url = Self.folder.appendingPathComponent("\(kind)-\(stamp).json")
        try? json.write(to: url)
        note("wrote \(kind) payload", detail: url.lastPathComponent)
    }

    private func appVersionLine() -> String {
        BuildIdentity(info: Bundle.main.infoDictionary).launchLine(
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            image: LoadedImage(containing: #dsohandle))
    }

    nonisolated(unsafe) private static let noteStamp = ISO8601DateFormatter()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let dayStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@inline(never)
func syntheticMainThreadStall(milliseconds: Double) {
    let end = CACurrentMediaTime() + milliseconds / 1000
    var spins = 0
    while CACurrentMediaTime() < end {
        spins &+= 1
    }
    DiagnosticsStore.shared.note(
        "perf.syntheticStall", detail: String(format: "blocked %.0f ms (%d spins)", milliseconds, spins))
}

@inline(never)
func syntheticSpinPass(until end: Double) {
    let passEnd = CACurrentMediaTime() + 0.004
    var spins = 0
    while CACurrentMediaTime() < passEnd {
        spins &+= 1
    }
    if CACurrentMediaTime() < end {
        DispatchQueue.main.async { syntheticSpinPass(until: end) }
    } else {
        DiagnosticsStore.shared.note("perf.syntheticSpin", detail: "done")
    }
}
