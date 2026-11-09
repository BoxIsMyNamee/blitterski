import Foundation
import WebKit

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

    init() {
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
    }

    @Published private(set) var states: [String: State] = [:]
    @Published var xConnected: Bool
    @Published var bskyHandle: String? = nil

    let x = XWebSource()
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
        update(feed) { $0.loading = true; $0.error = nil }
        do {
            let r = try await fetchPage(feed, more: false, cursor: nil)
            update(feed) {
                $0.posts = Self.order(r.posts, feed)
                $0.bskyCursor = r.cursor
                $0.canLoadMore = true
                $0.loadedOnce = true
            }
        } catch {
            update(feed) { $0.error = error.localizedDescription; $0.loadedOnce = true }
        }
        update(feed) { $0.loading = false }
    }

    func loadMore(_ feed: FeedDef) async {
        let s = state(for: feed)
        guard !s.loading, s.canLoadMore, s.loadedOnce, !s.posts.isEmpty else { return }
        update(feed) { $0.loading = true }
        do {
            let r = try await fetchPage(feed, more: true, cursor: s.bskyCursor)
            update(feed) { st in
                let known = Set(st.posts.map(\.id))
                let fresh = r.posts.filter { !known.contains($0.id) }
                st.posts = Self.order(st.posts + fresh, feed)
                st.bskyCursor = r.cursor
                if fresh.isEmpty && r.cursor == nil { st.canLoadMore = false }
            }
        } catch {
            update(feed) { $0.canLoadMore = false }
        }
        update(feed) { $0.loading = false }
    }

    private static func order(_ posts: [Post], _ feed: FeedDef) -> [Post] {
        feed.kind == .combined ? posts.sorted { $0.createdAt > $1.createdAt } : posts
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
            async let xr = fetchOptionalX(.following, more: more)
            async let br = fetchOptionalBsky(cursor: cursor)
            let (xp, xerr) = await xr
            let (bres, berr) = await br
            if xp.isEmpty && bres.posts.isEmpty, let e = xerr ?? berr { throw e }
            return (xp + bres.posts, bres.cursor)
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
