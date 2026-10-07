import AppKit
import SwiftUI

struct EditorCanvasMargin: NSViewRepresentable {
    let model: SlideEditorModel

    func makeNSView(context: Context) -> EditorCanvasMarginView {
        EditorCanvasMarginView(model: model)
    }

    func updateNSView(_ nsView: EditorCanvasMarginView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: EditorCanvasMarginView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

@MainActor
final class EditorCanvasMarginView: NSView {
    private let model: SlideEditorModel

    private weak var interaction: EditorInteractionNSView?

    init(model: SlideEditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorCanvasMarginView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    private var canvas: EditorInteractionNSView? {
        if interaction == nil {
            interaction = nearestInteractionView()
            interaction?.margin = self
        }
        return interaction
    }

    private func nearestInteractionView() -> EditorInteractionNSView? {
        var ancestor = superview
        var found: EditorInteractionNSView?
        while found == nil, let view = ancestor {
            found = view.firstDescendant(EditorInteractionNSView.self)
            ancestor = view.superview
        }
        return found
    }

    override func mouseDown(with event: NSEvent) {
        if let canvas, canvas.takesMarginPress {
            canvas.mouseDown(with: event)
        } else {

            model.clearSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        canvas?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        canvas?.mouseUp(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let canvas, let band = canvas.marqueeViewRect,
           let context = NSGraphicsContext.current?.cgContext {
            drawEditorMarquee(convert(band, from: canvas), in: context)
        }
    }
}

private extension NSView {

    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        var found: T?
        for subview in subviews where found == nil {
            found = (subview as? T) ?? subview.firstDescendant(type)
        }
        return found
    }
}
