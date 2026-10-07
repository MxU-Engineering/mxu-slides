import PresenterCore
import SwiftUI

struct ReflowSheet: View {
    let model: SlideEditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var linesPerSlide = 2

    var body: some View {

        let parsed = Reflow.parse(text, linesPerSlide: linesPerSlide)
        VStack(spacing: 0) {
            HStack {
                Text("Reflow")
                    .font(.headline)
                Spacer()
                Text("Label lines (Verse 1, Chorus…) start sections; blank lines split slides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            HSplitView {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                preview(parsed)
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 14) {
                Stepper("Lines per slide: \(linesPerSlide)", value: $linesPerSlide, in: 1...8)
                    .fixedSize()
                Spacer()
                Text(summary(parsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.applyReflow(text: text, linesPerSlide: linesPerSlide)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed.sections.allSatisfy(\.slides.isEmpty))
            }
            .padding(10)
        }
        .frame(minWidth: 700, minHeight: 460)
        .onAppear {
            text = model.reflowSeedText
        }
    }

    private func summary(_ parsed: Reflow.ParseResult) -> String {
        let slideCount = parsed.order.reduce(0) { $0 + parsed.sections[$1].slides.count }
        return "\(parsed.sections.count) sections · \(slideCount) slides"
    }

    private func preview(_ parsed: Reflow.ParseResult) -> some View {
        ReflowPreview(parsed: parsed, emptyTitle: "Paste Lyrics or Notes", emptyDescription: "Slides appear here as you type.")
    }
}

struct ReflowPreview: View {
    let parsed: Reflow.ParseResult
    var emptyTitle = "No Lyrics"
    var emptyDescription = ""

    var arrangementNames: [String]? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parsed.sections.enumerated()), id: \.offset) { sectionIndex, section in
                    Text(section.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, sectionIndex == 0 ? 0 : 8)
                    if section.slides.isEmpty {
                        Text("Empty section")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(section.slides.enumerated()), id: \.offset) { _, slide in
                        Text(slide)
                            .font(.callout)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: CornerStandard.element, style: .continuous))
                    }
                }
                if let order = arrangementNames ?? (hasRepeats ? parsed.order.map { parsed.sections[$0].name } : nil) {
                    Text("Arrangement")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Text(order.joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if parsed.sections.isEmpty {
                ContentUnavailableView(
                    emptyTitle, systemImage: "text.alignleft",
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private var hasRepeats: Bool {
        parsed.order.count != Set(parsed.order).count
    }
}
