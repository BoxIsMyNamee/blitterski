import Foundation
import UIKit
import WebKit

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Feed definitions

struct FeedDef: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case combined, xForYou, xFollowing, bskyTimeline, bskyGenerator }

    var id: String
    var title: String
    var kind: Kind
    var generatorURI: String? = nil

    static let combined = FeedDef(id: "combined", title: "Combined", kind: .combined)
    static let xForYou = FeedDef(id: "x.foryou", title: "Twitter: For You", kind: .xForYou)
    static let xFollowing = FeedDef(id: "x.following", title: "Twitter: Following", kind: .xFollowing)
    static let bskyFollowing = FeedDef(id: "bsky.following", title: "Bluesky: Following", kind: .bskyTimeline)
    static let builtins: [FeedDef] = [.combined, .xForYou, .xFollowing, .bskyFollowing]
}

/// Which feeds show up as tabs, and in what order. Persisted.
@MainActor
final class FeedConfig: ObservableObject {
    @Published var shown: [FeedDef] { didSet { Self.save(shown, "feeds.shown") } }
    /// Bluesky custom feeds fetched from the user's account (offered as "available").
    @Published var extra: [FeedDef] { didSet { Self.save(extra, "feeds.extra") } }

    /// In-app-only display names, keyed by feed id.
    @Published var names: [String: String] { didSet { Self.save(names, "feeds.names") } }

