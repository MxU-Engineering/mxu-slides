import AppKit
import PresenterCore
import SwiftUI

struct NoteFollowSlide {
    let deck: Presentation
    let slide: Slide
    let number: Int

    var isBlank = false
}

struct NoteFollowModel {
    var version = 0
    var body = NoteBody(blocks: [], plainText: "")
    var lines: [NoteFollowAlong.Line] = []
    var slides: [String: NoteFollowSlide] = [:]
    var lineBySlide: [String: String] = [:]
    var lineByBlock: [Int: String] = [:]

    var passages: [(blocks: ClosedRange<Int>, rows: [NoteFollowAlong.Row])] = []
}

@MainActor
final class NoteFollowScroller {
    var scrollTo: ((String) -> Void)?
}

struct NoteFollowAlongView: View, Equatable {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let follow: NoteFollowModel
    let fontSize: Double
    let query: String
    let fitsContent: Bool
    let live: NoteSlideLive
    let scroller: NoteFollowScroller

    @State private var width: CGFloat = 0
    @State private var prose: [String: NSAttributedString] = [:]
    @State private var placed = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.follow.version == rhs.follow.version && lhs.fontSize == rhs.fontSize && lhs.query == rhs.query
            && lhs.fitsContent == rhs.fitsContent
    }

    private var lane: CGFloat { CGFloat(NoteFollowAlong.laneWidth(view: Double(width))) }
    private static let gap: CGFloat = 12
    private static let inset: CGFloat = 8

    private static let maxWidth: CGFloat = 980

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if fitsContent {
                    content
                } else {
                    ScrollView { content }
                }
            }
            .onAppear {
                scroller.scrollTo = { id in proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .task(id: follow.version) {
                guard !placed, !follow.lines.isEmpty else { return }
                placed = true
                await Task.yield()
                if let id = live.slideID, let line = follow.lineBySlide[id] { scroller.scrollTo?(line) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, Self.maxWidth) } action: { width = $0 }
        .task(id: "\(follow.version):\(fontSize):\(query)") { renderProse() }
    }

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(follow.lines) { line in
                lineView(line).id(line.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.maxWidth + 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func lineView(_ line: NoteFollowAlong.Line) -> some View {
        switch line.content {
        case .prose:
            if let text = prose[line.id] {
                laned { NoteProseText(text: text) }
                    .padding(.vertical, 6)
            }
        case .row(let passageKind, let row, let first, let last):
            passageRow(row, kind: passageKind, first: first, last: last)
        case .slide(let slot, let inNote):
            if let resolved = follow.slides[slot.slideId] {
                loneSlide(resolved, inNote: inNote)
            }
        }
    }

    private func laned(@ViewBuilder _ text: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            Color.clear.frame(width: lane, height: 1)
            text().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
    }

    private func passageRow(_ row: NoteFollowAlong.Row, kind passageKind: String, first: Bool, last: Bool) -> some View {
        let color = Color(nsColor: NoteDocumentTextView.kindColor(passageKind))
        let resolved = row.slides.compactMap { follow.slides[$0.slideId] }
        let blank = row.kind == SlideKind.blank.rawValue
        return HStack(alignment: .top, spacing: Self.gap) {
            VStack(spacing: 6) {
                ForEach(resolved, id: \.slide.id) { thumbnail($0) }
            }
            .frame(width: lane)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(resolved.map { "\($0.number)" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                    Text(blank ? "BLANK" : NoteDocumentTextView.kindLabel(passageKind).uppercased())
                        .foregroundStyle(blank ? Color.secondary : color)
                        .kerning(0.5)
                    NoteFollowLiveTag(slideIDs: resolved.map(\.slide.id), live: live)
                }
                .font(.system(size: 10, weight: .bold))
                if let words = row.words, !words.isEmpty {
                    Text(verbatim: words)
                        .font(.system(size: fontSize))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, first ? Self.inset : 6)
        .padding(.bottom, last ? Self.inset : 6)
        .overlay(alignment: .top) {
            if !first {
                Line()
                    .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(height: 1)
                    .padding(.horizontal, Self.inset)
            }
        }
        .background { NoteFollowOutline(color: color, top: first, bottom: last) }
        .padding(.top, first ? 8 : 0)
        .padding(.bottom, last ? 8 : 0)
    }

    private func loneSlide(_ resolved: NoteFollowSlide, inNote: Bool) -> some View {
        let greyed = !inNote && !resolved.isBlank
        return HStack(alignment: .top, spacing: Self.gap) {
            thumbnail(resolved)
                .opacity(greyed ? 0.45 : 1)
                .frame(width: lane)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(resolved.number)").foregroundStyle(.secondary)
                    Text(resolved.isBlank ? "BLANK" : inNote ? "SLIDE" : "NOT IN THE NOTE").foregroundStyle(.tertiary).kerning(0.5)
                    NoteFollowLiveTag(slideIDs: [resolved.slide.id], live: live)
                }
                .font(.system(size: 10, weight: .bold))
                if !resolved.slide.name.isEmpty {
                    Text(resolved.slide.name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 6)
    }

    private func thumbnail(_ resolved: NoteFollowSlide) -> some View {
        NoteFollowTile(model: model, render: render, controls: controls, resolved: resolved, width: lane, live: live)
            .help("Fire slide \(resolved.number)")
    }

    private func renderProse() {
        let style = NoteReaderStyle(fontSize: fontSize, compact: false, slideDisplay: .hidden)
        var rendered: [String: NSAttributedString] = [:]
        for line in follow.lines {
            guard case .prose(let blocks) = line.content else { continue }
            let part = NoteBody(blocks: blocks.compactMap { follow.body.blocks.indices.contains($0) ? follow.body.blocks[$0] : nil }, plainText: "")
            let drawn = NoteDocumentRenderer.render(part, style: style, query: query, slides: nil, live: live)
            rendered[line.id] = drawn.text
        }
        prose = rendered
    }
}

private struct NoteFollowOutline: View {
    let color: Color
    let top: Bool
    let bottom: Bool

    var body: some View {
        Color.clear.overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.85), lineWidth: 1.5)
                .padding(.top, top ? 0 : -10)
                .padding(.bottom, bottom ? 0 : -10)
        }
        .clipped()
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct NoteFollowTile: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let resolved: NoteFollowSlide
    let width: CGFloat
    @ObservedObject var live: NoteSlideLive

    var body: some View {
        let aspect = SlideGridMetrics.tileAspect(for: resolved.deck)
        SlideTile(
            model: model, render: render, slide: resolved.slide, index: resolved.number - 1, aspect: aspect,
            presentation: resolved.deck, theme: model.theme(for: resolved.slide, in: resolved.deck),
            arrangementId: nil, showsSectionLabel: true, controls: controls,
            roundedCorners: UserDefaults.standard.object(forKey: "slideGrid.roundedCorners") as? Bool ?? true,
            hideScopedBackgrounds: false,
            liveOverride: live.slideID == resolved.slide.id
        ) {
            if let controls {
                NoteSlideCard.fire(resolved.slide, in: resolved.deck, index: resolved.number - 1, model: model, controls: controls)
            }
        }
        .frame(width: width, height: width / aspect + 4 + SlideGridMetrics.labelHeight)
    }
}

private struct NoteFollowLiveTag: View {
    let slideIDs: [String]
    @ObservedObject var live: NoteSlideLive

    var body: some View {
        if let id = live.slideID, slideIDs.contains(id) {
            Text("LIVE").foregroundStyle(.green)
        }
    }
}

private struct NoteProseText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.attributedStringValue != text { field.attributedStringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        return CGSize(width: width, height: ceil(height))
    }
}
