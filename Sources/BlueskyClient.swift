import Foundation

struct BskySession: Codable {
    var accessJwt: String
    var refreshJwt: String
    var did: String
    var handle: String
}

enum BskyError: Error, LocalizedError {
    case notLoggedIn, http(Int, String), badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not signed in to Bluesky. Sign in from Settings (profile tab)."
        case .http(let c, let b): return "Bluesky error \(c): \(b.prefix(150))"
        case .badResponse: return "Unexpected response from Bluesky"
        }
    }
}

// MARK: - Wire types

struct BskyFeedResponse: Decodable {
    let feed: [BskyFeedItem]
    let cursor: String?
}

struct BskyFeedItem: Decodable {
    let post: BskyPost
    let reason: BskyReason?
}

struct BskyReason: Decodable {
    let by: BskyAuthor?
}

struct BskyAuthor: Decodable {
    let handle: String
    let displayName: String?
    let avatar: String?
}

struct BskyRef: Decodable {
    let uri: String
    let cid: String
}

struct BskyReplyRef: Decodable {
    let root: BskyRef
    let parent: BskyRef
}

struct BskyByteSlice: Decodable {
    let byteStart: Int
    let byteEnd: Int
}

struct BskyFacetFeature: Decodable {
    let uri: String?
}

struct BskyFacet: Decodable {
    let index: BskyByteSlice?
    let features: [BskyFacetFeature]?
}

struct BskyRecord: Decodable {
    let text: String?
    let reply: BskyReplyRef?
    let facets: [BskyFacet]?
}

struct BskyImage: Decodable {
    let thumb: String?
    let fullsize: String?
    let aspectRatio: BskyRatio?
}

struct BskyRatio: Decodable {
    let width: Double
    let height: Double
}

final class BskyEmbed: Decodable {
    let images: [BskyImage]?
    let thumbnail: String?   // video poster
    let playlist: String?    // video HLS playlist
    let record: BskyRecordView? // quoted post (record / recordWithMedia)
    let media: BskyEmbed?    // recordWithMedia
}

final class BskyRecordView: Decodable {
    let uri: String?
    let cid: String?
    let indexedAt: String?
    let author: BskyAuthor?
    let text: String?
    let embeds: [BskyEmbed]?
    let record: BskyRecordView?
    enum K: String, CodingKey { case uri, cid, indexedAt, author, value, embeds, record }
    // Tolerant on purpose: quoted records can be posts, lists, feeds or blocked, and must never break a feed decode.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        uri = try? c.decode(String.self, forKey: .uri)
        cid = try? c.decode(String.self, forKey: .cid)
        indexedAt = try? c.decode(String.self, forKey: .indexedAt)
        author = try? c.decode(BskyAuthor.self, forKey: .author)
        if let rec = try? c.decode(BskyRecord.self, forKey: .value) {
            text = BlueskyClient.expandFacets(rec.text ?? "", facets: rec.facets)
        } else {
            text = nil
        }
        embeds = try? c.decode([BskyEmbed].self, forKey: .embeds)
        record = try? c.decode(BskyRecordView.self, forKey: .record)
    }
}

struct BskySearchResponse: Decodable {
    let posts: [BskyPost]
}

struct BskyNotifResponse: Decodable {
    let notifications: [BskyNotif]
}

struct BskyNotif: Decodable {
    let uri: String
    let author: BskyAuthor
    let reason: String
    let reasonSubject: String?
    let indexedAt: String
}

struct BskyViewer: Decodable {
    let like: String?
    let repost: String?
}

struct BskyPost: Decodable {
    let uri: String
    let cid: String
    let author: BskyAuthor
    let record: BskyRecord
    let embed: BskyEmbed?
    let replyCount: Int?
    let repostCount: Int?
    let likeCount: Int?
    let indexedAt: String
    let viewer: BskyViewer?
}

struct BskyThreadResponse: Decodable {
    let thread: BskyThreadNode
}

final class BskyThreadNode: Decodable {
    let post: BskyPost?
    let parent: BskyThreadNode?
    let replies: [BskyThreadNode]?
}

// MARK: - Client

