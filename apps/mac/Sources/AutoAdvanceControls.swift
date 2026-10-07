import PresenterCore
import SwiftUI

struct AutoAdvanceControls: View {
    @Binding var advance: AutoAdvance?

    var mediaScope = false
    var showsCountFrom = true

    var body: some View {
        Toggle("Auto Advance", isOn: enabledBinding())
        if let current = advance {
            if !mediaScope || showsCountFrom {
                Picker("Count From", selection: modeBinding()) {
                    Text(mediaScope ? "This Fire" : "This Slide Firing").tag(false)
                    Text("Video End").tag(true)
                }
            }
            SecondsRow(label: "Delay", seconds: delayBinding(), range: -30 ... 3600)
            if !mediaScope {
                Toggle("Loop to First Slide", isOn: loopBinding())
            }
            Text(caption(for: current))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func caption(for current: AutoAdvance) -> String {
        if mediaScope {
            return (current.afterPlayback ?? false)
                ? "Fires the next run-order item this long after the video finishes — 0 cuts straight at the end; NEGATIVE starts the next item early so its transition crossfades the ending."
                : "Fires the next run-order item this long after this media fires."
        }
        return (current.afterPlayback ?? false)
            ? "Fires the next slide this long after this slide's FOREGROUND video finishes — 0 cuts straight at the end; NEGATIVE starts the next slide early so its transition crossfades the ending. Background videos are ambient and don't drive the advance (time those from the fire instead). On the last slide, Loop wraps back to the first; without Loop the service keeps walking into the next item."
            : "Fires the next slide this long after this one fires. On the last slide, Loop wraps back to the first; without Loop the service keeps walking into the next item."
    }

    private func enabledBinding() -> Binding<Bool> {
        Binding(
            get: { advance != nil },
            set: { advance = $0 ? AutoAdvance(delaySeconds: 7) : nil }
        )
    }

    private func modeBinding() -> Binding<Bool> {
        Binding(
            get: { advance?.afterPlayback ?? false },
            set: { afterPlayback in
                guard var current = advance else { return }

                current.afterPlayback = afterPlayback ? true : nil
                if afterPlayback {
                    current.delaySeconds = 0
                } else if current.delaySeconds == 0 {
                    current.delaySeconds = 7
                }
                advance = current
            }
        )
    }

    private func delayBinding() -> Binding<Double> {
        Binding(
            get: { advance?.delaySeconds ?? 0 },
            set: { seconds in
                guard var current = advance else { return }

                let floor: Double = (current.afterPlayback ?? false) ? -30 : 0
                current.delaySeconds = max(floor, seconds)
                advance = current
            }
        )
    }

    private func loopBinding() -> Binding<Bool> {
        Binding(
            get: { advance?.loopToStart ?? false },
            set: { loops in
                guard var current = advance else { return }

                current.loopToStart = loops ? true : nil
                advance = current
            }
        )
    }
}

struct SecondsRow: View {
    let label: String
    @Binding var seconds: Double
    var range: ClosedRange<Double> = 0 ... 3600

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(
                "", value: $seconds,
                format: .number.precision(.fractionLength(0 ... 1))
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            Text("seconds")
                .foregroundStyle(.secondary)
            Stepper("", value: $seconds, in: range, step: 1)
                .labelsHidden()
        }
    }
}

struct AutoAdvanceSheet: View {
    let slideName: String
    @Binding var advance: AutoAdvance?

    var presentationScope = false

    var mediaScope = false
    var showsCountFrom = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(16)
            Form {
                Section {
                    AutoAdvanceControls(
                        advance: $advance,
                        mediaScope: mediaScope, showsCountFrom: showsCountFrom
                    )
                } footer: {
                    if presentationScope {
                        Text("Applies to every slide in this presentation. A slide with its own Auto Advance keeps its own timing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 400, height: presentationScope ? 360 : 320)
    }

    private var title: String {
        if presentationScope {
            return slideName.isEmpty ? "Slide Show" : "Slide Show: \(slideName)"
        }
        return slideName.isEmpty ? "Auto Advance" : "Auto Advance: \(slideName)"
    }
}
