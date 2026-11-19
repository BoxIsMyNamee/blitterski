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

    /// Restores saved auth_token and ct0 cookies into the shared WebKit cookie store if iOS purged them.
    @MainActor
    static func ensureCookies(in store: WKHTTPCookieStore = WKWebsiteDataStore.default().httpCookieStore) async {
        guard let creds = load() else { return }
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let xs = cookies.filter { $0.domain.hasSuffix("x.com") || $0.domain.hasSuffix("twitter.com") }
        let hasAuth = xs.contains { $0.name == "auth_token" && !$0.value.isEmpty }
        let hasCt0 = xs.contains { $0.name == "ct0" && !$0.value.isEmpty }
        if hasAuth && hasCt0 { return }

        let pairs: [(String, String, Bool)] = [
            ("auth_token", creds.authToken, true),
            ("ct0", creds.ct0, false),
        ]
        for (name, val, httpOnly) in pairs {
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: ".x.com",
                .path: "/",
                .name: name,
                .value: val,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(86_400 * 365),
            ]
            if httpOnly { props[.init("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.setCookie(cookie) { cont.resume() }
                }
            }
        }
    }
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

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let onLogin: (XCredentials) -> Void
        private var timer: Timer?
        init(onLogin: @escaping (XCredentials) -> Void) { self.onLogin = onLogin }
        deinit { timer?.invalidate() }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

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
