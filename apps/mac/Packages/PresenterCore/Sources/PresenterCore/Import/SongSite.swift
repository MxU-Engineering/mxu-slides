import Foundation

public enum SongSite: String, CaseIterable, Identifiable, Sendable {
    case songSelect

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .songSelect: "SongSelect"
        }
    }

    public var home: URL {
        switch self {
        case .songSelect: URL(string: "https://songselect.ccli.com/")!
        }
    }

    public func searchURL(_ query: String) -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = switch self {
        case .songSelect: URLComponents(string: "https://songselect.ccli.com/search/results")!
        }
        components.queryItems = [URLQueryItem(name: "search", value: trimmed)]
        return trimmed.isEmpty ? home : components.url!
    }

    public func start(ccliNumber: Int? = nil, title: String? = nil) -> URL {
        let page = switch self {
        case .songSelect: ccliNumber.flatMap { URL(string: "https://songselect.ccli.com/songs/\($0)") }
        }
        return page ?? searchURL(title ?? "")
    }

    public static func isDownload(mimeType: String?, filename: String?, contentDisposition: String?, isMainFrame: Bool, canShow: Bool) -> Bool {
        let mime = (mimeType ?? "").lowercased()
        let name = (filename ?? "").lowercased()
        let isChartText = ["txt", "cho", "chopro", "chordpro", "crd", "onsong"].contains((name as NSString).pathExtension)
        if contentDisposition?.lowercased().hasPrefix("attachment") == true || !canShow {
            return true
        } else if isMainFrame {
            return mime == "application/pdf" || (mime.hasPrefix("text/plain") && isChartText)
        } else {
            return false
        }
    }
}
