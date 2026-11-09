import Foundation

enum XError: Error, LocalizedError {
    case http(Int, String)
    case badResponse
    case queryIDNotFound(String)

    var errorDescription: String? {
        switch self {
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(300))"
        case .badResponse: return "Unexpected response shape"
        case .queryIDNotFound(let n): return "Couldn't find queryId for \(n)"
        }
    }
}

/// Direct-call transport (Plan A). Talks to X's private web GraphQL API from the device.
/// NOTE: written without being able to reach X, so expect to tune headers / endpoints. See README.
actor XClient: FeedSource {
    /// Public bearer baked into X's own web client. VERIFY against the current web bundle
    /// (search main.*.js for "AAAAAAAA") before trusting it.
    static let bearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    private let creds: XCredentials
    private let session: URLSession
    private var queryIDs: [String: String]
    private var features: [String: Bool] = XClient.baseFeatures
    private static let idsKey = "xspike.queryIDs"

    init(creds: XCredentials) {
        self.creds = creds
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: cfg)
        self.queryIDs = (UserDefaults.standard.dictionary(forKey: XClient.idsKey) as? [String: String]) ?? [:]
    }

    // MARK: - Public

    /// Chronological "Following" timeline (HomeLatestTimeline).
    func fetchHome(cursor: String?) async throws -> (posts: [Post], nextCursor: String?) {
        let op = "HomeLatestTimeline"
        var vars: [String: Any] = [
            "count": 40,
            "includePromotedContent": false,
            "latestControlAvailable": true,
            "requestContext": "launch",
        ]
        if let cursor { vars["cursor"] = cursor }

        for attempt in 0..<4 {
            let id = try await queryID(for: op)
            let body: [String: Any] = ["variables": vars, "features": features, "queryId": id]
            var req = URLRequest(url: URL(string: "https://x.com/i/api/graphql/\(id)/\(op)")!)
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            applyHeaders(&req)

            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return try XClient.parseTimeline(data) }

            let text = String(decoding: data, as: UTF8.self)
            if attempt < 3 {
                // X rejects requests missing feature flags and names them in the error. Fill and retry.
                if code == 400, absorbMissingFeatures(from: text) { continue }
                // Stale query id after a web deploy: rediscover and retry.
                if code == 404 {
                    queryIDs[op] = nil
                    try await refreshQueryIDs()
                    continue
                }
            }
            throw XError.http(code, text)
        }
        throw XError.badResponse
    }

    // MARK: - Headers

    private func applyHeaders(_ req: inout URLRequest) {
        req.setValue("Bearer \(XClient.bearer)", forHTTPHeaderField: "authorization")
        req.setValue(creds.ct0, forHTTPHeaderField: "x-csrf-token")
        req.setValue("auth_token=\(creds.authToken); ct0=\(creds.ct0)", forHTTPHeaderField: "cookie")
        req.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
        req.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
        req.setValue("en", forHTTPHeaderField: "x-twitter-client-language")
        req.setValue(xUserAgent, forHTTPHeaderField: "user-agent")
        req.setValue("https://x.com/home", forHTTPHeaderField: "referer")
        req.setValue("https://x.com", forHTTPHeaderField: "origin")
        // TODO if X returns 4xx with no useful body: it may want x-client-transaction-id.
        // That's what Plan B (XWebViewTransport) exists to dodge.
    }

    // MARK: - Query id discovery

    private func queryID(for op: String) async throws -> String {
        if let id = queryIDs[op] { return id }
        try await refreshQueryIDs()
        guard let id = queryIDs[op] else { throw XError.queryIDNotFound(op) }
        return id
    }

    /// Scrape queryId/operationName pairs out of X's web JS bundles.
    private func refreshQueryIDs() async throws {
        let html = try await getText("https://x.com/home")
        let scripts = XClient.matches(in: html,
            pattern: #"https://abs\.twimg\.com/responsive-web/client-web[^"' ]*?\.js"#).map { $0[0] }
        for url in scripts {
            guard let js = try? await getText(url) else { continue }
            for m in XClient.matches(in: js,
                pattern: #"queryId:"([A-Za-z0-9_-]+)",operationName:"([A-Za-z0-9_]+)""#) {
                queryIDs[m[2]] = m[1]
            }
            if queryIDs["HomeLatestTimeline"] != nil { break }
        }
        UserDefaults.standard.set(queryIDs, forKey: XClient.idsKey)
    }

    private func getText(_ url: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        applyHeaders(&req)
        let (data, _) = try await session.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    private func absorbMissingFeatures(from body: String) -> Bool {
        guard let m = XClient.matches(in: body, pattern: #"features cannot be null: ([A-Za-z0-9_, ]+)"#).first
        else { return false }
        var added = false
        for name in m[1].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if features[name] == nil { features[name] = false; added = true }
        }
        return added
    }

    static func matches(in s: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    // MARK: - Parsing (shared with the WebView transport)

    static func parseTimeline(_ data: Data) throws -> (posts: [Post], nextCursor: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XError.badResponse
        }
        let instructions = dig(root, ["data", "home", "home_timeline_urt", "instructions"]) as? [[String: Any]] ?? []
        var posts: [Post] = []
        var cursor: String?

        for ins in instructions {
            guard let entries = ins["entries"] as? [[String: Any]] else { continue }
            for e in entries {
                let entryID = e["entryId"] as? String ?? ""
                if entryID.hasPrefix("cursor-bottom") {
                    cursor = dig(e, ["content", "value"]) as? String
                } else if entryID.hasPrefix("tweet-"),
                          var r = dig(e, ["content", "itemContent", "tweet_results", "result"]) as? [String: Any] {
                    if let inner = r["tweet"] as? [String: Any] { r = inner } // TweetWithVisibilityResults
                    if let p = post(from: r) { posts.append(p) }
                }
            }
        }
        return (posts, cursor)
    }

    private static func post(from raw: [String: Any]) -> Post? {
        var r = raw
        var repostedBy: String?
        // Retweets: show the original, remember who reposted.
        if let rt = dig(r, ["legacy", "retweeted_status_result", "result"]) as? [String: Any] {
            repostedBy = userHandle(r)
            r = (rt["tweet"] as? [String: Any]) ?? rt
        }
        guard let legacy = r["legacy"] as? [String: Any],
              let id = r["rest_id"] as? String else { return nil }

        let text = (dig(r, ["note_tweet", "note_tweet_results", "result", "text"]) as? String)
            ?? (legacy["full_text"] as? String) ?? ""
        let user = dig(r, ["core", "user_results", "result"]) as? [String: Any] ?? [:]
        let ulegacy = user["legacy"] as? [String: Any] ?? [:]
        let handle = (dig(user, ["core", "screen_name"]) as? String) ?? (ulegacy["screen_name"] as? String) ?? "?"
        let name = (dig(user, ["core", "name"]) as? String) ?? (ulegacy["name"] as? String) ?? handle
        let avatar = (dig(user, ["avatar", "image_url"]) as? String) ?? (ulegacy["profile_image_url_https"] as? String)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        let date = (legacy["created_at"] as? String).flatMap(f.date(from:)) ?? Date()

        return Post(id: id, network: .x, authorHandle: handle, authorName: name,
                    avatarURL: avatar.flatMap(URL.init(string:)), text: text, createdAt: date,
                    likeCount: legacy["favorite_count"] as? Int ?? 0,
                    repostCount: legacy["retweet_count"] as? Int ?? 0,
                    repostedBy: repostedBy)
    }

    private static func userHandle(_ r: [String: Any]) -> String? {
        let user = dig(r, ["core", "user_results", "result"]) as? [String: Any] ?? [:]
        return (dig(user, ["core", "screen_name"]) as? String)
            ?? (dig(user, ["legacy", "screen_name"]) as? String)
    }

    private static func dig(_ obj: Any, _ path: [String]) -> Any? {
        var cur: Any = obj
        for k in path {
            guard let d = cur as? [String: Any], let n = d[k] else { return nil }
            cur = n
        }
        return cur
    }

    // MARK: - Feature flags (starting set; the 400-retry fills in whatever X currently demands)

    static let baseFeatures: [String: Bool] = [
        "rweb_video_screen_enabled": false,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_graphql_exclude_directive_enabled": true,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "view_counts_everywhere_api_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "tweet_awards_web_tipping_enabled": false,
        "responsive_web_enhance_cards_enabled": false,
    ]
}
