import AppKit
import PresenterCore
import SlideScene
import SwiftUI

@MainActor
enum DropLatency {
    static var performedAt: ContinuousClock.Instant?

    static var awaitingPaint: Set<String> = []

    static var relaidStamped = false

    static func sincePerform() -> String? {
        performedAt.map { at in
            let elapsed = at.duration(to: .now)
            return elapsed < .seconds(10) ? "\(elapsed)" : nil
        } ?? nil
    }

    static func performed() {
        performedAt = .now
        awaitingPaint = []
        relaidStamped = false
    }

    static func relaid(count: Int) {
        if !relaidStamped, let since = sincePerform() {
            relaidStamped = true
            DiagnosticsStore.shared.note("grid.drop.relaid", detail: "\(since) \(count) slides")
        }
    }

    static func painted(_ slideID: String, detail: String) {
        if awaitingPaint.remove(slideID) != nil, let since = sincePerform() {
            DiagnosticsStore.shared.note("grid.drop.painted", detail: "\(since) \(detail)")
            if awaitingPaint.isEmpty {
                performedAt = nil
            }
        }
    }
}

struct GutterDropDelegate: DropDelegate {
    let enabled: Bool

    var breadcrumb: String = "grid.drop"
    let dropStarted: () -> Void
    let setLine: (Bool) -> Void
    let setRing: (Bool) -> Void
    let performText: (String, Bool) -> Bool
    let performFiles: ([URL], Bool) -> Void

    var insertOnly = false

    var acceptPrefixes: [String]?

    var rejectPrefixes: [String]?

    var tileWidth: (() -> CGFloat)?

    var rowSize: (() -> CGSize)?
    var setLineAfter: (Bool) -> Void = { _ in }
    var performTextAfter: ((String) -> Bool)?
    var performFilesAfter: (([URL]) -> Void)?

    private func zone(_ info: DropInfo) -> SlideDropZone {
        if let tileWidth {
            SlideDropZone.tile(at: info.location, width: tileWidth(), reorder: isReorder, insertOnly: insertOnly)
        } else if let rowSize, !isReorder {
            SlideDropZone.row(at: info.location, size: rowSize(), insertOnly: insertOnly)
        } else if insertOnly || isReorder || info.location.x < SlideDropZone.gutter {
            .before
        } else {
            .on
        }
    }

    static func forcesInsert(payload: String?) -> Bool {
        guard let payload else { return false }
        return payload.hasPrefix("mxueditslide::") || payload.hasPrefix("mxuslide::")
            || payload.hasPrefix("mxuobj::")
    }

    private var isReorder: Bool {
        Self.forcesInsert(payload: NSPasteboard(name: .drag).string(forType: .string))
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard enabled, info.hasItemsConforming(to: [.plainText, .fileURL]) else { return false }

        let payload = NSPasteboard(name: .drag).string(forType: .string)
        if let rejectPrefixes, let payload,
           rejectPrefixes.contains(where: { payload.hasPrefix($0) }) {
            return false
        }
        guard let acceptPrefixes else { return true }
        guard let payload else { return false }
        return acceptPrefixes.contains { payload.hasPrefix($0) }
    }

