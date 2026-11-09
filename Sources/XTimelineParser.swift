import Foundation

enum XError: Error, LocalizedError {
    case badResponse, timeout, notLoggedIn, actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .actionFailed(let why): return "Twitter action failed (\(why))"
        case .badResponse: return "Unexpected response from Twitter"
        case .timeout: return "Timed out waiting for Twitter. Are you signed in?"
        case .notLoggedIn: return "Not signed in to Twitter. Connect it in Settings (profile tab)."
        }
    }
}

/// Turns X's private GraphQL timeline JSON into `Post`s.
enum XTimelineParser {
    static func parse(_ data: Data) throws -> [Post] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XError.badResponse
        }
        let instructions = dig(root, ["data", "home", "home_timeline_urt", "instructions"]) as? [[String: Any]] ?? []
        var posts: [Post] = []
        for ins in instructions {
            guard let entries = ins["entries"] as? [[String: Any]] else { continue }
            for e in entries {
                // Only plain tweets: skips cursors, promoted items, who-to-follow, conversation modules.
                guard (e["entryId"] as? String ?? "").hasPrefix("tweet-"),
                      var r = dig(e, ["content", "itemContent", "tweet_results", "result"]) as? [String: Any]
                else { continue }
                if let inner = r["tweet"] as? [String: Any] { r = inner } // TweetWithVisibilityResults
                if let p = post(from: r) { posts.append(p) }
            }
        }
        return posts
    }

    /// Replies from a TweetDetail response (everything except the focal tweet itself).
    static func parseDetail(_ data: Data, excluding focalID: String) -> [Post] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let instructions = dig(root, ["data", "threaded_conversation_with_injections_v2", "instructions"]) as? [[String: Any]] ?? []
        var out: [Post] = []
        var seen = Set<String>([focalID])
        func add(_ item: [String: Any]) {
            guard var r = dig(item, ["itemContent", "tweet_results", "result"]) as? [String: Any] else { return }
            if let inner = r["tweet"] as? [String: Any] { r = inner }
            if let p = post(from: r), seen.insert(p.id).inserted { out.append(p) }
        }
        for ins in instructions {
            for e in (ins["entries"] as? [[String: Any]]) ?? [] {
                let id = e["entryId"] as? String ?? ""
                // Replies live in conversation modules; skip the focal tweet and its ancestors.
                guard id.hasPrefix("conversationthread-") else { continue }
                for it in (dig(e, ["content", "items"]) as? [[String: Any]]) ?? [] {
                    if let item = it["item"] as? [String: Any] { add(item) }
                }
            }
        }
        return out
    }

    static func post(from raw: [String: Any]) -> Post? {
        var r = raw
        var repostedBy: String?
        // Retweets: show the original, remember who reposted.
        if let rt = dig(r, ["legacy", "retweeted_status_result", "result"]) as? [String: Any] {
            repostedBy = displayName(of: r)
            r = (rt["tweet"] as? [String: Any]) ?? rt
        }
        guard let legacy = r["legacy"] as? [String: Any],
              let id = r["rest_id"] as? String else { return nil }

        let user = dig(r, ["core", "user_results", "result"]) as? [String: Any] ?? [:]
        let ulegacy = user["legacy"] as? [String: Any] ?? [:]
        let handle = (dig(user, ["core", "screen_name"]) as? String) ?? (ulegacy["screen_name"] as? String) ?? "unknown"
        let name = (dig(user, ["core", "name"]) as? String) ?? (ulegacy["name"] as? String) ?? handle
        let avatar = (dig(user, ["avatar", "image_url"]) as? String) ?? (ulegacy["profile_image_url_https"] as? String)

        // Text: long-form note if present, then expand t.co links and drop media links.
        let note = dig(r, ["note_tweet", "note_tweet_results", "result"]) as? [String: Any]
        var text = (note?["text"] as? String) ?? (legacy["full_text"] as? String) ?? ""
        var urlEntities = (dig(legacy, ["entities", "urls"]) as? [[String: Any]]) ?? []
        if let n = note, let more = dig(n, ["entity_set", "urls"]) as? [[String: Any]] { urlEntities += more }
        for u in urlEntities {
            if let short = u["url"] as? String, let full = u["expanded_url"] as? String {
                text = text.replacingOccurrences(of: short, with: full)
            }
        }

        let media = (dig(legacy, ["extended_entities", "media"]) as? [[String: Any]])
            ?? (dig(legacy, ["entities", "media"]) as? [[String: Any]]) ?? []
        var images: [URL] = []
        var videos: [PostVideo] = []
        for m in media {
            if let short = m["url"] as? String { text = text.replacingOccurrences(of: short, with: "") }
            let type = m["type"] as? String
            if type == "video" || type == "animated_gif" {
                let variants = (dig(m, ["video_info", "variants"]) as? [[String: Any]]) ?? []
                let best = variants
                    .filter { ($0["content_type"] as? String) == "video/mp4" }
                    .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
                if let u = (best?["url"] as? String).flatMap(URL.init(string:)) {
                    videos.append(PostVideo(url: u, poster: (m["media_url_https"] as? String).flatMap(URL.init(string:)),
                                            gif: type == "animated_gif"))
                    continue
                }
            }
            if let s = m["media_url_https"] as? String, let u = URL(string: s) { images.append(u) }
        }
        text = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        let date = (legacy["created_at"] as? String).flatMap(f.date(from:)) ?? Date()

        return Post(id: id, network: .x, authorHandle: handle, authorName: name,
                    avatarURL: avatar.flatMap(URL.init(string:)), text: text, createdAt: date,
                    replyCount: legacy["reply_count"] as? Int ?? 0,
                    repostCount: legacy["retweet_count"] as? Int ?? 0,
                    likeCount: legacy["favorite_count"] as? Int ?? 0,
                    images: images, videos: videos, repostedBy: repostedBy,
                    url: URL(string: "https://x.com/\(handle)/status/\(id)"),
                    liked: legacy["favorited"] as? Bool ?? false,
                    reposted: legacy["retweeted"] as? Bool ?? false)
    }

    private static func displayName(of r: [String: Any]) -> String? {
        let user = dig(r, ["core", "user_results", "result"]) as? [String: Any] ?? [:]
        return (dig(user, ["core", "name"]) as? String) ?? (dig(user, ["legacy", "name"]) as? String)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func dig(_ obj: Any, _ path: [String]) -> Any? {
        var cur: Any = obj
        for k in path {
            guard let d = cur as? [String: Any], let n = d[k] else { return nil }
            cur = n
        }
        return cur
    }
}
