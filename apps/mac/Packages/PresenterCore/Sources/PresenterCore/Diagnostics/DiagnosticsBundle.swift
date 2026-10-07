import Foundation

public enum DiagnosticsBundle {

    public struct Candidate: Equatable, Sendable {
        public var url: URL
        public var modified: Date
        public var byteSize: Int

        public init(url: URL, modified: Date, byteSize: Int) {
            self.url = url
            self.modified = modified
            self.byteSize = byteSize
        }
    }

    public static let reportWindowDays = 7
    public static let retentionDays = 14

    public static let byteCap = 25 * 1024 * 1024

    private static func cutoff(_ days: Int, before now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    public static func selection(
        from candidates: [Candidate], now: Date,
        windowDays: Int = reportWindowDays, byteCap: Int = byteCap
    ) -> [Candidate] {
        let since = cutoff(windowDays, before: now)
        var total = 0
        var chosen: [Candidate] = []
        for candidate in candidates.filter({ $0.modified >= since }).sorted(by: { $0.modified > $1.modified }) {
            if total + candidate.byteSize <= byteCap {
                total += candidate.byteSize
                chosen.append(candidate)
            }
        }
        return chosen
    }

    public static func expired(
        from candidates: [Candidate], now: Date, retentionDays: Int = retentionDays
    ) -> [Candidate] {
        let since = cutoff(retentionDays, before: now)
        return candidates.filter { $0.modified < since }
    }

    public static func isCrashReport(fileName: String) -> Bool {
        let name = fileName.lowercased()
        return name.hasPrefix("mxu slides")
            && ["ips", "crash", "hang", "spin", "diag"].contains((name as NSString).pathExtension)
    }

    public static func crashReports(in candidates: [Candidate], since previousLaunch: Date?) -> [Candidate] {
        candidates.filter { candidate in
            isCrashReport(fileName: candidate.url.lastPathComponent)
                && previousLaunch.map { candidate.modified > $0 } == true
        }
    }

    public static func candidates(in folder: URL) -> [Candidate] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, let modified = values?.contentModificationDate {
                return Candidate(url: url, modified: modified, byteSize: values?.fileSize ?? 0)
            } else {
                return nil
            }
        }
    }
}
