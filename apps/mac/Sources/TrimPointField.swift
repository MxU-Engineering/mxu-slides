import SlideScene
import SwiftUI

struct TrimPointField: View {
    let label: String
    let value: Double?

    var placeholder = "—"
    let commit: (Double?) -> Bool

    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var pauseToken = 0

    var body: some View {
        TextField(label, text: $draft, prompt: Text(placeholder))
            .labelsHidden()
            .focused($focused)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .onAppear { draft = shown }
            .onChange(of: value) {
                if !focused { draft = shown }
            }

            .onSubmit { focused = false }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { apply() }
            }
            .onChange(of: draft) {
                pauseToken += 1
                let token = pauseToken
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    if token == pauseToken, focused { landWhileTyping() }
                }
            }
            .onDisappear {
                if draft != shown { apply() }
            }
            .help("Type a time like 1:05.5, or clear it to use the \(label == "In" ? "start" : "end").")
    }

    private var shown: String {
        value.map(MediaTrimEdit.timecode) ?? ""
    }

    private func landWhileTyping() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text != shown, let seconds = MediaTrimEdit.seconds(fromTimecode: text) {
            _ = commit(seconds)
        }
    }

    private func apply() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        let seconds = MediaTrimEdit.seconds(fromTimecode: text)
        if text != shown, (text.isEmpty || seconds != nil), commit(text.isEmpty ? nil : seconds) {
            draft = seconds.map(MediaTrimEdit.timecode) ?? ""
        } else {
            draft = shown
        }
    }
}
