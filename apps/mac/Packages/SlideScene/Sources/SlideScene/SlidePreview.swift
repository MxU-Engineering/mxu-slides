import Foundation
import PresenterCore

public enum SlidePreview {

    public enum RowText: Equatable {

        case preview(String)

        case name

        case number
    }

    public static func rowText(for slide: Slide, backgroundMediaName: String?) -> RowText {
        if !slide.name.isEmpty {
            let foregroundVideo = (slide.background?.layer ?? .loopingVideos) == .videos
            if foregroundVideo
                || !nameIsBackgroundMedia(slide.name, mediaName: backgroundMediaName) {
                return .name
            }
        }
        let preview = line(for: slide)
        return preview.isEmpty ? .number : .preview(preview)
    }

    static func nameIsBackgroundMedia(_ name: String, mediaName: String?) -> Bool {
        guard let mediaName, !mediaName.isEmpty else { return false }
        let strip: (String) -> String = {
            ($0 as NSString).deletingPathExtension.lowercased()
        }
        return name.lowercased() == mediaName.lowercased()
            || strip(name) == strip(mediaName)
    }

    public static func line(for slide: Slide) -> String {
        ConfidenceSceneBuilder.lyricText(for: slide)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}
