import SwiftUI
import WebKit

/// Sheet that embeds the real bandcamp.com login. We never see the password —
/// once the user logs in, we read the `identity` session cookie from the web view.
struct BandcampLoginSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var status = "Log in with your Bandcamp account."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Bandcamp").font(.system(size: 15, weight: .bold))
                    Text(status).font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Cancel") { state.showLogin = false }
                    .buttonStyle(.soft).foregroundStyle(p.muted)
            }
            .padding(Space.s4)

            Divider()

            BandcampWebView { identity in
                state.finishConnect(identity: identity)
            } onProgress: { s in
                status = s
            }
        }
        .frame(width: 900, height: 640)
        .background(p.page)
    }
}

/// WKWebView wrapper that watches for the login session cookie.
struct BandcampWebView: NSViewRepresentable {
    let onIdentity: (String) -> Void
    let onProgress: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // In-memory store: we only need to read the `identity` cookie once. Nothing
        // is written to WebKit's on-disk cookie store, so no unencrypted second copy
        // of the session survives on disk after the sheet closes.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://bandcamp.com/login")!))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: BandcampWebView
        private var done = false

        init(_ parent: BandcampWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let path = webView.url?.path ?? ""
            let host = webView.url?.host ?? ""
            // Still on the login page → keep waiting.
            if path.hasPrefix("/login") {
                parent.onProgress("Log in with your Bandcamp account.")
                return
            }
            guard host.contains("bandcamp.com") else { return }
            parent.onProgress("Finishing up…")
            checkCookies(webView)
        }

        private func checkCookies(_ webView: WKWebView) {
            guard !done else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard let identity = cookies.first(where: { $0.name == "identity" })?.value,
                      identity.count > 20 else { return }
                self.done = true
                DispatchQueue.main.async { self.parent.onIdentity(identity) }
            }
        }
    }
}
