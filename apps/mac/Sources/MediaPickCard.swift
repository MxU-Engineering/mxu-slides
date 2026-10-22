import PresenterCore
import SwiftUI

struct MediaPickCard: View {
    let model: AppModel
    let mediaID: String

    let scope: String
    let onReplace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Color.black
                    .overlay { PosterImage(model: model, mediaId: mediaID) }
                    .frame(width: 80, height: 45)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.indexEntry(mediaID)?.name ?? "Missing item")
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Replace…", action: onReplace)
                    .help("Choose different media for \(scope) only.")
                Button("Edit Media…") {
                    model.openInEditor(entryID: mediaID)
                }
                .help("Open this library item: trim, effects and its file. Changes there apply everywhere it's used.")
            }
        }
    }

    private var detail: String {
        if let item = model.media(mediaID) {
            MediaPickCardLogic.detail(
                kind: item.mediaKind, width: item.pixelWidth, height: item.pixelHeight,
                duration: item.durationSeconds, missing: model.isMediaFileMissing(item))
        } else {
            "Not in the library"
        }
    }
}
