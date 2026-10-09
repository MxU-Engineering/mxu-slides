import SwiftUI

struct FeedbackView: View {
    let model: AppModel?
    let close: () -> Void

    @State private var feedback = FeedbackController.shared
    @State private var message = ""

    @FocusState private var noteFocused: Bool

    private var isWorking: Bool {
        if case .working = feedback.phase { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(feedback.lastRunCrashed ? "MxU Slides quit unexpectedly" : "Report a Problem")
                .font(.title3.weight(.semibold))
            Text(feedback.lastRunCrashed
                ? "A diagnostics report with the crash log helps track it down. What were you doing when it happened?"
                : "What happened, and what did you expect? The more specific, the faster we can fix it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .focused($noteFocused)
                .onAppear { DispatchQueue.main.async { noteFocused = true } }
            DisclosureGroup("What is included") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your note, this Mac's summary below, and the last 7 days of MxU Slides diagnostics: activity breadcrumbs (these can include file and song names), performance samples, and macOS crash reports for this app. No slides, media or passwords.")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(feedback.systemInfo(model: model).sorted(by: { $0.key < $1.key }), id: \.key) { row in
                        Text("\(row.key): \(row.value)")
                            .font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .font(.callout)
            status
            HStack {
                Text("The report saves to Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Report…") {
                    Task { await feedback.saveReport(message: message, model: model) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private var status: some View {
        switch feedback.phase {
        case .idle:
            EmptyView()
        case .working(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout)
            }
        case .saved(let url):
            Label("Saved \(url.lastPathComponent) to Downloads.", systemImage: "tray.and.arrow.down")
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Label("Could not save: \(text)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dismiss() {
        feedback.reset()
        close()
    }
}