    func title(_ f: FeedDef) -> String {
        let n = names[f.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? f.title : n
    }

    /// Feed ids that make up the Combined feed. Default: Twitter Following + Bluesky Following.
    @Published var combined: Set<String> {
        didSet { Self.save(Array(combined), "feeds.combined") }
    }

    /// Everything that can feed Combined (any single-source feed).
    var combinedCandidates: [FeedDef] {
        (FeedDef.builtins + extra).filter { $0.kind != .combined }
    }

    /// Same data read straight from disk, so the store doesn't need a reference to the config.
    static func loadCombined() -> [FeedDef] {
        let ids: [String] = load("feeds.combined") ?? [FeedDef.xFollowing.id, FeedDef.bskyFollowing.id]
        let extra: [FeedDef] = load("feeds.extra") ?? []
        return (FeedDef.builtins + extra).filter { $0.kind != .combined && ids.contains($0.id) }
    }

    init() {
        let saved: [String]? = Self.load("feeds.combined")
        combined = Set(saved ?? [FeedDef.xFollowing.id, FeedDef.bskyFollowing.id])
        names = Self.load("feeds.names") ?? [:]
        shown = Self.load("feeds.shown") ?? FeedDef.builtins
        extra = Self.load("feeds.extra") ?? []
    }

    var available: [FeedDef] {
        (FeedDef.builtins + extra).filter { f in !shown.contains { $0.id == f.id } }
    }

    private static func save<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

struct NotifItem: Identifiable {
    let id: String
    let reason: String
    let name: String
    let handle: String
    let avatar: URL?
    let date: Date
    let postID: String?
}

// MARK: - Feed loading

@MainActor
final class FeedStore: ObservableObject {
    struct State {
        var posts: [Post] = []
        var loading = false
        var error: String?
        var bskyCursor: String?
        var canLoadMore = true
        var loadedOnce = false
        var retryAfter = Date.distantPast
        var lastRefresh = Date.distantPast
    }

    @Published private(set) var states: [String: State] = [:]
    @Published var xConnected: Bool
    @Published var bskyHandle: String? = nil
    @Published var toast: String? = nil
    @Published var notifs: [NotifItem] = []
    @Published var notifLoading = false
    @Published var notifError: String?
    @Published var searchError: String?
    @Published var searching = false

    let x = XWebSource()
    let xActions = XActionRunner()
    let bsky = BlueskyClient()

    init() {
        xConnected = XSession.load() != nil
    }

    func bootstrap() async {
        bskyHandle = await bsky.handle
    }

    func state(for feed: FeedDef) -> State { states[feed.id] ?? State() }

    private func update(_ feed: FeedDef, _ body: (inout State) -> Void) {
        var s = state(for: feed)
        body(&s)
        states[feed.id] = s
    }

    // MARK: Load

    func refresh(_ feed: FeedDef) async {
        guard !state(for: feed).loading else { return }
        // Show the last session's posts immediately while the network catches up.
        if state(for: feed).posts.isEmpty, let cached = Self.readCache(feed) {
            update(feed) { $0.posts = cached }
            registerQuotes(cached)
        }
        update(feed) { $0.loading = true; $0.error = nil }
        var attempt = 0
        while true {
            do {
                let r = try await fetchPage(feed, more: false, cursor: nil)
                let posts = Self.order(Self.unique(r.posts), feed)
                update(feed) {
                    $0.posts = posts
                    $0.bskyCursor = r.cursor
                    $0.canLoadMore = true
                    $0.retryAfter = .distantPast
                    $0.loadedOnce = true
                    $0.lastRefresh = Date()
                }
                Self.writeCache(feed, posts)
                registerQuotes(posts)
                break
            } catch {
                attempt += 1
                // X occasionally needs a second go (page was still loading, response missed).
                if attempt < 2, case XError.timeout = error { continue }
                update(feed) { $0.error = error.localizedDescription; $0.loadedOnce = true }
                break
            }
        }
        update(feed) { $0.loading = false }
    }

    /// Quoted posts become real, openable posts (kept in their own hidden list so likes and replies work on them).
    private func registerQuotes(_ posts: [Post]) {
        var st = states["quoted"] ?? State()
        var known = Set(st.posts.map(\.id))
        for p in posts {
            if let q = p.quote, !q.id.isEmpty, known.insert(q.id).inserted { st.posts.append(q.asPost) }
        }
        states["quoted"] = st
    }

    /// Pull-to-refresh equivalent for when the app comes back after a while.
    func refreshIfStale(_ feed: FeedDef, after seconds: TimeInterval = 600) async {
        let s = state(for: feed)
        guard s.loadedOnce, Date().timeIntervalSince(s.lastRefresh) > seconds else { return }
        await refresh(feed)
    }

    // MARK: Disk cache (last refresh per feed)

    private static func cacheURL(_ feed: FeedDef) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let safe = feed.id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return dir.appendingPathComponent("feed-\(safe).json")
    }

    private static func readCache(_ feed: FeedDef) -> [Post]? {
        guard let u = cacheURL(feed), let d = try? Data(contentsOf: u),
              let posts = try? JSONDecoder().decode([Post].self, from: d), !posts.isEmpty else { return nil }
        return posts
    }

    private static func writeCache(_ feed: FeedDef, _ posts: [Post]) {
        guard let u = cacheURL(feed), let d = try? JSONEncoder().encode(Array(posts.prefix(60))) else { return }
        try? d.write(to: u, options: .atomic)
    }

    func loadMore(_ feed: FeedDef) async {
        let s = state(for: feed)
        guard !s.loading, s.canLoadMore, s.loadedOnce, !s.posts.isEmpty, Date() > s.retryAfter else { return }
        update(feed) { $0.loading = true }
        do {
            let r = try await fetchPage(feed, more: true, cursor: s.bskyCursor)
            update(feed) { st in
                let known = Set(st.posts.map(\.id))
                let fresh = r.posts.filter { !known.contains($0.id) }
                st.posts = Self.order(Self.unique(st.posts + fresh), feed)
                st.bskyCursor = r.cursor
                if fresh.isEmpty && r.cursor == nil { st.canLoadMore = false }
            }
            registerQuotes(r.posts)
        } catch {
            // Transient failure (e.g. X timeout): try again later instead of giving up for good.
            update(feed) { $0.retryAfter = Date().addingTimeInterval(8) }
        }
        update(feed) { $0.loading = false }
    }

    /// Duplicate ids (a post reposted twice, overlapping pages) make SwiftUI lists misbehave.
    private static func unique(_ posts: [Post]) -> [Post] {
        var seen = Set<String>()
        return posts.filter { seen.insert($0.id).inserted }
    }

    /// Interleaves Twitter and Bluesky posts evenly across the batch without throwing away fetched posts
    /// when one side returns a smaller page.
    private static func mix(_ x: [Post], _ b: [Post]) -> [Post] {
        if x.isEmpty || b.isEmpty { return x + b }
        var out: [Post] = []
        out.reserveCapacity(x.count + b.count)
        var ix = 0, ib = 0
        while ix < x.count || ib < b.count {
            if ix < x.count && (ib >= b.count || Double(ix) / Double(x.count) <= Double(ib) / Double(b.count)) {
                out.append(x[ix])
                ix += 1
            } else if ib < b.count {
                out.append(b[ib])
                ib += 1
            }
        }
        return out
    }

    private static func order(_ posts: [Post], _ feed: FeedDef) -> [Post] {
        posts // combined pages are already interleaved; appended pages keep their place
    }

    private func fetchPage(_ feed: FeedDef, more: Bool, cursor: String?) async throws -> (posts: [Post], cursor: String?) {
        switch feed.kind {
        case .xForYou:
            guard xConnected else { throw XError.notLoggedIn }
            return (try await x.fetch(.forYou, loadMore: more), nil)
        case .xFollowing:
            guard xConnected else { throw XError.notLoggedIn }
            return (try await x.fetch(.following, loadMore: more), nil)
        case .bskyTimeline:
            return try await bsky.timeline(cursor: cursor)
        case .bskyGenerator:
            return try await bsky.feed(uri: feed.generatorURI ?? "", cursor: cursor)
        case .combined:
            let sources = FeedConfig.loadCombined()
            if sources.isEmpty {
                throw AppError(message: "No sources chosen for Combined. Pick them in Settings > Choose feeds.")
            }
            let xOps: [XOp] = sources.compactMap {
                $0.kind == .xForYou ? .forYou : ($0.kind == .xFollowing ? .following : nil)
            }
            let bsrc = sources.filter { $0.kind == .bskyTimeline || $0.kind == .bskyGenerator }
            var old: [String: String] = [:]
            if more, let c = cursor, let d = c.data(using: .utf8),
               let m = try? JSONDecoder().decode([String: String].self, from: d) { old = m }

            var errors: [Error] = []
            var xlists: [[Post]] = []
            for op in xOps {
                let (p, e) = await fetchOptionalX(op, more: more)
                xlists.append(p)
                if let e { errors.append(e) }
            }
            var blist: [Post] = []
            var newCursors: [String: String] = [:]
            if bskyHandle != nil {
                for f in bsrc {
                    if more && old[f.id] == nil { continue } // that source is exhausted
                    let cur = more ? old[f.id] : nil
                    do {
                        let r = f.kind == .bskyTimeline
                            ? try await bsky.timeline(cursor: cur)
                            : try await bsky.feed(uri: f.generatorURI ?? "", cursor: cur)
                        blist += r.posts
                        if let c = r.cursor { newCursors[f.id] = c }
                    } catch { errors.append(error) }
                }
            }
            // Several Twitter sources take turns; Bluesky is shuffled so refreshes feel fresh.
            var xs: [Post] = []
            let longest = xlists.map(\.count).max() ?? 0
            for i in 0..<longest { for l in xlists where i < l.count { xs.append(l[i]) } }
            let merged = Self.mix(Self.unique(xs), Self.unique(blist).shuffled())
            if merged.isEmpty, let e = errors.first { throw e }
            let enc = (try? JSONEncoder().encode(newCursors)).flatMap { String(data: $0, encoding: .utf8) }
            return (merged, newCursors.isEmpty ? nil : enc)
        }
    }

    private func fetchOptionalX(_ op: XOp, more: Bool) async -> ([Post], Error?) {
        guard xConnected else { return ([], nil) }
        do { return (try await x.fetch(op, loadMore: more), nil) }
        catch { return ([], error) }
    }

    private func fetchOptionalBsky(cursor: String?) async -> ((posts: [Post], cursor: String?), Error?) {
        guard bskyHandle != nil else { return (([], nil), nil) }
        do { return (try await bsky.timeline(cursor: cursor), nil) }
        catch { return (([], cursor), error) }
    }

    // MARK: Search and notifications (Bluesky)

    func search(_ q: String) async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true; searchError = nil
        do {
            let results = Self.unique(try await bsky.search(query: query))
            var st = State(); st.posts = results; st.loadedOnce = true
            states["search"] = st
            registerQuotes(results)
        } catch {
            searchError = bskyHandle == nil ? "Sign in to Bluesky in Settings to search." : error.localizedDescription
        }
        searching = false
    }

