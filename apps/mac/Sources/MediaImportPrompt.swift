import AppKit
import PresenterCore
import SwiftUI

@MainActor
enum MediaImportPrompt {
    enum Conflict {

        case sameFile

        case sameName
    }

    static func ask(
        model: AppModel, conflict: Conflict, kind: DocumentKind, existingID: String, existingName: String,
        incoming: URL, copyName: String, othersLeft: Int
    ) async -> (useExisting: Bool, forRest: Bool) {
        var forRest = false
        let code = await present { finish in
            MediaImportConflictView(
                model: model, conflict: conflict, kind: kind, existingID: existingID, existingName: existingName,
                incoming: incoming, copyName: copyName, othersLeft: othersLeft, forRest: { forRest = $0 }, finish: finish)
        }
        return (code == 1, forRest)
    }

    static func confirmSharedFile(model: AppModel, otherID: String, otherName: String, itemName: String) async -> Bool {
        await present { finish in
            SharedFileConfirmView(model: model, otherID: otherID, otherName: otherName, itemName: itemName, finish: finish)
        } == 1
    }

    private static func present<V: View>(_ make: (@escaping (Int) -> Void) -> V) async -> Int {
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        NSApp.activate()
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
        return await withCheckedContinuation { continuation in
            var answered = false
            let view = make { code in
                if !answered {
                    answered = true
                    if let parent {
                        parent.endSheet(sheet)
                    } else {
                        sheet.orderOut(nil)
                    }
                    continuation.resume(returning: code)
                }
            }
            sheet.contentViewController = NSHostingController(rootView: view)
            if let parent {
                parent.beginSheet(sheet)
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct MediaPromptTile: View {
    let title: String
    let caption: String
    let image: AnyView

    var body: some View {
        VStack(spacing: 6) {
            image
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle.standard(CornerStandard.element))
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 170)
    }
}

private func libraryPicture(model: AppModel, kind: DocumentKind, id: String) -> AnyView {
    if kind == .media {
        AnyView(Color.black.overlay { PosterImage(model: model, mediaId: id) })
    } else {
        AnyView(Color.primary.opacity(0.06).overlay {
            Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
        })
    }
}

private struct IncomingFilePicture: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else if MediaImporter.libraryKind(of: url) == .audio {
                    Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .task(id: url) { image = await ThumbnailStore.filePoster(url: url) }
    }
}

private struct MediaImportConflictView: View {
    let model: AppModel
    let conflict: MediaImportPrompt.Conflict
    let kind: DocumentKind
    let existingID: String
    let existingName: String
    let incoming: URL
    let copyName: String
    let othersLeft: Int
    let forRest: (Bool) -> Void
    let finish: (Int) -> Void

    @State private var sameForRest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(conflict == .sameFile
                ? "“\(incoming.lastPathComponent)” is already in your library"
                : "“\(existingName)” is already in your library")
                .font(.headline)
            Text(conflict == .sameFile
                ? "It's the same file as “\(existingName)”. Use that item, or add another copy as “\(copyName)”."
                : "A different file has this name in your library. Use the one you have, or add the new file as “\(copyName)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                MediaPromptTile(
                    title: existingName, caption: "In your library",
                    image: libraryPicture(model: model, kind: kind, id: existingID))
                if conflict == .sameName {
                    MediaPromptTile(
                        title: incoming.lastPathComponent, caption: "New file",
                        image: AnyView(IncomingFilePicture(url: incoming)))
                }
            }
            .frame(maxWidth: .infinity)
            if othersLeft > 0 {
                Toggle("Do the same for the rest of this import", isOn: $sameForRest)
                    .toggleStyle(.checkbox)
                    .onChange(of: sameForRest) { forRest(sameForRest) }
            }
            HStack {
                Spacer()
                Button("Add as New Copy") { finish(0) }
                Button("Use Existing") { finish(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct SharedFileConfirmView: View {
    let model: AppModel
    let otherID: String
    let otherName: String
    let itemName: String
    let finish: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This file is already in your library")
                .font(.headline)
            Text("It's the file of “\(otherName)”. Replacing anyway gives “\(itemName)” the same file, so the two items show the same picture.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MediaPromptTile(
                title: otherName, caption: "In your library",
                image: libraryPicture(model: model, kind: .media, id: otherID))
                .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button("Cancel") { finish(0) }
                    .keyboardShortcut(.cancelAction)
                Button("Replace Anyway") { finish(1) }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
