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

struct BskyRecord: Decodable {
    let text: String?
}

struct BskyImage: Decodable {
    let thumb: String?
    let fullsize: String?
}

final class BskyEmbed: Decodable {
    let images: [BskyImage]?
    let thumbnail: String?   // video poster
    let media: BskyEmbed?    // recordWithMedia
}

struct BskyPost: Decodable {
    let uri: String
    let author: BskyAuthor
    let record: BskyRecord
    let embed: BskyEmbed?
    let replyCount: Int?
    let repostCount: Int?
    let likeCount: Int?
    let indexedAt: String
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
            let p = item.post
            let rkey = p.uri.split(separator: "/").last.map(String.init) ?? ""
            let name = (p.author.displayName?.isEmpty == false) ? p.author.displayName! : p.author.handle
            let by = item.reason?.by
            return Post(id: p.uri, network: .bluesky,
                        authorHandle: p.author.handle, authorName: name,
                        avatarURL: p.author.avatar.flatMap(URL.init(string:)),
                        text: p.record.text ?? "", createdAt: parseDate(p.indexedAt),
                        replyCount: p.replyCount ?? 0, repostCount: p.repostCount ?? 0, likeCount: p.likeCount ?? 0,
                        images: imageURLs(p.embed),
                        repostedBy: by.map { $0.displayName ?? $0.handle },
                        url: URL(string: "https://bsky.app/profile/\(p.author.handle)/post/\(rkey)"))
        }
        return (posts, r.cursor)
    }

    private static func imageURLs(_ e: BskyEmbed?) -> [URL] {
        guard let e else { return [] }
        var out = (e.images ?? []).compactMap { ($0.thumb ?? $0.fullsize).flatMap(URL.init(string:)) }
        if let t = e.thumbnail, let u = URL(string: t) { out.append(u) }
        if out.isEmpty, let m = e.media { out = imageURLs(m) }
        return out
    }

    private static func parseDate(_ s: String) -> Date {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s) ?? Date()
    }
}