    func loadNotifications() async {
        guard bskyHandle != nil else { notifError = "Sign in to Bluesky in Settings to see notifications."; return }
        notifLoading = true; notifError = nil
        do {
            let r = try await bsky.notifications()
            let posts = Self.unique(r.posts)
            var st = State(); st.posts = posts; st.loadedOnce = true
            states["notif"] = st
            registerQuotes(posts)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var seenNotif = Set<String>()
            notifs = r.items.compactMap { n in
                let id = n.uri + ":" + n.reason + ":" + n.indexedAt
                guard seenNotif.insert(id).inserted else { return nil }
                let targetPostID: String?
                if ["reply", "mention", "quote"].contains(n.reason) {
                    targetPostID = n.uri
                } else if ["like", "repost"].contains(n.reason) {
                    targetPostID = n.reasonSubject
                } else {
                    targetPostID = nil
                }
                return NotifItem(
                    id: id, reason: n.reason,
                    name: (n.author.displayName?.isEmpty == false) ? n.author.displayName! : n.author.handle,
                    handle: n.author.handle, avatar: n.author.avatar.flatMap(URL.init(string:)),
                    date: f.date(from: n.indexedAt) ?? ISO8601DateFormatter().date(from: n.indexedAt) ?? Date(),
                    postID: targetPostID)
            }
        } catch {
            notifError = error.localizedDescription
        }
        notifLoading = false
    }

