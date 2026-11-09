import UIKit
import WebKit

enum XOp: String {
    case forYou = "HomeTimeline"
    case following = "HomeLatestTimeline"
    var tabLabel: String { self == .forYou ? "for you" : "following" }
}

/// Tiny async mutex so only one X fetch drives the shared webview at a time.
@MainActor
final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// Loads the real x.com/home in a hidden webview and listens to the timeline responses
/// X's own JS fetches. X's code handles signing, query ids, feature flags and headers.
/// Cookies come from the same default data store the login webview used.
@MainActor
final class XWebSource: NSObject, WKScriptMessageHandler {
    private let webView: WKWebView
    private let lock = AsyncLock()
    private var wanted: XOp = .following
    private var currentOp: XOp?
    private var pending: CheckedContinuation<[Post], Error>?
    private var pendingToken = UUID()
    private var triedTab = false

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
        ucc.addUserScript(WKUserScript(source: XWebSource.hook,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        webView = WKWebView(frame: CGRect(x: -2000, y: 0, width: 1000, height: 1200), configuration: cfg)
        webView.customUserAgent = xUserAgent
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        super.init()
        ucc.add(self, name: "xcapture")
    }

    /// Park the webview offscreen in the key window so iOS doesn't throttle it.
    private func attach() {
        guard webView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(webView)
    }

    /// Fetch a page of posts. `loadMore` scrolls the hidden page to make X request the next page.
    func fetch(_ op: XOp, loadMore: Bool) async throws -> [Post] {
        await lock.acquire()
        defer { lock.release() }
        attach()
        wanted = op
        let reload = !loadMore || currentOp != op

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Post], Error>) in
            pending = cont
            let token = UUID()
            pendingToken = token
            triedTab = false
            if reload {
                webView.load(URLRequest(url: URL(string: "https://x.com/home")!))
            } else {
                webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);", completionHandler: nil)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if self.pendingToken == token, let p = self.pending {
                    self.pending = nil
                    p.resume(throwing: XError.timeout)
                }
            }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any],
              let url = d["url"] as? String, let body = d["body"] as? String else { return }
        handle(url: url, body: body)
    }

    private func handle(url: String, body: String) {
        guard let m = url.range(of: #"/graphql/[^/]+/(HomeLatestTimeline|HomeTimeline)"#, options: .regularExpression)
        else { return }
        let opName = String(url[m]).split(separator: "/").last.map(String.init) ?? ""
        guard let op = XOp(rawValue: opName) else { return }

        if op == wanted {
            guard let cont = pending, let data = body.data(using: .utf8) else { return }
            pending = nil
            currentOp = op
            do { cont.resume(returning: try XTimelineParser.parse(data)) }
            catch { cont.resume(throwing: error) }
        } else if !triedTab, pending != nil {
            // The page opened on the other tab ("For you" vs "Following"). Click ours.
            triedTab = true
            clickTab(wanted)
        }
    }

    private func clickTab(_ op: XOp) {
        let js = """
        (function(label){
          const find = () => Array.from(document.querySelectorAll('[role="tab"]'))
            .find(t => (t.innerText || '').trim().toLowerCase() === label);
          let n = 0;
          const iv = setInterval(() => {
            const t = find();
            if (t) { t.click(); clearInterval(iv); }
            else if (++n > 40) clearInterval(iv);
          }, 250);
        })('\(op.tabLabel)');
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
