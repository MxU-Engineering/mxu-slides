import AppKit
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

    var rowHeight: (() -> CGFloat)?

    var tileWidth: (() -> CGFloat)?
    var setLineAfter: (Bool) -> Void = { _ in }
    var performTextAfter: ((String) -> Bool)?

    private func isAfterZone(_ info: DropInfo) -> Bool {
        if !isReorder {
            return false
        } else if let rowHeight {
            let height = rowHeight()
            return height > 0 && info.location.y > height / 2
        } else if let tileWidth {
            let width = tileWidth()
            return width > 0 && info.location.x > width / 2
        } else {
            return false
        }
    }

    private var insertZone: CGFloat { 26 }

    private func isInsert(_ info: DropInfo) -> Bool {
        info.location.x < insertZone
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
        if isAfterZone(info) {
            setLine(false)
            setRing(false)
            setLineAfter(true)
            return
        }
        setLineAfter(false)
        let insert = insertOnly || isInsert(info) || isReorder
        setLine(insert)
        setRing(!insert)
    }

    func performDrop(info: DropInfo) -> Bool {
        let described = info.itemProviders(for: [.plainText, .fileURL])
            .map { $0.registeredTypeIdentifiers.joined(separator: "+") }
            .joined(separator: " | ")
        MainActor.assumeIsolated { DropLatency.performed() }
        DiagnosticsStore.shared.note("\(breadcrumb).perform", detail: described)
        let insert = isInsert(info)
        let after = isAfterZone(info)
        dropStarted()
        setLine(false)
        setRing(false)
        setLineAfter(false)
        guard enabled else { return false }
        if after, let performTextAfter,
           let text = NSPasteboard(name: .drag).string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).after", detail: String(text.prefix(40)))
            return performTextAfter(text)
        }

        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURLs = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).files", detail: "\(fileURLs.count)")
            performFiles(fileURLs, insert)
            return true
        }
        if let text = dragPasteboard.string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).pasteboard", detail: String(text.prefix(40)))
            return performText(text, insert)
        }

        guard let provider = info.itemProviders(for: [.plainText]).first else {
            DiagnosticsStore.shared.note("\(breadcrumb).noTextProvider")
            return false
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first ?? "public.utf8-plain-text"
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in

            DispatchQueue.main.async {
                DiagnosticsStore.shared.note(
                    "\(breadcrumb).loadCallback",
                    detail: "bytes=\(data?.count ?? -1) error=\(error.map(String.init(describing:)) ?? "nil")")
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    DiagnosticsStore.shared.note(
                        "\(breadcrumb).textLoadFailed", detail: typeIdentifier)
                    return
                }
                _ = performText(text, insert)
            }
        }
        return true
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
