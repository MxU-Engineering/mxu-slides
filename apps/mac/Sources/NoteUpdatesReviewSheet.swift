import PresenterCore
import SwiftUI

struct NoteUpdatesReviewSheet: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let noteID: String
    @State private var busy: Set<String> = []

    private var updates: [NotePendingUpdate] { model.liveUpdates[noteID]?.updates ?? [] }
    private var deck: Presentation? {
        model.liveNoteByDeck.first { $0.value == noteID }.flatMap { model.presentation($0.key) }
    }
    private var liveSlideID: String? { controls?.liveSlideID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Changes from the notes").font(.title3.weight(.semibold))
                if !updates.isEmpty {
                    Text("\(updates.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if updates.count > 1 {
                    Button("Skip All") { run(updates) { await model.skipNoteUpdate(noteID: noteID, updateID: $0.id) } }
                    Button("Apply All") { run(updates.filter { !waitsForLive($0) }) { await model.applyNoteUpdate(noteID: noteID, updateID: $0.id) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            Divider()
            if let deck, !updates.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(updates) { update in
                            row(update, deck: deck)
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("The slides match the notes.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.reviewingNoteID = nil }
                    .keyboardShortcut(updates.count > 1 ? .cancelAction : .defaultAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 600)
    }

    private func row(_ update: NotePendingUpdate, deck: Presentation) -> some View {
        let current = update.slideId.flatMap { id in deck.slides.firstIndex { $0.id == id } }
        let waits = waitsForLive(update)
        return HStack(alignment: .center, spacing: 12) {
            if let current {
                thumbnail(deck.slides[current], deck: deck, caption: "Slide \(current + 1) now", dashed: false)
            } else {
                emptyFrame(deck: deck, text: "No slide yet", caption: "New")
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            if update.kind == NotePendingUpdate.remove || update.kind == NotePendingUpdate.orphan {
                emptyFrame(deck: deck, text: "Removed", caption: "After")
            } else if let proposed = preview(update) {
                thumbnail(proposed, deck: deck, caption: afterCaption(update, deck: deck), dashed: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title(update)).font(.callout.weight(.semibold))
                what(update)
                    .font(.callout)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if waits {
                    Label("On screen now. It waits until the slide is off screen.", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Skip") { run([update]) { await model.skipNoteUpdate(noteID: noteID, updateID: $0.id) } }
                Button(verb(update)) { run([update]) { await model.applyNoteUpdate(noteID: noteID, updateID: $0.id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(waits)
            }
            .disabled(busy.contains(update.id))
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.element))
    }

    private func preview(_ update: NotePendingUpdate) -> Slide? {
        guard var slide = update.proposed else { return nil }
        let words = slide.objects.map(\.text).joined(separator: "\n")
        slide.id = "review:\(update.id):\(words.hashValue)"
        return slide
    }

    private func waitsForLive(_ update: NotePendingUpdate) -> Bool {
        update.slideId != nil && update.slideId == liveSlideID
    }

    private func run(_ changes: [NotePendingUpdate], _ action: @escaping (NotePendingUpdate) async -> Void) {
        busy.formUnion(changes.map(\.id))
        Task {
            for change in changes { await action(change) }
            busy.subtract(changes.map(\.id))
        }
    }

    private func verb(_ update: NotePendingUpdate) -> String {
        switch update.kind {
        case NotePendingUpdate.new: "Add"
        case NotePendingUpdate.words: "Update"
        default: "Remove"
        }
    }

    private func title(_ update: NotePendingUpdate) -> String {
        switch update.kind {
        case NotePendingUpdate.new: "New slide"
        case NotePendingUpdate.words: "Words changed"
        default: "Not in the notes any more"
        }
    }

    private func afterCaption(_ update: NotePendingUpdate, deck: Presentation) -> String {
        guard update.kind == NotePendingUpdate.new else { return "From the notes" }
        let after = update.afterSlideId.flatMap { id in deck.slides.firstIndex { $0.id == id } }
        if let after { return "After slide \(after + 1)" }
        return update.afterSlideId == nil ? "At the front" : "After the new slide"
    }

    private func what(_ update: NotePendingUpdate) -> Text {
        let before = (update.before ?? []).map(\.text).joined(separator: " / ")
        switch update.kind {
        case NotePendingUpdate.words:
            let after = (update.after ?? []).map(\.text).joined(separator: " / ")
            var text = AttributedString()
            for (index, piece) in NoteLiveUpdates.wordDiff(before, after).enumerated() {
                var words = AttributedString((index == 0 ? "" : " ") + piece.text)
                switch piece.change {
                case .removed:
                    words.strikethroughStyle = .single
                    words.foregroundColor = .red
                case .added:
                    words.foregroundColor = .green
                    words.inlinePresentationIntent = .stronglyEmphasized
                case .kept:
                    words.foregroundColor = .secondary
                }
                text += words
            }
            return Text(text)
        case NotePendingUpdate.new:
            let words = update.proposed.map { $0.objects.map(\.text).filter { !$0.isEmpty }.joined(separator: " / ") } ?? ""
            return Text(words.isEmpty ? "A picture or video slide" : words).foregroundStyle(.secondary)
        default:
            return Text(before.isEmpty ? "Its passage left the notes." : before).foregroundStyle(.secondary).strikethrough()
        }
    }

    private func thumbnail(_ slide: Slide, deck: Presentation, caption: String, dashed: Bool) -> some View {
        VStack(spacing: 4) {
            SlideThumbnailView(
                model: model, render: render, slide: slide, presentation: deck,
                theme: model.theme(for: slide, in: deck), arrangementId: nil, hideScopedBackgrounds: false)
            .aspectRatio(SlideGridMetrics.tileAspect(for: deck), contentMode: .fit)
            .frame(width: 200)
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(style: StrokeStyle(lineWidth: dashed ? 1.5 : 1, dash: dashed ? [4, 3] : []))
                    .foregroundStyle(dashed ? Color.accentColor : Color.primary.opacity(0.12)))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyFrame(deck: Presentation, text: String, caption: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary)
                .aspectRatio(SlideGridMetrics.tileAspect(for: deck), contentMode: .fit)
                .frame(width: 200)
                .overlay { Text(text).font(.callout).foregroundStyle(.secondary) }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
