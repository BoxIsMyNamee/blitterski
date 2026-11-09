import SwiftUI
import WebKit
import Security

struct XCredentials: Codable {
    let authToken: String
    let ct0: String
}

/// Shared so the login webview and the API client look like the same browser.
let xUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

enum XKeychain {
    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "xspike",
         kSecAttrAccount as String: "x.credentials"]
    }

    // Sideload containers (LiveContainer etc.) can make the Keychain flaky,
    // so fall back to UserDefaults if it refuses.
    private static let fallbackKey = "x.credentials.fallback"

    static func save(_ c: XCredentials) throws {
        let data = try JSONEncoder().encode(c)
        SecItemDelete(base() as CFDictionary)
        var add = base()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let s = SecItemAdd(add as CFDictionary, nil)
        if s != errSecSuccess { UserDefaults.standard.set(data, forKey: fallbackKey) }
    }

    static func load() -> XCredentials? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let c = try? JSONDecoder().decode(XCredentials.self, from: d) {
            return c
        }
        if let d = UserDefaults.standard.data(forKey: fallbackKey) {
            return try? JSONDecoder().decode(XCredentials.self, from: d)
        }
        return nil
    }

    static func clear() {
        SecItemDelete(base() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }
}

/// Shows X's real login page (handles captcha / 2FA / whatever X throws at us),
/// then lifts auth_token + ct0 out of the webview's cookie store.
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
