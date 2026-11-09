import SwiftUI
import WebKit

struct XCredentials: Codable {
    let authToken: String
    let ct0: String
}

/// Shared so the login webview and the timeline webview look like the same browser.
let xUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

enum XSession {
    static let key = "x.credentials"
    static func load() -> XCredentials? { Secrets.load(XCredentials.self, key: key) }
}

/// Shows X's real login page (handles captcha / 2FA / whatever X throws at us),
/// then lifts auth_token + ct0 out of the webview's cookie store.
/// The cookies stay in the shared default data store, which is what the timeline webview uses.
struct XLoginView: UIViewRepresentable {
    let onLogin: (XCredentials) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLogin: onLogin) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.customUserAgent = xUserAgent
        context.coordinator.start(watching: wv)
        wv.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator {
        let onLogin: (XCredentials) -> Void
        private var timer: Timer?
        init(onLogin: @escaping (XCredentials) -> Void) { self.onLogin = onLogin }

        func start(watching wv: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak wv] t in
                guard let self, let wv else { t.invalidate(); return }
                wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let xs = cookies.filter { $0.domain.hasSuffix("x.com") || $0.domain.hasSuffix("twitter.com") }
                    guard let auth = xs.first(where: { $0.name == "auth_token" })?.value,
                          let ct0 = xs.first(where: { $0.name == "ct0" })?.value else { return }
                    t.invalidate()
                    DispatchQueue.main.async { self.onLogin(XCredentials(authToken: auth, ct0: ct0)) }
                }
            }
        }
    }
}