    func dropEntered(info: DropInfo) {
        updateFeedback(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateFeedback(info)

        return DropProposal(operation: isReorder ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        setLine(false)
        setRing(false)
        setLineAfter(false)
    }

    private func updateFeedback(_ info: DropInfo) {
        let zone = zone(info)
        setLineAfter(zone == .after)
        setLine(zone == .before)
        setRing(zone == .on)
    }

    func performDrop(info: DropInfo) -> Bool {
        let described = info.itemProviders(for: [.plainText, .fileURL])
            .map { $0.registeredTypeIdentifiers.joined(separator: "+") }
            .joined(separator: " | ")
        MainActor.assumeIsolated { DropLatency.performed() }
        DiagnosticsStore.shared.note("\(breadcrumb).perform", detail: described)
        let zone = zone(info)
        dropStarted()
        setLine(false)
        setRing(false)
        setLineAfter(false)

        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURLs = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = dragPasteboard.string(forType: .string) ?? ""
        if !enabled {
            return false
        } else if zone == .after {
            return performAfter(fileURLs: fileURLs, text: text)
        } else {
            return perform(info, fileURLs: fileURLs, text: text, insert: zone == .before)
        }
    }

    private func performAfter(fileURLs: [URL], text: String) -> Bool {
        if !fileURLs.isEmpty, let performFilesAfter {
            DiagnosticsStore.shared.note("\(breadcrumb).afterFiles", detail: "\(fileURLs.count)")
            performFilesAfter(fileURLs)
            return true
        } else if !text.isEmpty, let performTextAfter {
            DiagnosticsStore.shared.note("\(breadcrumb).after", detail: String(text.prefix(40)))
            return performTextAfter(text)
        } else {
            DiagnosticsStore.shared.note("\(breadcrumb).afterNoHandler")
            return false
        }
    }

    private func perform(_ info: DropInfo, fileURLs: [URL], text: String, insert: Bool) -> Bool {
        if !fileURLs.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).files", detail: "\(fileURLs.count)")
            performFiles(fileURLs, insert)
            return true
        } else if !text.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).pasteboard", detail: String(text.prefix(40)))
            return performText(text, insert)
        } else if let provider = info.itemProviders(for: [.plainText]).first {

            let typeIdentifier = provider.registeredTypeIdentifiers.first ?? "public.utf8-plain-text"
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in

                DispatchQueue.main.async {
                    DiagnosticsStore.shared.note(
                        "\(breadcrumb).loadCallback",
                        detail: "bytes=\(data?.count ?? -1) error=\(error.map(String.init(describing:)) ?? "nil")")
                    if let data, let text = String(data: data, encoding: .utf8) {
                        _ = performText(text, insert)
                    } else {
                        DiagnosticsStore.shared.note(
                            "\(breadcrumb).textLoadFailed", detail: typeIdentifier)
                    }
                }
            }
            return true
        } else {
            DiagnosticsStore.shared.note("\(breadcrumb).noTextProvider")
            return false
        }
    }
}

struct CanvasDropDelegate: DropDelegate {
    let enabled: Bool

    let viewSize: () -> CGSize
    let canvasSize: CGSize
    let setTargeted: (Bool) -> Void
    let performText: (String, CGPoint) -> Bool
    let performFiles: ([URL], CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.plainText, .fileURL])
    }

    func dropEntered(info: DropInfo) { setTargeted(true) }
    func dropExited(info: DropInfo) { setTargeted(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    private func scenePoint(_ location: CGPoint) -> CGPoint {
        EditorGeometry.scenePoint(
            fromView: location, viewSize: viewSize(), canvas: canvasSize, inset: EditorGeometry.pasteboardInset)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        guard enabled else { return false }
        let point = scenePoint(info.location)
        DiagnosticsStore.shared.note(
            "editor.canvasDrop",
            detail: "x=\(Int(point.x)) y=\(Int(point.y))")

        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURLs = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            DiagnosticsStore.shared.note("editor.canvasDrop.files", detail: "\(fileURLs.count)")
            performFiles(fileURLs, point)
            return true
        }
        if let text = dragPasteboard.string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note(
                "editor.canvasDrop.pasteboard", detail: String(text.prefix(40)))
            return performText(text, point)
        }
        DiagnosticsStore.shared.note("editor.canvasDrop.noPayload")
        return false
    }
}

struct GridGapDropDelegate: DropDelegate {
    let enabled: Bool

    let dropStarted: () -> Void

    let spot: (CGPoint) -> SlideGridDrop.Spot
    let setTarget: (SlideGridDrop.Spot?) -> Void
    let performText: (String, Int) -> Bool
    let performFiles: ([URL], Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.plainText, .fileURL])
            && !GutterDropDelegate.forcesInsert(payload: NSPasteboard(name: .drag).string(forType: .string))
    }

    func dropEntered(info: DropInfo) { setTarget(spot(info.location)) }
    func dropExited(info: DropInfo) { setTarget(nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setTarget(spot(info.location))
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = spot(info.location).insertionIndex
        dropStarted()
        DiagnosticsStore.shared.note("grid.gapDrop", detail: "before \(index)")
        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURLs = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !enabled {
            return false
        } else if !fileURLs.isEmpty {
            DiagnosticsStore.shared.note("grid.gapDrop.files", detail: "\(fileURLs.count)")
            performFiles(fileURLs, index)
            return true
        } else if let text = dragPasteboard.string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note("grid.gapDrop.pasteboard", detail: String(text.prefix(40)))
            return performText(text, index)
        } else {
            DiagnosticsStore.shared.note("grid.gapDrop.noPayload")
            return false
        }
    }
}