actor BlueskyClient {
    private static let key = "bsky.session"
    private let base = "https://bsky.social/xrpc/"
    private var session: BskySession?

    init() {
        session = Secrets.load(BskySession.self, key: BlueskyClient.key)
    }

    var isLoggedIn: Bool { session != nil }
    var handle: String? { session?.handle }

    func login(identifier: String, password: String) async throws {
        var id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("@") { id.removeFirst() }
        var req = URLRequest(url: URL(string: base + "com.atproto.server.createSession")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["identifier": id, "password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw BskyError.http(code, String(decoding: data, as: UTF8.self)) }
        let s = try JSONDecoder().decode(BskySession.self, from: data)
        session = s
        Secrets.save(s, key: BlueskyClient.key)
    }

    func logout() {
        session = nil
        Secrets.clear(key: BlueskyClient.key)
    }

    // MARK: Reading

    func timeline(cursor: String?) async throws -> (posts: [Post], cursor: String?) {
        var q = [URLQueryItem(name: "limit", value: "40")]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try BlueskyClient.decodeFeed(try await get("app.bsky.feed.getTimeline", q))
    }

    func feed(uri: String, cursor: String?) async throws -> (posts: [Post], cursor: String?) {
        var q = [URLQueryItem(name: "feed", value: uri), URLQueryItem(name: "limit", value: "40")]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try BlueskyClient.decodeFeed(try await get("app.bsky.feed.getFeed", q))
    }

    func search(query: String) async throws -> [Post] {
        let data = try await get("app.bsky.feed.searchPosts", [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "40"),
        ])
        let r = try JSONDecoder().decode(BskySearchResponse.self, from: data)
        return r.posts.map { BlueskyClient.map($0, repostedBy: nil) }
    }

    /// Recent notifications, plus the posts behind replies, mentions, quotes, likes and reposts so they can be opened.
    func notifications() async throws -> (items: [BskyNotif], posts: [Post]) {
        let data = try await get("app.bsky.notification.listNotifications", [URLQueryItem(name: "limit", value: "40")])
        let items = try JSONDecoder().decode(BskyNotifResponse.self, from: data).notifications
        var seen = Set<String>()
        var uris: [String] = []
        for n in items {
            let target: String?
            if ["reply", "mention", "quote"].contains(n.reason) {
                target = n.uri
            } else if ["like", "repost"].contains(n.reason) {
                target = n.reasonSubject
            } else {
                target = nil
            }
            if let u = target, u.contains("/app.bsky.feed.post/"), seen.insert(u).inserted {
                uris.append(u)
            }
        }
        var posts: [Post] = []
        var offset = 0
        while offset < uris.count {
            let chunk = Array(uris[offset..<min(offset + 25, uris.count)])
            offset += 25
            let q = chunk.map { URLQueryItem(name: "uris", value: $0) }
            if let d = try? await get("app.bsky.feed.getPosts", q),
               let r = try? JSONDecoder().decode(BskySearchResponse.self, from: d) {
                posts += r.posts.map { BlueskyClient.map($0, repostedBy: nil) }
            }
        }
        return (items, posts)
    }

    /// Parents above a post (oldest first) and replies under it (flattened depth-first).
    func threadWithParents(uri: String) async throws -> (parents: [Post], replies: [Post]) {
        let data = try await get("app.bsky.feed.getPostThread", [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "depth", value: "3"),
            URLQueryItem(name: "parentHeight", value: "10"),
        ])
        let r = try JSONDecoder().decode(BskyThreadResponse.self, from: data)
        var parents: [Post] = []
        var cur = r.thread.parent
        var seenParents = Set<String>()
        while let node = cur {
            if let p = node.post, seenParents.insert(p.uri).inserted {
                parents.append(BlueskyClient.map(p, repostedBy: nil))
            }
            cur = node.parent
        }
        parents.reverse()

        var replies: [Post] = []
        func walk(_ nodes: [BskyThreadNode]?) {
            for n in nodes ?? [] {
                guard let p = n.post else { continue }
                replies.append(BlueskyClient.map(p, repostedBy: nil))
                walk(n.replies)
            }
        }
        walk(r.thread.replies)
        return (parents, replies)
    }

    /// Replies under a post, flattened depth-first.
    func thread(uri: String) async throws -> [Post] {
        try await threadWithParents(uri: uri).replies
    }

    /// The user's saved/pinned custom feeds, so they can be added as tabs.
    func savedFeeds() async throws -> [FeedDef] {
        let prefs = try await get("app.bsky.actor.getPreferences", [])
        guard let root = try JSONSerialization.jsonObject(with: prefs) as? [String: Any],
              let arr = root["preferences"] as? [[String: Any]] else { return [] }
        var uris: [String] = []
        for p in arr where (p["$type"] as? String) == "app.bsky.actor.defs#savedFeedsPrefV2" {
            for it in (p["items"] as? [[String: Any]]) ?? [] where (it["type"] as? String) == "feed" {
                if let v = it["value"] as? String { uris.append(v) }
            }
        }
        guard !uris.isEmpty else { return [] }
        let q = uris.prefix(25).map { URLQueryItem(name: "feeds", value: $0) }
        let data = try await get("app.bsky.feed.getFeedGenerators", q)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feeds = obj["feeds"] as? [[String: Any]] else { return [] }
        return feeds.compactMap { f in
            guard let uri = f["uri"] as? String, let name = f["displayName"] as? String else { return nil }
            return FeedDef(id: "bsky:\(uri)", title: "Bluesky: \(name)", kind: .bskyGenerator, generatorURI: uri)
        }
    }

    // MARK: Writing

    func like(uri: String, cid: String) async throws -> String {
        try await createRecord("app.bsky.feed.like", [
            "$type": "app.bsky.feed.like",
            "subject": ["uri": uri, "cid": cid],
            "createdAt": Self.now(),
        ])
    }

    func unlike(recordURI: String) async throws {
        try await deleteRecord("app.bsky.feed.like", recordURI)
    }

    func repost(uri: String, cid: String) async throws -> String {
        try await createRecord("app.bsky.feed.repost", [
            "$type": "app.bsky.feed.repost",
            "subject": ["uri": uri, "cid": cid],
            "createdAt": Self.now(),
        ])
    }

    func unrepost(recordURI: String) async throws {
        try await deleteRecord("app.bsky.feed.repost", recordURI)
    }

    func createPost(text: String) async throws {
        var rec: [String: Any] = [
            "$type": "app.bsky.feed.post",
            "text": text,
            "createdAt": Self.now(),
        ]
        let facets = Self.detectLinkFacets(in: text)
        if !facets.isEmpty { rec["facets"] = facets }
        _ = try await createRecord("app.bsky.feed.post", rec)
    }

    func reply(text: String, parent: (uri: String, cid: String), root: (uri: String, cid: String)) async throws {
        var rec: [String: Any] = [
            "$type": "app.bsky.feed.post",
            "text": text,
            "createdAt": Self.now(),
            "reply": [
                "root": ["uri": root.uri, "cid": root.cid],
                "parent": ["uri": parent.uri, "cid": parent.cid],
            ],
        ]
        let facets = Self.detectLinkFacets(in: text)
        if !facets.isEmpty { rec["facets"] = facets }
        _ = try await createRecord("app.bsky.feed.post", rec)
    }

    private func createRecord(_ collection: String, _ record: [String: Any]) async throws -> String {
        guard let did = session?.did else { throw BskyError.notLoggedIn }
        let data = try await send("com.atproto.repo.createRecord",
                                  ["repo": did, "collection": collection, "record": record])
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uri = o["uri"] as? String else { throw BskyError.badResponse }
        return uri
    }

    private func deleteRecord(_ collection: String, _ recordURI: String) async throws {
        guard let did = session?.did else { throw BskyError.notLoggedIn }
        guard let rkey = recordURI.split(separator: "/").last.map(String.init) else { throw BskyError.badResponse }
        _ = try await send("com.atproto.repo.deleteRecord",
                           ["repo": did, "collection": collection, "rkey": rkey])
    }

    // MARK: Networking

    private func get(_ method: String, _ query: [URLQueryItem]) async throws -> Data {
        for attempt in 0..<2 {
            guard let s = session else { throw BskyError.notLoggedIn }
            var comps = URLComponents(string: base + method)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(s.accessJwt)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            let body = String(decoding: data, as: UTF8.self)
            if attempt == 0, body.contains("ExpiredToken") {
                try await refresh()
                continue
            }
            throw BskyError.http(code, body)
        }
        throw BskyError.badResponse
    }

    private func send(_ method: String, _ body: [String: Any]) async throws -> Data {
        for attempt in 0..<2 {
            guard let s = session else { throw BskyError.notLoggedIn }
            var req = URLRequest(url: URL(string: base + method)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(s.accessJwt)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            let text = String(decoding: data, as: UTF8.self)
            if attempt == 0, text.contains("ExpiredToken") {
                try await refresh()
                continue
            }
            throw BskyError.http(code, text)
        }
        throw BskyError.badResponse
    }

    private func refresh() async throws {
        guard let s = session else { throw BskyError.notLoggedIn }
        var req = URLRequest(url: URL(string: base + "com.atproto.server.refreshSession")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(s.refreshJwt)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let fresh = try? JSONDecoder().decode(BskySession.self, from: data) else {
            logout()
            throw BskyError.notLoggedIn
        }
        session = fresh
        Secrets.save(fresh, key: BlueskyClient.key)
    }

    // MARK: Mapping

    static func decodeFeed(_ data: Data) throws -> (posts: [Post], cursor: String?) {
        let r = try JSONDecoder().decode(BskyFeedResponse.self, from: data)
        let posts = r.feed.map { item -> Post in
            let by = item.reason?.by
            return map(item.post, repostedBy: by.map { $0.displayName ?? $0.handle })
        }
        return (posts, r.cursor)
    }

    static func map(_ p: BskyPost, repostedBy: String?) -> Post {
        let rkey = p.uri.split(separator: "/").last.map(String.init) ?? ""
        let name = (p.author.displayName?.isEmpty == false) ? p.author.displayName! : p.author.handle
        let fullText = expandFacets(p.record.text ?? "", facets: p.record.facets)
        return Post(id: p.uri, network: .bluesky,
                    authorHandle: p.author.handle, authorName: name,
                    avatarURL: p.author.avatar.flatMap(URL.init(string:)),
                    text: fullText, createdAt: parseDate(p.indexedAt),
                    replyCount: p.replyCount ?? 0, repostCount: p.repostCount ?? 0, likeCount: p.likeCount ?? 0,
                    images: imageURLs(p.embed), videos: videoList(p.embed), quote: quote(p.embed), imageRatio: ratio(p.embed),
                    repostedBy: repostedBy,
                    url: URL(string: "https://bsky.app/profile/\(p.author.handle)/post/\(rkey)"),
                    liked: p.viewer?.like != nil,
                    reposted: p.viewer?.repost != nil,
                    cid: p.cid,
                    likeRecord: p.viewer?.like,
                    repostRecord: p.viewer?.repost,
                    rootURI: p.record.reply?.root.uri ?? p.uri,
                    rootCID: p.record.reply?.root.cid ?? p.cid)
    }

    /// Replaces truncated link spans in Bluesky post text with their full facet URIs so links work when tapped.
    static func expandFacets(_ text: String, facets: [BskyFacet]?) -> String {
        guard let facets, !facets.isEmpty, !text.isEmpty else { return text }
        var utf8 = Array(text.utf8)
        let sorted = facets.sorted { ($0.index?.byteStart ?? 0) > ($1.index?.byteStart ?? 0) }
        for f in sorted {
            guard let idx = f.index,
                  let uri = f.features?.compactMap(\.uri).first,
                  !uri.isEmpty,
                  idx.byteStart >= 0, idx.byteEnd <= utf8.count, idx.byteStart < idx.byteEnd else { continue }
            utf8.replaceSubrange(idx.byteStart..<idx.byteEnd, with: uri.utf8)
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    /// Detects URLs in outgoing post text and encodes AT Protocol link facets with UTF-8 byte offsets.
    private static func detectLinkFacets(in text: String) -> [[String: Any]] {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let matches = det.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        var out: [[String: Any]] = []
        for m in matches {
            guard let url = m.url,
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let range = Range(m.range, in: text) else { continue }
            let start = text[..<range.lowerBound].utf8.count
            let end = start + text[range].utf8.count
            out.append([
                "index": ["byteStart": start, "byteEnd": end],
                "features": [["$type": "app.bsky.richtext.facet#link", "uri": url.absoluteString]],
            ])
        }
        return out
    }

    private static func quote(_ e: BskyEmbed?) -> QuotedPost? {
        guard let r = e?.record else { return nil }
        let v = r.author == nil ? r.record : r
        guard let v, let a = v.author, let t = v.text else { return nil }
        let uri = v.uri ?? ""
        let rkey = uri.split(separator: "/").last.map(String.init) ?? ""
        let imgs = (v.embeds ?? []).flatMap { imageURLs($0) }
        return QuotedPost(name: (a.displayName?.isEmpty == false) ? a.displayName! : a.handle,
                          handle: a.handle, avatar: a.avatar.flatMap(URL.init(string:)), text: t,
                          id: uri, network: .bluesky, date: v.indexedAt.map(parseDate) ?? Date(), images: imgs,
                          url: URL(string: "https://bsky.app/profile/\(a.handle)/post/\(rkey)"), cid: v.cid)
    }

    private static func ratio(_ e: BskyEmbed?) -> CGFloat? {
        guard let e else { return nil }
        if let r = e.images?.first?.aspectRatio, r.height > 0 { return CGFloat(r.width / r.height) }
        return ratio(e.media)
    }

    private static func videoList(_ e: BskyEmbed?) -> [PostVideo] {
        guard let e else { return [] }
        if let p = e.playlist, let u = URL(string: p) {
            return [PostVideo(url: u, poster: e.thumbnail.flatMap(URL.init(string:)))]
        }
        return videoList(e.media)
    }

    private static func imageURLs(_ e: BskyEmbed?) -> [URL] {
        guard let e else { return [] }
        var out = (e.images ?? []).compactMap { ($0.thumb ?? $0.fullsize).flatMap(URL.init(string:)) }
        if e.playlist == nil, let t = e.thumbnail, let u = URL(string: t) { out.append(u) }
        if out.isEmpty, let m = e.media { out = imageURLs(m) }
        return out
    }

    private static func parseDate(_ s: String) -> Date {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s) ?? Date()
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
