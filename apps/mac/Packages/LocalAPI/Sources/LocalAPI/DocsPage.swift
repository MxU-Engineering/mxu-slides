import Foundation

public enum DocsPage {
    public static func html(
        routes: [APIRoute], baseURL: String, schemaVersion: Int
    ) -> String {
        let grouped = Dictionary(grouping: routes, by: \.tag)
        let tagOrder = ["Show", "Media", "Overlays", "Alerts", "Timers",
                        "Audio", "Transport", "Outputs", "Services",
                        "Documents", "Library"]
        let orderedTags = tagOrder.filter { grouped[$0] != nil }
            + grouped.keys.filter { !tagOrder.contains($0) }.sorted()

        var sections = ""
        var nav = ""
        for tag in orderedTags {
            guard let tagRoutes = grouped[tag] else { continue }
            nav += "<a href=\"#\(slug(tag))\">\(escape(tag))</a>"
            sections += "<section id=\"\(slug(tag))\"><h2>\(escape(tag))</h2>"
            for route in tagRoutes.sorted(by: { $0.path < $1.path }) {
                sections += endpointBlock(route, baseURL: baseURL)
            }
            sections += "</section>"
        }

        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>MxU Slides — Local API</title>
        <style>\(css)</style>
        </head><body>
        <header>
          <h1>MxU Slides — Local API</h1>
          <p class="lede">Local show-control and content API served by this Mac.
          API version \(escape(OpenAPIDocument.apiVersion)) · document schema v\(schemaVersion).</p>
          <p class="base">Base URL <code>http://\(escape(baseURL))</code></p>
        </header>
        <div class="layout">
          <nav>\(nav)<a href="/openapi.json">openapi.json ↗</a><a href="/asyncapi.json">asyncapi.json ↗</a></nav>
          <main>
          <section id="auth"><h2>Authenticating</h2>
            \(authBlock(baseURL: baseURL))
          </section>
          \(sections)
          </main>
        </div>
        </body></html>
        """
    }

    private static func authBlock(baseURL: String) -> String {
        """
        <p>Every request carries an access key as a bearer token — the address
        alone won't get you in. The default Operate key sits under
        <strong>Settings › Network &amp; API › Connect at</strong>; create more
        (Watch / Operate / Manage access) with <strong>Manage Keys</strong>.
        Send it in the <code>Authorization</code> header:</p>
        \(curlBox("curl \(shellURL(baseURL, "/v1/status")) \\\n  -H \"Authorization: Bearer YOUR_KEY\""))
        <p>The WebSocket takes the key in the query string
        (<code>ws://\(escape(baseURL))/v1/ws?token=YOUR_KEY</code>) — send
        <code>{\"type\":\"subscribe\",\"topics\":[\"show\"]}</code> to receive
        live state, or a <code>command</code> frame to invoke any endpoint
        below over the socket. Each topic's <code>data</code> is the same shape
        as its REST snapshot — <code>show</code> is <code>GET /v1/status</code>,
        whose <code>liveSlide</code> carries <code>stepIndex</code> /
        <code>stepCount</code> while a slide with animation steps is live
        (<code>POST /v1/show/advance</code> reveals one step per call). The
        full channel list is at <code>/asyncapi.json</code>.</p>
        """
    }

    private static func endpointBlock(_ route: APIRoute, baseURL: String) -> String {
        let method = route.method.uppercased()
        let scopeBadge = "<span class=\"scope scope-\(route.scope.rawValue)\">\(scopeLabel(route.scope))</span>"
        var block = """
        <article class="endpoint">
          <div class="ep-head">
            <span class="method m-\(method.lowercased())">\(method)</span>
            <code class="path">\(escape(route.path))</code>
            \(scopeBadge)
          </div>
          <p class="summary">\(escape(route.summary))</p>
        """
        block += curlBox(curlExample(route, baseURL: baseURL))
        if route.requestSchema != nil {
            block += "<p class=\"note\">Body: JSON — see the schema in <a href=\"/openapi.json\">openapi.json</a>.</p>"
        }
        block += "</article>"
        return block
    }

    private static func curlExample(_ route: APIRoute, baseURL: String) -> String {
        let method = route.method.uppercased()
        let path = samplePath(route.path)
        var lines = [method == "GET"
            ? "curl \(shellURL(baseURL, path))"
            : "curl -X \(method) \(shellURL(baseURL, path))"]
        lines.append("  -H \"Authorization: Bearer YOUR_KEY\"")
        if let body = sampleBody(for: route) {
            lines.append("  -H \"Content-Type: application/json\"")
            lines.append("  -d '\(body)'")
        }

        return lines.joined(separator: " \\\n")
    }

    private static func samplePath(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{kind}", with: "presentations")
            .replacingOccurrences(of: "{id}", with: "ID")
    }

    private static func sampleBody(for route: APIRoute) -> String? {
        switch route.operationId {
        case "fireSlide": return #"{"serviceItemId": "ITEM", "occurrence": 0}"#
        case "advance": return #"{"steps": 1}"#
        case "clear": return #"{"function": "slides"}"#
        case "fireAlert": return #"{"presetId": "PRESET", "tokens": {"number": "142"}}"#
        case "audioTransport": return #"{"action": "playPause"}"#
        case "mediaTransport": return #"{"action": "seek", "position": 12.5}"#
        case "addServiceItem": return #"{"refId": "PRESENTATION"}"#
        case "createDocument", "updateDocument":
            return #"{"name": "New Song", "presentationKind": "deck", "themeId": "", "slides": []}"#
        case "fireAudioPlaylist": return #"{"startAtEntryId": null}"#
        default: return nil
        }
    }

    private static func scopeLabel(_ scope: APIScope) -> String {
        switch scope {
        case .view: "Watch"
        case .control: "Operate"
        case .edit: "Manage"
        }
    }

    private static func curlBox(_ text: String) -> String {
        "<pre class=\"curl\">\(escape(text))</pre>"
    }

    private static func shellURL(_ baseURL: String, _ path: String) -> String {
        "http://\(baseURL)\(path)"
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let css = """
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; font: 14px/1.5 -apple-system, system-ui, sans-serif;
      background: #1f1f1e; color: #e8e8e6; }
    header { padding: 28px 32px 20px; border-bottom: 1px solid #333; }
    h1 { margin: 0 0 4px; font-size: 20px; }
    .lede { margin: 0 0 6px; color: #9a9a97; }
    .base { margin: 0; color: #9a9a97; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    header code { color: #cfcfcc; }
    .layout { display: flex; align-items: flex-start; }
    nav { position: sticky; top: 0; width: 180px; flex: none; padding: 24px 16px;
      display: flex; flex-direction: column; gap: 2px; height: 100vh; overflow: auto; }
    nav a { color: #b7b7b4; text-decoration: none; padding: 5px 10px;
      border-radius: 8px; font-size: 13px; }
    nav a:hover { background: #2a2a2a; color: #fff; }
    main { flex: 1; padding: 24px 32px 80px; max-width: 820px; min-width: 0; }
    section { margin-bottom: 36px; }
    h2 { font-size: 16px; border-bottom: 1px solid #333; padding-bottom: 6px; }
    .endpoint { background: #262626; border: 1px solid #333; border-radius: 8px;
      padding: 14px 16px; margin: 12px 0; }
    .ep-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .method { font-weight: 700; font-size: 12px; padding: 2px 8px; border-radius: 6px;
      font-family: ui-monospace, monospace; }
    .m-get { background: #16351f; color: #6bd08a; }
    .m-post { background: #1a2c3d; color: #6bb6e0; }
    .m-put { background: #3a2f14; color: #d8b34a; }
    .m-delete { background: #3a1a1a; color: #e08585; }
    .path { font-size: 13px; color: #e8e8e6; }
    .scope { margin-left: auto; font-size: 11px; font-weight: 600; padding: 2px 8px;
      border-radius: 999px; background: #333; color: #b7b7b4; }
    .scope-view { color: #8fb7d8; }
    .scope-control { color: #6bd08a; }
    .scope-edit { color: #d8b34a; }
    .summary { color: #b7b7b4; margin: 8px 0; }
    pre.curl { background: #161616; border: 1px solid #333; border-radius: 8px;
      padding: 12px 14px; overflow-x: auto; font-size: 12.5px; color: #cfcfcc;
      font-family: ui-monospace, monospace; }
    .note { font-size: 12px; color: #8a8a87; margin: 6px 0 0; }
    @media (max-width: 720px) { nav { display: none; } main { padding: 20px; } }
    """
}
