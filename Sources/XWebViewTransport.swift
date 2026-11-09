import SwiftUI
import WebKit

/// Plan B. Instead of forging requests, load the real x.com/home in a hidden webview and
/// listen to the timeline responses X's own JS fetches. X's code handles signing, query ids,
/// feature flags and headers, so none of that can break us. Cookies come from the same
/// default data store the login webview used, so no credential handling at all.
///
/// Trade-off: heavier (full web app loads) and "load more" means scrolling/reloading the page.
final class XWebViewTransport: NSObject, ObservableObject, WKScriptMessageHandler {
    let webView: WKWebView
    var onTimeline: ((Result<(posts: [Post], nextCursor: String?), Error>) -> Void)?

    private static let hook = """
    (function(){
      const post = (url, body) => window.webkit.messageHandlers.xcapture.postMessage({url: url, body: body});
      const wanted = u => /\\/graphql\\/[^/]+\\/(HomeLatestTimeline|HomeTimeline)/.test(u || '');
      const of = window.fetch;
      window.fetch = async function(...args) {
        const res = await of.apply(this, args);
        try {
          const u = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url);
          if (wanted(u)) res.clone().text().then(t => post(u, t));
        } catch (e) {}
        return res;
      };
      const oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        this.__u = u;
        this.addEventListener('load', () => { try { if (wanted(this.__u)) post(this.__u, this.responseText); } catch (e) {} });
        return oo.apply(this, arguments);
      };
    })();
    """

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: XWebViewTransport.hook,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
        webView.customUserAgent = xUserAgent
        super.init()
        ucc.add(self, name: "xcapture")
    }

    /// Reload to trigger a fresh timeline request.
    func refresh() {
        webView.load(URLRequest(url: URL(string: "https://x.com/home")!))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any],
              let body = d["body"] as? String, let data = body.data(using: .utf8) else { return }
        do { onTimeline?(.success(try XClient.parseTimeline(data))) }
        catch { onTimeline?(.failure(error)) }
    }
}

/// Needs to live in the view tree (1pt, invisible) or iOS may throttle the page.
struct HiddenWebView: UIViewRepresentable {
    let transport: XWebViewTransport
    func makeUIView(context: Context) -> WKWebView { transport.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
