import AppKit
import PresenterCore
import SwiftUI
import WebKit

struct SongSiteBrowser: View {
    let site: SongSite
    let start: URL

    var query = ""

    let onChart: (_ text: String, _ filename: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var browser = SongSiteBrowserModel()
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                    .help("Back")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward)
                    .help("Forward")
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                TextField("Search \(site.name)", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { browser.webView.load(URLRequest(url: site.searchURL(search))) }
                Text(browser.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(8)
            Divider()
            SongSiteWebView(webView: browser.webView)
            Divider()
            Text(browser.status ?? "Sign in to \(site.name) with your church's account, find the song, then use the site's Download button (lyrics, ChordPro or a chord chart PDF). MxU Slides brings it in.")
                .font(.caption)
                .foregroundStyle(browser.statusIsProblem ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }

        .frame(minWidth: 1240, minHeight: 760)
        .task {
            search = query
            browser.onChart = { text, filename in
                onChart(text, filename)
                dismiss()
            }
            browser.webView.load(URLRequest(url: start))
        }
    }
}

private struct SongSiteWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
@Observable
final class SongSiteBrowserModel: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    @ObservationIgnored let webView: WKWebView
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var host = ""
    var status: String?
    var statusIsProblem = false
    @ObservationIgnored var onChart: ((String, String) -> Void)?
    @ObservationIgnored private var destinations: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()

        configuration.websiteDataStore = .default()

        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.host = view.url?.host() ?? "" } },
        ]
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let isDownload = SongSite.isDownload(
            mimeType: navigationResponse.response.mimeType,
            filename: navigationResponse.response.suggestedFilename,
            contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"),
            isMainFrame: navigationResponse.isForMainFrame,
            canShow: navigationResponse.canShowMIMEType)
        return isDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MxU Slides Song Downloads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: suggestedFilename.isEmpty ? "download" : suggestedFilename)
        destinations[ObjectIdentifier(download)] = destination
        status = "Bringing in “\(destination.lastPathComponent)”…"
        statusIsProblem = false
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let destination = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            Task { await importDownload(at: destination) }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        status = "The download didn't finish: \(error.localizedDescription)"
        statusIsProblem = true
    }

    private func importDownload(at url: URL) async {
        let filename = url.lastPathComponent
        let text = await Task.detached {
            (try? Data(contentsOf: url)).flatMap { ChordChartPDF.importText(from: $0, filename: filename) }
        }.value
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if let text {
            status = nil
            onChart?(text, filename)
        } else {
            status = "“\(filename)” has no words MxU Slides can read. Try the lyrics or ChordPro download."
            statusIsProblem = true
        }
    }
}
