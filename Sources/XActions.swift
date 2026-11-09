import UIKit
import WebKit

enum XAction {
    case like(Bool)      // true = like, false = unlike
    case repost(Bool)    // true = retweet, false = undo
    case reply(String)
    case post(String)
}

/// Performs write actions on X by driving x.com in a second hidden webview, using the
/// real page's buttons. That sidesteps request signing entirely, at the cost of being
/// tied to X's markup (data-testid attributes), which have been stable for years.
@MainActor
final class XActionRunner: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let lock = AsyncLock()
    private var navCont: CheckedContinuation<Void, Never>?
    private var navToken = UUID()

    override init() {
        webView = WKWebView(frame: CGRect(x: -2000, y: 0, width: 1000, height: 1200),
                            configuration: WKWebViewConfiguration())
        webView.customUserAgent = xUserAgent
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        super.init()
        webView.navigationDelegate = self
    }

    private func attach() {
        guard webView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(webView)
    }

    func run(_ action: XAction, statusURL: URL?) async throws {
        await lock.acquire()
        defer { lock.release() }
        attach()

        let op: String
        var text = ""
        var target = statusURL
        switch action {
        case .like(let on): op = on ? "like" : "unlike"
        case .repost(let on): op = on ? "retweet" : "unretweet"
        case .reply(let t): op = "reply"; text = t
        case .post(let t): op = "post"; text = t; target = URL(string: "https://x.com/compose/post")
        }
        guard let target else { throw XError.badResponse }

        // Tweet id for finding the right article on the status page.
        let id = statusURL?.lastPathComponent ?? ""

        await load(target)
        let result = try await webView.callAsyncJavaScript(
            Self.script,
            arguments: ["op": op, "id": id, "text": text],
            in: nil, contentWorld: .page)
        let s = (result as? String) ?? "no-result"
        guard s == "ok" || s == "already" else { throw XError.actionFailed(s) }
    }

    // MARK: Navigation

    private func load(_ url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            navCont = c
            let token = UUID()
            navToken = token
            webView.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if self.navToken == token { self.finishNav() }
            }
        }
    }

    private func finishNav() {
        navCont?.resume()
        navCont = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNav() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNav() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNav() }

    // MARK: Page script (function body: has `op`, `id`, `text`)

    private static let script = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const waitFor = async (fn, ms) => {
      const t = Date.now();
      while (Date.now() - t < (ms || 15000)) { const v = fn(); if (v) return v; await sleep(250); }
      return null;
    };
    const clickEl = el => { el.scrollIntoView({block: 'center'}); el.click(); };
    const typeInto = async (t) => {
      const box = await waitFor(() => document.querySelector('[data-testid="tweetTextarea_0"]'));
      if (!box) return false;
      box.focus();
      await sleep(300);
      document.execCommand('insertText', false, t);
      await sleep(400);
      return true;
    };
    const submit = async () => {
      const btn = await waitFor(() => {
        const b = document.querySelector('[data-testid="tweetButton"]') || document.querySelector('[data-testid="tweetButtonInline"]');
        return (b && b.getAttribute('aria-disabled') !== 'true') ? b : null;
      });
      if (!btn) return 'submit-not-found';
      btn.click();
      await sleep(1500);
      return 'ok';
    };

    if (op === 'post') {
      if (!(await typeInto(text))) return 'editor-not-found';
      return await submit();
    }

    const art = await waitFor(() => {
      const t = document.querySelector('a[href*="/status/' + id + '"] time');
      return t ? t.closest('article') : null;
    });
    if (!art) return 'tweet-not-found';

    if (op === 'like' || op === 'unlike') {
      const b = art.querySelector('[data-testid="' + op + '"]');
      if (!b) return 'already';
      clickEl(b); await sleep(800); return 'ok';
    }
    if (op === 'retweet' || op === 'unretweet') {
      const b = art.querySelector('[data-testid="' + op + '"]');
      if (!b) return 'already';
      clickEl(b);
      const c = await waitFor(() => document.querySelector('[data-testid="' + op + 'Confirm"]'));
      if (!c) return 'confirm-not-found';
      c.click(); await sleep(800); return 'ok';
    }
    if (op === 'reply') {
      const b = art.querySelector('[data-testid="reply"]');
      if (!b) return 'reply-button-not-found';
      clickEl(b);
      if (!(await typeInto(text))) return 'editor-not-found';
      return await submit();
    }
    return 'unknown-op';
    """
}
