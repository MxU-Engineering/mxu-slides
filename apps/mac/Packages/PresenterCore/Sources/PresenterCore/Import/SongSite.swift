import Foundation

public enum SongSite: String, CaseIterable, Identifiable, Sendable {
    case songSelect
    case multiTracks

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .songSelect: "SongSelect"
        case .multiTracks: "MultiTracks"
        }
    }

    public var home: URL {
        switch self {
        case .songSelect: URL(string: "https://songselect.ccli.com/")!
        case .multiTracks: URL(string: "https://www.multitracks.com/")!
        }
    }

    public func searchURL(_ query: String) -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = switch self {
        case .songSelect: URLComponents(string: "https://songselect.ccli.com/search/results")!
        case .multiTracks: URLComponents(string: "https://www.multitracks.com/songs/")!
        }
        components.queryItems = [URLQueryItem(name: "search", value: trimmed)]
        return trimmed.isEmpty ? home : components.url!
    }

    public func start(ccliNumber: Int? = nil, title: String? = nil, pageURL: String? = nil) -> URL {
        let page = switch self {
        case .songSelect: ccliNumber.flatMap { URL(string: "https://songselect.ccli.com/songs/\($0)") }
        case .multiTracks: pageURL.flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
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
