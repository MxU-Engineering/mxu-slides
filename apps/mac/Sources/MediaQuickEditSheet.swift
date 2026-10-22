import PresenterCore
import SlideScene
import SwiftUI

struct MediaQuickEditSheet: View {
    let model: AppModel

    var onReplace: ((_ oldID: String, _ newID: String) -> Void)? = nil

    @State private var mediaID: String
    @State private var preview = MediaPreviewPlayer()

    @State private var loadedHash: String?
    @State private var pickingReplacement = false
    @Environment(\.dismiss) private var dismiss

    init(
        model: AppModel, mediaID: String,
        onReplace: ((_ oldID: String, _ newID: String) -> Void)? = nil
    ) {
        self.model = model
        self.onReplace = onReplace
        _mediaID = State(initialValue: mediaID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = model.media(mediaID) {
                content(item)
            } else {
                Text("Item unavailable.")
                    .foregroundStyle(.secondary)
                    .padding(24)
                footer(nil)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: mediaID) { await load() }

        .onChange(of: model.listVersion) { Task { await load() } }
        .onDisappear { preview.teardown() }
        .sheet(isPresented: $pickingReplacement) {
            LibraryPickerSheet(appModel: model) { entry in
                onReplace?(mediaID, entry.id)
                mediaID = entry.id
            }
        }
    }

    @ViewBuilder
    private func content(_ item: MediaItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.indexEntry(mediaID)?.name ?? item.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(detail(item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        picture(item)
            .padding(.horizontal, 14)
        if let problem = problem(item) {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
        }
        if item.mediaKind == .video {
            MediaEditorView.TransportPill(
                preview: preview,
                trimRange: MediaTrimEdit.fractions(
                    inPoint: item.inPoint, outPoint: item.outPoint, duration: preview.duration),
                onTrimChange: { range, final in

                    if final, preview.duration > 0 {
                        let points = MediaTrimEdit.points(fractions: range, duration: preview.duration)
                        model.updateMedia(mediaID) {
                            $0.inPoint = points.inPoint
                            $0.outPoint = points.outPoint
                        }
                    }
                }
            )
            .padding(.horizontal, 14)
            .padding(.top, 8)
            Text(trimCaption(item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 54)
                .padding(.trailing, 14)
        }
        Divider().padding(.top, 10)
        settings(item)
        footer(item)
    }

    private func picture(_ item: MediaItem) -> some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if item.mediaKind == .video {
                    VideoPreviewSurface(player: preview.player)
                } else {
                    PosterImage(model: model, mediaId: mediaID)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
    }

    @ViewBuilder
    private func settings(_ item: MediaItem) -> some View {
        VStack(spacing: 0) {
            if item.mediaKind == .video {
                row("Loop") {
                    Picker("Loop", selection: binding(\.loops, fallback: false)) {
                        Text("On").tag(true)
                        Text("Off").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Divider()
            }
            row("Classification") {
                Picker("Classification", selection: binding(\.classification, fallback: .foreground)) {
                    Text("Foreground").tag(MediaClassification.foreground)
                    Text("Background").tag(MediaClassification.background)
                }
                .fixedSize()
            }
            Divider()
            row("Transition") {
                TransitionMenu(current: item.transition, labeled: false) { transform in
                    model.updateMedia(mediaID) { $0.transition = transform($0.transition) }
                }
                .fixedSize()
            }
            if item.mediaKind == .video {
                Divider()
                row("Play Rate") {
                    Picker("Play Rate", selection: Binding(
                        get: { model.media(mediaID)?.playRate ?? 1 },

                        set: { rate in model.updateMedia(mediaID) { $0.playRate = rate == 1 ? nil : rate } }
                    )) {
                        ForEach(MediaEditorView.rateChoices, id: \.self) { rate in
                            Text(rate == 1 ? "Normal" : String(format: "%g×", rate)).tag(rate)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .labelsHidden()
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func footer(_ item: MediaItem?) -> some View {
        HStack(spacing: 6) {
            if onReplace != nil {
                Button("Replace…") { pickingReplacement = true }
                    .help("Choose different media for this spot only.")
            }
            if let item {
                MediaEditorDoors(model: model, mediaID: mediaID, item: item) { dismiss() }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private func binding<T: Equatable & Sendable>(
        _ keyPath: WritableKeyPath<MediaItem, T> & Sendable, fallback: T
    ) -> Binding<T> {
        Binding(
            get: { model.media(mediaID)?[keyPath: keyPath] ?? fallback },
            set: { value in model.updateMedia(mediaID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func detail(_ item: MediaItem) -> String {
        let kind = item.mediaKind.rawValue.capitalized
        return if let duration = item.durationSeconds, item.mediaKind == .video {
            "\(kind) · \(MediaEditorView.timecode(duration))"
        } else if let width = item.pixelWidth, let height = item.pixelHeight {
            "\(kind) · \(width) × \(height)"
        } else {
            kind
        }
    }

    private func problem(_ item: MediaItem) -> String? {
        if model.isMediaFileMissing(item) {
            "The file isn't on this Mac."
        } else if item.fileStatus == .needsTranscode || item.fileStatus == .transcodeFailed {
            "Needs transcode — open Edit Media… to fix it."
        } else {
            nil
        }
    }

    private func trimCaption(_ item: MediaItem) -> String {
        if let window = MediaTrimEdit.window(
            inPoint: item.inPoint, outPoint: item.outPoint, duration: preview.duration
        ) {
            "Trim \(MediaEditorView.timecode(window.lowerBound)) – \(MediaEditorView.timecode(window.upperBound)) · drag the ends to change"
        } else {
            "Drag either end of the bar to trim"
        }
    }

    private func load() async {
        await model.resident.ready([.media])
        if let item = model.media(mediaID), item.mediaKind == .video {
            if item.fileHash != loadedHash, let url = model.blobs?.url(forHash: item.fileHash) {
                loadedHash = item.fileHash
                await preview.load(url: url)
            }
            preview.trimWindow = MediaTrimEdit.window(
                inPoint: item.inPoint, outPoint: item.outPoint, duration: preview.duration)
            preview.playRate = item.playRate ?? 1
            preview.applyEffects(
                SlideSceneBuilder.sceneEffects(item.effects),
                canvasWidth: Double(SlideSceneBuilder.canvasSize.width))
        }
    }
}
