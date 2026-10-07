import Foundation
import os

private let log = Logger(subsystem: "com.example.mxuslides", category: "hls-upload")

actor HLSUploader {
    struct Item: Sendable {
        var name: String
        var data: Data
        var duration: Double
    }

    static let queueDepth = 30

    private let primary: String
    private let backup: String?
    private var activeTemplate: String
    private let session: URLSession
    private var playlist: HLSPlaylist
    private let continuity: HLSContinuity
    private let items: AsyncStream<Item>
    private let enqueueContinuation: AsyncStream<Item>.Continuation
    private var droppedSegments = 0

    private var lastStatusByKind: [String: Int] = [:]
    private var loggedHost = false

    init(primary: String, backup: String?, continuity: HLSContinuity, session: URLSession? = nil) {
        self.primary = primary
        self.backup = backup
        self.activeTemplate = primary
        self.continuity = continuity
        self.playlist = HLSPlaylist(mediaSequence: continuity.resumeSequence)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(configuration: config)
        }
        (items, enqueueContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingOldest(Self.queueDepth))
    }

    nonisolated func enqueue(_ item: Item) {
        enqueueContinuation.yield(item)
    }

    nonisolated func finishEnqueuing() {
        enqueueContinuation.finish()
    }

    private static let dumpDir: URL? = ProcessInfo.processInfo
        .environment["MXU_HLS_DUMP"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    func run() async throws {
        if let dir = Self.dumpDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for await item in items {
            try await deliver(segment: item)
        }
    }

    private func deliver(segment: Item) async throws {
        if let dir = Self.dumpDir {
            try? segment.data.write(to: dir.appendingPathComponent(segment.name))
        }
        try await put(name: segment.name, body: segment.data, contentType: "video/mp2t")
        playlist.add(name: segment.name, duration: segment.duration)
        continuity.recordSequence(playlist.nextSequence)
        let rendered = Data(playlist.render().utf8)
        if let dir = Self.dumpDir {
            try? rendered.write(to: dir.appendingPathComponent("playlist.m3u8"))
        }
        try await put(
            name: "playlist.m3u8",
            body: rendered,
            contentType: "application/vnd.apple.mpegurl")
    }

    private func put(name: String, body: Data, contentType: String) async throws {
        var attempt = 0
        while true {
            do {
                try await putOnce(template: activeTemplate, name: name, body: body, contentType: contentType)
                return
            } catch let error as StreamSessionError {
                if case .fatal = error { throw error }
                attempt += 1

                if attempt == 2, let backup, activeTemplate == primary {
                    log.warning("hls ingest failing over to backup after \(attempt) attempts")
                    activeTemplate = backup
                } else if attempt >= 4 {
                    throw StreamSessionError.transportClosed("hls ingest unreachable after \(attempt) attempts")
                }
                let delay = min(4.0, pow(2.0, Double(attempt - 1)) * 0.5)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func putOnce(template: String, name: String, body: Data, contentType: String) async throws {
        guard let url = Self.uploadURL(template: template, filename: name) else {
            throw StreamSessionError.fatal("bad HLS ingest URL template")
        }
        if !loggedHost {
            loggedHost = true
            log.info("hls ingest host: \(url.host ?? "?", privacy: .public)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let status: Int
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw StreamSessionError.transportClosed("hls upload failed: \(error.localizedDescription)")
        }
        let kind = name.hasSuffix(".ts") ? "segment" : "playlist"
        if lastStatusByKind[kind] != status {
            lastStatusByKind[kind] = status
            log.info("hls \(kind, privacy: .public) status -> \(status) (\(name, privacy: .public))")
        }
        switch status {
        case 200...299:
            return
        case 401:
            throw StreamSessionError.fatal("hls ingest rejected credentials (401) — the ingest URL expired")
        case 400, 403, 405:
            throw StreamSessionError.fatal("hls ingest rejected the upload (\(status))")
        default:
            throw StreamSessionError.transportClosed("hls ingest returned \(status)")
        }
    }

    static func uploadURL(template: String, filename: String) -> URL? {
        if template.hasSuffix("=") {
            return URL(string: template + filename)
        }
        if template.contains("?") {
            return URL(string: template + "&file=" + filename)
        }
        return URL(string: template + "?file=" + filename)
    }
}
