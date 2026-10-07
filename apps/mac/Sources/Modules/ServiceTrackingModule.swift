import PresenterCore
import SlideScene
import SwiftUI

struct ServiceTrackingModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let timers = controls.timers
        let tracking = controls.serviceTracking
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeaderBar {

            } trailing: {
                EmptyView()
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 8) {
                    currentRow(tracking: tracking, timers: timers, at: now)
                    spanRow("Section", subject: .section, timers: timers, at: now)
                    spanRow("Service", subject: .service, timers: timers, at: now)
                    nextRow(tracking: tracking)
                }
            }
            if tracking?.localTiming != nil {
                localTimingNote(tracking: tracking)
            } else if model.currentServiceID == nil {
                Text("Select a service to track it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if tracking?.currentRow == nil {
                Text("Fire the first item to start tracking.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func localTimingNote(tracking: ServiceTimingController?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Timed on this Mac from your fires. The timers stop when the planned service would end (later if an item runs over).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !runOnly {
                Button("Clear") { tracking?.clearLocalTiming() }
                    .controlSize(.small)
                    .help("Stop these timers on this Mac")
            }
        }
    }

    private func currentRow(tracking: ServiceTimingController?, timers: TimersController, at now: Date) -> some View {
        let remaining = timers.snapshot(id: ServiceTrackingTimers.id(.item, .remaining))
        let elapsed = timers.snapshot(id: ServiceTrackingTimers.id(.item, .elapsed))
        let name = tracking?.currentRow?.name ?? "No item"
        return VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let remaining {
                    Text(remaining.displayString(at: now))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundStyle(urgencyColor(remaining, at: now))
                }
                if let elapsed {
                    Text("+\(elapsed.displayString(at: now))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let remaining, remaining.isRunning, remaining.value(at: now) < 0 {
                    Text("late by \(TimerSnapshot.timecode(-remaining.value(at: now)))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func spanRow(_ title: String, subject: ServiceTrackingTimers.Subject, timers: TimersController, at now: Date) -> some View {
        let remaining = timers.snapshot(id: ServiceTrackingTimers.id(subject, .remaining))
        let elapsed = timers.snapshot(id: ServiceTrackingTimers.id(subject, .elapsed))
        return HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let elapsed {
                Text("+\(elapsed.displayString(at: now))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let remaining {
                Text(remaining.displayString(at: now))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(urgencyColor(remaining, at: now))
            }
        }
    }

    @ViewBuilder
    private func nextRow(tracking: ServiceTimingController?) -> some View {
        if let next = tracking?.nextRow {
            HStack(spacing: 6) {
                Text("Next · \(next.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let duration = next.duration, duration > 0 {
                    Text(TimerSnapshot.timecode(TimeInterval(duration)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func urgencyColor(_ timer: TimerSnapshot, at now: Date) -> Color {
        switch timer.urgency(at: now) {
        case .normal: .primary
        case .warning: .orange
        case .overrun: .red
        }
    }
}
