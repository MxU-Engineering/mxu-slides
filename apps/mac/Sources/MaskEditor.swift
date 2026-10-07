import AppKit
import OutputEngine
import RenderEngine
import SlideScene
import SwiftUI

struct OutputMaskEditor: View {
    let outputs: OutputManager
    let render: RenderContext
    let screen: PlaceholderScreen

    @State private var expanded = false

    @State private var drawing = false

    @State private var editingMaskID: UUID?

    private var masks: [OutputMask] {
        outputs.masks(forScreen: screen.id)
    }

    private func update(_ mutate: (inout [OutputMask]) -> Void) {
        var value = masks
        mutate(&value)
        outputs.setMasks(value, forScreen: screen.id)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(masks) { mask in
                    maskRow(mask)
                }
                if drawing || editingMaskID != nil {
                    penCanvas
                }
                HStack {
                    Button(drawing ? "Cancel Drawing" : "Add Mask") {
                        editingMaskID = nil
                        drawing.toggle()
                    }
                    .font(.caption)
                    if drawing {
                        Text("Click to place points, drag for curves — click the first point or press Return to close.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Masks")
                    .font(.caption.weight(.medium))
                if !masks.isEmpty {
                    Text("\(masks.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !outputs.activeMasks(forScreen: screen.id).isEmpty {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .help("Masks are covering this screen right now")
                }
            }
        }
        .onChange(of: expanded) { _, open in
            if !open {
                drawing = false
                editingMaskID = nil
            }
        }
    }

    private func maskRow(_ mask: OutputMask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                CommittedTextField(
                    "Name",
                    text: Binding(
                        get: { mask.name },
                        set: { newName in
                            update { library in
                                guard let index = library.firstIndex(where: { $0.id == mask.id })
                                else { return }
                                library[index].name = newName
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(width: 110)
                Picker(
                    "",
                    selection: Binding(
                        get: { mask.mode },
                        set: { newMode in
                            update { library in
                                guard let index = library.firstIndex(where: { $0.id == mask.id })
                                else { return }
                                library[index].mode = newMode
                            }
                        }
                    )
                ) {
                    Text("Black Out").tag(OutputMask.Mode.out)
                    Text("Show Only").tag(OutputMask.Mode.in)
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
                .help("Black Out darkens inside the shape; Show Only darkens everything else.")
                Toggle(
                    "Always On",
                    isOn: Binding(
                        get: { mask.alwaysOn },
                        set: { newValue in
                            update { library in
                                guard let index = library.firstIndex(where: { $0.id == mask.id })
                                else { return }
                                library[index].alwaysOn = newValue
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("On = room geometry, applies regardless of preset. Off = only while an Output Preset activates it.")
                Button(editingMaskID == mask.id ? "Done" : "Edit Points") {
                    drawing = false
                    editingMaskID = editingMaskID == mask.id ? nil : mask.id
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button(role: .destructive) {
                    if editingMaskID == mask.id { editingMaskID = nil }
                    update { library in library.removeAll { $0.id == mask.id } }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Delete this mask")
            }
            HStack(spacing: 8) {
                Text("Feather")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { mask.feather },
                        set: { newValue in
                            update { library in
                                guard let index = library.firstIndex(where: { $0.id == mask.id })
                                else { return }
                                library[index].feather = newValue
                            }
                        }
                    ),
                    in: 0...0.25
                )
                .controlSize(.mini)
                Text(String(format: "%.2f", mask.feather))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private var penCanvas: some View {
        ZStack {
            PlaceholderScreenPreview(screen: screen, compositor: render.compositor)
            MaskPenSurface(
                mode: editingMaskID.flatMap { id in
                    masks.first { $0.id == id }.flatMap { mask in
                        PathAnchorCodec.parse(
                            mask.pathData, in: CGRect(x: 0, y: 0, width: 1, height: 1)
                        ).map { MaskPenSurface.Mode.edit(anchors: $0.anchors, closed: $0.closed) }
                    }
                } ?? .draw,
                onComplete: { anchors, closed in
                    guard let pathData = PathAnchorCodec.encodeAbsolute(
                        anchors: anchors, closed: closed)
                    else { return }
                    if let id = editingMaskID {
                        update { library in
                            guard let index = library.firstIndex(where: { $0.id == id })
                            else { return }
                            library[index].pathData = pathData
                        }
                    } else {
                        update { library in
                            library.append(OutputMask(
                                name: "Mask \(library.count + 1)", pathData: pathData))
                        }
                        drawing = false
                    }
                },
                onCancel: { drawing = false }
            )
        }
        .aspectRatio(
            CGFloat(screen.width) / CGFloat(max(screen.height, 1)), contentMode: .fit
        )
        .frame(maxHeight: 260)
        .clipShape(RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
        .onAppear { outputs.setCanvasWake(true, forScreen: screen.id) }
        .onDisappear { outputs.setCanvasWake(false, forScreen: screen.id) }
    }
}

private struct MaskPenSurface: NSViewRepresentable {
    enum Mode: Equatable {
        case draw
        case edit(anchors: [PathAnchor], closed: Bool)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.draw, .draw): true
            case (.edit(let la, let lc), .edit(let ra, let rc)): la == ra && lc == rc
            default: false
            }
        }
    }

    let mode: Mode
    let onComplete: ([PathAnchor], Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MaskPenNSView {
        let view = MaskPenNSView()
        view.onComplete = onComplete
        view.onCancel = onCancel
        view.apply(mode: mode)
        return view
    }

    func updateNSView(_ view: MaskPenNSView, context: Context) {
        view.onComplete = onComplete
        view.onCancel = onCancel

        if view.appliedMode != mode, !view.dragInProgress {
            view.apply(mode: mode)
        }
    }
}

final class MaskPenNSView: NSView {
    var onComplete: (([PathAnchor], Bool) -> Void)?
    var onCancel: (() -> Void)?

    fileprivate var appliedMode: MaskPenSurface.Mode = .draw
    private(set) var dragInProgress = false

    private var anchors: [PathAnchor] = []
    private var closed = false

    private var isDrawing = true
    private var hover: CGPoint?

    private enum DragTarget {
        case anchor(Int)
        case handleIn(Int)
        case handleOut(Int)
        case penHandles(Int)  
    }
    private var dragTarget: DragTarget?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    fileprivate func apply(mode: MaskPenSurface.Mode) {
        appliedMode = mode
        switch mode {
        case .draw:
            anchors = []
            closed = false
            isDrawing = true
        case .edit(let seeded, let seededClosed):
            anchors = seeded
            closed = seededClosed
            isDrawing = false
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    private func unitPoint(_ event: NSEvent) -> CGPoint {
        let view = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(view.x / bounds.width, 0), 1),
            y: min(max(view.y / bounds.height, 0), 1)
        )
    }

    private func viewPoint(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: unit.x * bounds.width, y: unit.y * bounds.height)
    }

    private func hits(_ unit: CGPoint, _ candidate: CGPoint) -> Bool {
        let a = viewPoint(unit)
        let b = viewPoint(candidate)
        return hypot(a.x - b.x, a.y - b.y) <= 7
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = unitPoint(event)
        if isDrawing {
            if anchors.count >= 3, let first = anchors.first, hits(first.point, point) {
                finish(close: true)
                return
            }
            if event.clickCount == 2, anchors.count >= 3 {
                finish(close: true)
                return
            }
            anchors.append(PathAnchor(point: point))
            dragTarget = .penHandles(anchors.count - 1)
            dragInProgress = true
            needsDisplay = true
            return
        }

        for (index, anchor) in anchors.enumerated() {
            if let h = anchor.handleIn, hits(h, point) {
                dragTarget = .handleIn(index)
                dragInProgress = true
                return
            }
            if let h = anchor.handleOut, hits(h, point) {
                dragTarget = .handleOut(index)
                dragInProgress = true
                return
            }
        }
        for (index, anchor) in anchors.enumerated() where hits(anchor.point, point) {
            dragTarget = .anchor(index)
            dragInProgress = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragTarget else { return }
        let point = unitPoint(event)
        switch dragTarget {
        case .anchor(let index):
            let delta = CGPoint(
                x: point.x - anchors[index].point.x, y: point.y - anchors[index].point.y)
            anchors[index].point = point
            anchors[index].handleIn = anchors[index].handleIn.map {
                CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
            anchors[index].handleOut = anchors[index].handleOut.map {
                CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
        case .handleIn(let index):
            anchors[index].handleIn = point
        case .handleOut(let index):
            anchors[index].handleOut = point
        case .penHandles(let index):

            let anchor = anchors[index].point
            anchors[index].handleOut = point
            anchors[index].handleIn = CGPoint(
                x: anchor.x * 2 - point.x, y: anchor.y * 2 - point.y)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = nil
        dragInProgress = false
        if !isDrawing {

            onComplete?(anchors, closed)
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard isDrawing else { return }
        hover = unitPoint(event)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  
            if isDrawing, anchors.count >= 3 { finish(close: true) } else { super.keyDown(with: event) }
        case 53:  
            if isDrawing {
                anchors = []
                needsDisplay = true
                onCancel?()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func finish(close: Bool) {
        guard anchors.count >= 3 else { return }
        closed = close
        onComplete?(anchors, close)
        if isDrawing { anchors = [] }
        hover = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !anchors.isEmpty else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: viewPoint(anchors[0].point))
        let segmentCount = closed && !isDrawing ? anchors.count : anchors.count - 1
        for i in 0..<max(segmentCount, 0) {
            let from = anchors[i]
            let to = anchors[(i + 1) % anchors.count]
            if from.handleOut == nil, to.handleIn == nil {
                path.line(to: viewPoint(to.point))
            } else {
                path.curve(
                    to: viewPoint(to.point),
                    controlPoint1: viewPoint(from.handleOut ?? from.point),
                    controlPoint2: viewPoint(to.handleIn ?? to.point)
                )
            }
        }
        if isDrawing, let hover, let last = anchors.last {
            let rubber = NSBezierPath()
            rubber.move(to: viewPoint(last.point))
            if let out = last.handleOut {
                rubber.curve(
                    to: viewPoint(hover),
                    controlPoint1: viewPoint(out), controlPoint2: viewPoint(hover))
            } else {
                rubber.line(to: viewPoint(hover))
            }
            rubber.lineWidth = 1
            NSColor.white.withAlphaComponent(0.5).setStroke()
            rubber.stroke()
        }

        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 3
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 1.2
        path.stroke()

        for anchor in anchors {
            for handle in [anchor.handleIn, anchor.handleOut].compactMap({ $0 }) {
                let line = NSBezierPath()
                line.move(to: viewPoint(anchor.point))
                line.line(to: viewPoint(handle))
                line.lineWidth = 0.8
                NSColor.white.withAlphaComponent(0.45).setStroke()
                line.stroke()
                let dot = NSBezierPath(
                    ovalIn: NSRect(x: viewPoint(handle).x - 3, y: viewPoint(handle).y - 3,
                                   width: 6, height: 6))
                NSColor.white.setFill()
                dot.fill()
            }
            let square = NSRect(
                x: viewPoint(anchor.point).x - 3.5, y: viewPoint(anchor.point).y - 3.5,
                width: 7, height: 7)
            NSColor.white.setFill()
            NSBezierPath(rect: square).fill()
            NSColor.black.withAlphaComponent(0.7).setStroke()
            NSBezierPath(rect: square).stroke()
        }
    }
}