    // MARK: Lookup

    /// Current copy of a post, from whichever feed (or thread) holds it.
    func post(id: String) -> Post? {
        for s in states.values {
            if let p = s.posts.first(where: { $0.id == id }) { return p }
        }
        return nil
    }

    func parents(for post: Post) -> [Post] { states["parents:\(post.id)"]?.posts ?? [] }
    func replies(for post: Post) -> State { states["thread:\(post.id)"] ?? State() }

    /// Apply a change to every copy of a post (it can sit in several feeds at once).
    private func mutate(_ id: String, _ body: (inout Post) -> Void) {
        for (k, var s) in states {
            if let i = s.posts.firstIndex(where: { $0.id == id }) {
                body(&s.posts[i])
                states[k] = s
            }
        }
    }

    func loadThread(_ post: Post) async {
        let key = "thread:\(post.id)"
        let pKey = "parents:\(post.id)"
        var s = states[key] ?? State()
        s.loading = true
        states[key] = s
        do {
            let parents: [Post]
            let replies: [Post]
            if post.network == .bluesky {
                let res = try await bsky.threadWithParents(uri: post.id)
                parents = Self.unique(res.parents)
                replies = Self.unique(res.replies)
            } else {
                guard let url = post.url else { throw XError.badResponse }
                let res = try await xActions.thread(statusURL: url)
                parents = Self.unique(res.parents)
                replies = Self.unique(res.replies)
            }
            var ps = State()
            ps.posts = parents
            ps.loadedOnce = true
            states[pKey] = ps

            s.posts = replies
            s.error = nil
            registerQuotes(parents + replies)
        } catch {
            s.error = error.localizedDescription
        }
        s.loading = false
        s.loadedOnce = true
        states[key] = s
    }

    // MARK: Actions

    private func haptic() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

