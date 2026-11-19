import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var nav: Nav
    @State private var query = ""
    @State private var path: [PostRoute] = []

    var body: some View {
        let posts = store.states["search"]?.posts ?? []
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("search-top")
                        if let e = store.searchError {
                            Text(e).font(.footnote).foregroundStyle(.red).padding()
                        }
                        if store.searching { ProgressView().padding() }
                        if posts.isEmpty && !store.searching && store.searchError == nil {
                            Text("Search Bluesky posts").foregroundStyle(.secondary).padding(.top, 60)
                        }
                        ForEach(posts) { p in
                            SwipeRow(liked: p.liked,
                                     onLike: { Task { await store.toggleLike(p) } },
                                     onReply: { path.append(PostRoute(postID: p.id, focusReply: true)) }) {
                                PostRow(post: p,
                                        onOpen: { path.append(PostRoute(postID: p.id, focusReply: false)) },
                                        onReply: { path.append(PostRoute(postID: p.id, focusReply: true)) })
                                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
                            }
                            Divider()
                        }
                        Color.clear.frame(height: nav.bottomInset)
                    }
                }
                .onChange(of: nav.scrollToTop) { _ in
                    guard nav.tab == 1 else { return }
                    if !path.isEmpty {
                        path.removeAll()
                    } else {
                        withAnimation { proxy.scrollTo("search-top", anchor: .top) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search Bluesky")
            .onSubmit(of: .search) { Task { await store.search(query) } }
            .navigationDestination(for: PostRoute.self) { PostDetailView(route: $0).toolbar(.hidden, for: .tabBar) }
        }
        .environment(\.openPost, { path.append($0) })
        .environment(\.mediaActive, nav.tab == 1 && !nav.hideBars)
        .task(id: posts.count) {
            let urls = posts.prefix(40).flatMap { p in
                [p.avatarURL].compactMap { $0 } + p.images + p.videos.compactMap(\.poster)
            }
            await ImageLoader.shared.prefetch(urls)
        }
        .onChange(of: path) { p in if nav.tab == 1 { nav.hideBars = !p.isEmpty } }
        .onChange(of: nav.tab) { t in if t == 1 { nav.hideBars = !path.isEmpty } }
    }
}

struct NotificationsView: View {
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var nav: Nav
    @State private var path: [PostRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = store.notifError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(e).font(.footnote).foregroundStyle(.red)
                        Button("Try again") { Task { await store.loadNotifications() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                if store.notifs.isEmpty && store.notifLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .padding()
                }
                if store.notifs.isEmpty && !store.notifLoading && store.notifError == nil {
                    Text("No notifications yet.").foregroundStyle(.secondary)
                }
                ForEach(store.notifs) { n in
                    Button {
                        if let id = n.postID, store.post(id: id) != nil {
                            path.append(PostRoute(postID: id, focusReply: false))
                        }
                    } label: { row(n) }
                    .buttonStyle(.plain)
                }
                Color.clear.frame(height: nav.bottomInset).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await store.loadNotifications() }
            .task { await store.loadNotifications() }
            .task(id: store.notifs.count) {
                let urls = store.notifs.prefix(40).compactMap(\.avatar)
                await ImageLoader.shared.prefetch(urls)
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PostRoute.self) { PostDetailView(route: $0).toolbar(.hidden, for: .tabBar) }
        }
        .environment(\.openPost, { path.append($0) })
        .onChange(of: path) { p in if nav.tab == 3 { nav.hideBars = !p.isEmpty } }
        .onChange(of: nav.tab) { t in if t == 3 { nav.hideBars = !path.isEmpty } }
        .onChange(of: nav.scrollToTop) { _ in
            if nav.tab == 3 && !path.isEmpty { path.removeAll() }
        }
    }

    private func row(_ n: NotifItem) -> some View {
        let (icon, color, verb): (String, Color, String) = {
            switch n.reason {
            case "like": return ("heart.fill", .pink, "liked your post")
            case "repost": return ("arrow.2.squarepath", .green, "reposted your post")
            case "follow": return ("person.fill.badge.plus", .blue, "followed you")
            case "reply": return ("bubble.left.fill", .blue, "replied to you")
            case "mention": return ("at", .orange, "mentioned you")
            case "quote": return ("quote.opening", .purple, "quoted your post")
            default: return ("bell.fill", .gray, n.reason)
            }
        }()
        return HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            Avatar(url: n.avatar, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n.name) \(verb)").font(.subheadline).lineLimit(2)
                if let id = n.postID, let p = store.post(id: id), !p.text.isEmpty {
                    Text(p.text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(shortAge(n.date)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
