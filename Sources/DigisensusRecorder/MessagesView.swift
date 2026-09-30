import SwiftUI
import WebKit

/// The Messages window: every message from Digisensus on the left, the selected one in full
/// on the right. A notification's click opens it on that message.
struct MessagesView: View {
    @ObservedObject var center: MessageCenter

    var body: some View {
        NavigationSplitView {
            List(center.messages, selection: $center.selected) { message in
                row(message).tag(message.id)
            }
            .overlay {
                if center.messages.isEmpty {
                    Text("No messages yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let message = center.messages.first(where: { $0.id == center.selected }) {
                MessageWebView(message: message)
            } else {
                Text(center.messages.isEmpty ? "Messages from Digisensus show up here." : "Select a message.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.canvas)
            }
        }
        .onChange(of: center.selected, initial: true) { _, id in center.markRead(id) }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func row(_ message: BroadcastMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(center.read.contains(message.id) ? Color.clear : Palette.accent)
                .frame(width: 7, height: 7)
                .accessibilityLabel(center.read.contains(message.id) ? "" : "Unread")
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(size: 13, weight: center.read.contains(message.id) ? .regular : .semibold))
                    .lineLimit(2)
                if !message.summary.isEmpty {
                    Text(message.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(message.publishedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A message's body in a web view: the backend's HTML (escaped Markdown with links and
/// images) in the app's type and colours. No JavaScript runs, nothing is stored, only images
/// load, and a link opens in the browser.
struct MessageWebView: NSViewRepresentable {
    let message: BroadcastMessage

    /// The last web view shown, for the DSREC_SNAPSHOT hook (a web view draws out of process,
    /// so it has to be asked for its picture).
    @MainActor static weak var current: WKWebView?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = true
        Self.current = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(message.id)-\(message.updatedAt.timeIntervalSince1970)"
        guard context.coordinator.shown != key else { return }
        context.coordinator.shown = key
        view.loadHTMLString(Self.page(message), baseURL: DigisensusAccount.server)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // The page itself loads as the server's address; anything else is a link.
            let server = DigisensusAccount.server
            if action.navigationType == .other, let url = action.request.url, url.host == server.host, url.port == server.port,
               ["", "/"].contains(url.path) {
                decisionHandler(.allow)
                return
            }
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    /// The whole page: the title and date above the body, and a policy that lets images in
    /// (from any https site or from the server itself) but nothing else.
    static func page(_ message: BroadcastMessage) -> String {
        let server = DigisensusAccount.server
        let origin = "\(server.scheme ?? "https")://\(server.host ?? "")\(server.port.map { ":\($0)" } ?? "")"
        let date = message.publishedAt.formatted(date: .long, time: .omitted)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: \(origin); style-src 'unsafe-inline'">
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; padding: 28px 36px 48px; max-width: 700px; background: #FBFAF8; color: #1D1B18;
                 font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; -webkit-font-smoothing: antialiased; }
          h1 { font-size: 22px; line-height: 1.3; margin: 0 0 4px; }
          .date { color: #6B665E; font-size: 12px; margin: 0 0 22px; }
          h2 { font-size: 17px; margin: 24px 0 8px; }
          h3 { font-size: 15px; margin: 20px 0 6px; }
          p, ul, ol { margin: 0 0 12px; }
          li { margin: 3px 0; }
          a { color: #2F6BD8; }
          img { max-width: 100%; height: auto; border-radius: 8px; margin: 4px 0; }
          @media (prefers-color-scheme: dark) {
            body { background: #1F1E1C; color: #EDEAE4; }
            .date { color: #8F8980; }
            a { color: #5B8DEF; }
          }
        </style></head>
        <body><h1>\(escape(message.title))</h1><p class="date">\(escape(date))</p>
        \(message.html)
        </body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