    func toggleLike(_ p: Post) async {
        let cur = post(id: p.id) ?? p
        let on = !cur.liked
        haptic()
        mutate(p.id) { $0.liked = on; $0.likeCount = max(0, $0.likeCount + (on ? 1 : -1)) }
        do {
            switch cur.network {
            case .bluesky:
                if on {
                    guard let cid = cur.cid else { throw BskyError.badResponse }
                    let rec = try await bsky.like(uri: cur.id, cid: cid)
                    mutate(p.id) { $0.likeRecord = rec }
                } else if let rec = post(id: p.id)?.likeRecord ?? cur.likeRecord {
                    try await bsky.unlike(recordURI: rec)
                    mutate(p.id) { $0.likeRecord = nil }
                }
            case .x:
                try await xActions.run(.like(on), statusURL: cur.url)
            }
        } catch {
            mutate(p.id) { $0.liked = !on; $0.likeCount = max(0, $0.likeCount + (on ? -1 : 1)) }
            toast = "Couldn't \(on ? "like" : "unlike"): \(error.localizedDescription)"
        }
    }

    func toggleRepost(_ p: Post) async {
        let cur = post(id: p.id) ?? p
        let on = !cur.reposted
        haptic()
        mutate(p.id) { $0.reposted = on; $0.repostCount = max(0, $0.repostCount + (on ? 1 : -1)) }
        do {
            switch cur.network {
            case .bluesky:
                if on {
                    guard let cid = cur.cid else { throw BskyError.badResponse }
                    let rec = try await bsky.repost(uri: cur.id, cid: cid)
                    mutate(p.id) { $0.repostRecord = rec }
                } else if let rec = post(id: p.id)?.repostRecord ?? cur.repostRecord {
                    try await bsky.unrepost(recordURI: rec)
                    mutate(p.id) { $0.repostRecord = nil }
                }
            case .x:
                try await xActions.run(.repost(on), statusURL: cur.url)
            }
        } catch {
            mutate(p.id) { $0.reposted = !on; $0.repostCount = max(0, $0.repostCount + (on ? -1 : 1)) }
            toast = "Couldn't \(on ? "repost" : "undo repost"): \(error.localizedDescription)"
        }
    }

    func reply(to p: Post, text: String) async throws {
        let cur = post(id: p.id) ?? p
        switch cur.network {
        case .bluesky:
            guard let cid = cur.cid else { throw BskyError.badResponse }
            try await bsky.reply(text: text,
                                 parent: (cur.id, cid),
                                 root: (cur.rootURI ?? cur.id, cur.rootCID ?? cid))
        case .x:
            try await xActions.run(.reply(text), statusURL: cur.url)
        }
        mutate(p.id) { $0.replyCount += 1 }
        await loadThread(cur)
    }

    func createPost(text: String, toX: Bool, toBluesky: Bool) async throws {
        var failures: [String] = []
        if toBluesky {
            do { try await bsky.createPost(text: text) }
            catch { failures.append("Bluesky: \(error.localizedDescription)") }
        }
        if toX {
            do { try await xActions.run(.post(text), statusURL: nil) }
            catch { failures.append("Twitter: \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw AppError(message: failures.joined(separator: "\n")) }
    }

    // MARK: Accounts

    func connectX(_ creds: XCredentials) {
        Secrets.save(creds, key: XSession.key)
        xConnected = true
        states = [:]
    }

    func disconnectX() async {
        Secrets.clear(key: XSession.key)
        xConnected = false
        states = [:]
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { $0.displayName.contains("x.com") || $0.displayName.contains("twitter.com") }
        await store.removeData(ofTypes: types, for: mine)
    }

    func loginBluesky(handle: String, password: String, config: FeedConfig) async throws {
        try await bsky.login(identifier: handle, password: password)
        bskyHandle = await bsky.handle
        states = [:]
        await fetchSavedFeeds(config)
    }

    func logoutBluesky() async {
        await bsky.logout()
        bskyHandle = nil
        states = [:]
    }

    func fetchSavedFeeds(_ config: FeedConfig) async {
        if let feeds = try? await bsky.savedFeeds() { config.extra = feeds }
    }
}
