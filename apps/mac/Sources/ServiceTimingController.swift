import Foundation
import PresenterCore
import SlideScene

@MainActor
@Observable
final class ServiceTimingController {
    private(set) var localItemStarts: [String: Date] = [:]
    private(set) var currentServiceItemID: String?
    private(set) var localServiceStart: Date?

    private let model: AppModel
    private weak var controls: ServiceControls?
    private let render: RenderContext
    private var generation = 0

    init(model: AppModel, controls: ServiceControls, render: RenderContext) {
        self.model = model
        self.controls = controls
        self.render = render

        refresh()
        arm()
    }

    func noteItemFired(serviceItemID: String?) {
        guard let serviceItemID else { return }
        armLocalTimingEnd(firedItemID: serviceItemID)
        guard serviceItemID != currentServiceItemID else { return }
        let now = Date()
        currentServiceItemID = serviceItemID
        localItemStarts[serviceItemID] = now
        if localServiceStart == nil { localServiceStart = now }
        refresh()
    }

    private func armLocalTimingEnd(firedItemID: String) {
        localTimingWake?.cancel()
        let now = Date()
        let rows = currentService.map { model.runOfShow($0) } ?? []
        let endsAt = ServiceTrackingTimers.localTimingEnds(
            firstFireAt: localServiceStart ?? now,
            servicePlannedSeconds: Self.plannedSeconds(rows),
            lastFireAt: now,
            itemPlannedSeconds: TimeInterval(rows.first { $0.id == firedItemID }?.duration ?? 0))
        localTimingWake = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.localTiming != nil else { return }
            DiagnosticsStore.shared.note("serviceTracking.localTimingEnded", detail: "ended \(endsAt)")
            self.clearLocalTiming()
        }
    }

    private static func plannedSeconds(_ rows: [ServiceItem]) -> TimeInterval {
        ServiceTrackingTimers.plannedSeconds(durations: rows.filter { $0.itemKind != .header }.map(\.duration))
    }

    @ObservationIgnored private var localTimingWake: Task<Void, Never>?

    var localTiming: ServiceTrackingTimers.LocalTiming? {
        guard let service = currentService else { return nil }
        return ServiceTrackingTimers.localTiming(fired: predictedItem(service: service, now: Date()) != nil)
    }

    func clearLocalTiming() {
        localItemStarts = [:]
        currentServiceItemID = nil
        localServiceStart = nil
        refresh()
    }

    var currentRow: ServiceItem? {
        guard let service = currentService, let id = currentServiceItemID else { return nil }
        return service.items.first { $0.id == id }
    }

    var nextRow: ServiceItem? {
        guard let service = currentService, let current = currentRow else { return nil }
        return ServiceRunOrder.nextFireable(in: model.runOfShow(service), after: current.id)
    }

    private var currentService: Service? {
        model.currentServiceID.flatMap { try? model.service($0) }
    }

    private func arm() {
        generation += 1
        let gen = generation
        withObservationTracking {
            _ = model.currentServiceID

            _ = model.fillVersion(of: .service)
            _ = controls?.media.rowsVersion
            _ = controls?.liveContextID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.refresh()
                self.arm()
            }
        }
    }

    private func refresh() {
        guard let controls else { return }
        if model.currentServiceID != lastServiceID {
            lastServiceID = model.currentServiceID
            localItemStarts = [:]
            currentServiceItemID = nil
            localServiceStart = nil
        }
        controls.timers.setSystemTimers(snapshots(now: Date()))
    }

    private var lastServiceID: String?

    func snapshots(now: Date) -> [TimerSnapshot] {
        var result: [TimerSnapshot] = []
        let service = currentService
        result += localItem(predictedItem(service: service, now: now), now: now)
        result += localSpans(service: service, now: now)
        result += videoTimers(now: now)
        return result
    }

    private struct PredictedItem {
        var item: ServiceItem
        var startedAt: Date
    }

    private func predictedItem(service: Service?, now: Date) -> PredictedItem? {
        guard let service, let id = currentServiceItemID, let startedAt = localItemStarts[id],
              let item = service.items.first(where: { $0.id == id })
        else { return nil }
        return PredictedItem(item: item, startedAt: startedAt)
    }

    private func localItem(_ predicted: PredictedItem?, now: Date) -> [TimerSnapshot] {
        guard let predicted else {
            return [ServiceTrackingTimers.idle(.item, .remaining), ServiceTrackingTimers.idle(.item, .elapsed)]
        }
        let planned = TimeInterval(predicted.item.duration ?? 0)
        let since = now.timeIntervalSince(predicted.startedAt)
        return [
            ServiceTrackingTimers.remaining(.item, plannedSeconds: planned, remainingSeconds: planned > 0 ? planned - since : nil, running: true, now: now),
            ServiceTrackingTimers.elapsed(.item, elapsedSeconds: since, limitSeconds: planned, running: true, now: now),
        ]
    }

    private func localSpans(service: Service?, now: Date) -> [TimerSnapshot] {
        var idle: [TimerSnapshot] = []
        for subject in [ServiceTrackingTimers.Subject.section, .service] {
            idle += [ServiceTrackingTimers.idle(subject, .remaining), ServiceTrackingTimers.idle(subject, .elapsed)]
        }
        guard let service, let currentID = currentServiceItemID, let serviceStart = localServiceStart else { return idle }
        let rows = model.runOfShow(service)
        guard let index = rows.firstIndex(where: { $0.id == currentID }) else { return idle }
        let sectionStart = rows[..<index].lastIndex { $0.itemKind == .header }.map { $0 + 1 } ?? 0
        let sectionEnd = rows[(index + 1)...].firstIndex { $0.itemKind == .header } ?? rows.endIndex
        let section = rows[sectionStart..<sectionEnd].filter { $0.itemKind != .header }
        let sectionPlanned = ServiceTrackingTimers.plannedSeconds(durations: section.map(\.duration))
        let sectionElapsed = section.compactMap { localItemStarts[$0.id] }.min().map { now.timeIntervalSince($0) } ?? 0
        let servicePlanned = Self.plannedSeconds(rows)
        let serviceElapsed = now.timeIntervalSince(serviceStart)
        return [
            ServiceTrackingTimers.remaining(.section, plannedSeconds: sectionPlanned, remainingSeconds: sectionPlanned > 0 ? sectionPlanned - sectionElapsed : nil, running: true, now: now),
            ServiceTrackingTimers.elapsed(.section, elapsedSeconds: sectionElapsed, limitSeconds: sectionPlanned, running: true, now: now),
            ServiceTrackingTimers.remaining(.service, plannedSeconds: servicePlanned, remainingSeconds: servicePlanned > 0 ? servicePlanned - serviceElapsed : nil, running: true, now: now),
            ServiceTrackingTimers.elapsed(.service, elapsedSeconds: serviceElapsed, limitSeconds: servicePlanned, running: true, now: now),
        ]
    }

    private func videoTimers(now: Date) -> [TimerSnapshot] {
        guard let countdown = render.confidenceInfo.videoCountdown else {
            return [ServiceTrackingTimers.idle(.video, .remaining), ServiceTrackingTimers.idle(.video, .elapsed)]
        }
        let position = countdown.position + (countdown.isPlaying ? now.timeIntervalSince(countdown.anchoredAt) : 0)
        return [
            ServiceTrackingTimers.remaining(.video, plannedSeconds: countdown.duration, remainingSeconds: countdown.duration - position, running: countdown.isPlaying, now: now),
            ServiceTrackingTimers.elapsed(.video, elapsedSeconds: position, limitSeconds: countdown.duration, running: countdown.isPlaying, now: now),
        ]
    }
}
