import SwiftUI

@main
struct TwitterApp: App {
    @StateObject private var store = FeedStore()
    @StateObject private var config = FeedConfig()
    @StateObject private var theme = Theme()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(config)
                .environmentObject(theme)
                .tint(theme.accent)
                .task { await store.bootstrap() }
        }
    }
}

/// Floating Liquid Glass tab bar plus a feed switcher pill above it.
/// All tabs stay alive so Home keeps its scroll position.
struct RootView: View {
    @EnvironmentObject var store: FeedStore
    @StateObject private var nav = Nav()

    var body: some View {
        ZStack {
            page(0) { HomeView(openSettings: { nav.tab = 4 }) }
            page(1) { PlaceholderView(title: "Search") }
            page(2) { PlaceholderView(title: "Messages") }
            page(3) { PlaceholderView(title: "Notifications") }
            page(4) { SettingsView().safeAreaInset(edge: .bottom) { Color.clear.frame(height: 84) } }
        }
        .overlay(alignment: .bottom) { FloatingBars() }
        .environmentObject(nav)
        .sheet(isPresented: $nav.showCompose) { ComposeView() }
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glass(in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 8).padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: store.toast)
        .task(id: store.toast) {
            guard store.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            store.toast = nil
        }
    }

    private func page<V: View>(_ i: Int, @ViewBuilder _ v: () -> V) -> some View {
        v().opacity(nav.tab == i ? 1 : 0).allowsHitTesting(nav.tab == i)
    }
}

struct PlaceholderView: View {
    let title: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title2.bold())
            Text("Coming soon").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Home

struct PostRoute: Hashable {
    let postID: String
    let focusReply: Bool
}

struct HomeView: View {
    @EnvironmentObject var config: FeedConfig
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var nav: Nav
    let openSettings: () -> Void
    @State private var path: [PostRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                if config.shown.isEmpty {
                    Spacer()
                    Text("No feeds selected.\nChoose some in Settings > Choose feeds.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    // All pages stay alive (keeps scroll positions); only the selected one is visible.
                    ZStack {
                        ForEach(config.shown) { f in
                            FeedPage(feed: f, isActive: f.id == nav.feed, open: { path.append($0) })
                                .opacity(f.id == nav.feed ? 1 : 0)
                                .allowsHitTesting(f.id == nav.feed)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PostRoute.self) { PostDetailView(route: $0) }
        }
        .onAppear(perform: ensureSelection)
        .onChange(of: config.shown) { _ in ensureSelection() }
        .onChange(of: path) { p in nav.hideBars = !p.isEmpty }
    }

    private func ensureSelection() {
        if !config.shown.contains(where: { $0.id == nav.feed }) {
            nav.feed = config.shown.first?.id ?? ""
        }
    }

    private var header: some View {
        HStack {
            Button(action: openSettings) {
                Image(systemName: "line.3.horizontal").font(.title3).foregroundStyle(.primary)
            }
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2).foregroundStyle(theme.accent)
            Spacer()
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
}

struct FeedPage: View {
    let feed: FeedDef
    let isActive: Bool
    let open: (PostRoute) -> Void
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var theme: Theme

    var body: some View {
        let state = store.state(for: feed)
        ScrollView {
            LazyVStack(spacing: 0) {
                if let e = state.error {
                    Text(e).font(.footnote).foregroundStyle(.red).padding()
                }
                if state.posts.isEmpty && state.loading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                if state.posts.isEmpty && !state.loading && state.error == nil && state.loadedOnce {
                    Text("Nothing here yet. Connect your accounts in Settings (profile tab).")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
                ForEach(state.posts) { p in
                    row(p, lastID: state.posts.last?.id)
                }
                if state.loading && !state.posts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                Color.clear.frame(height: 150) // room under the floating bars
            }
        }
        .refreshable { await store.refresh(feed) }
        .task(id: isActive) {
            if isActive && !store.state(for: feed).loadedOnce { await store.refresh(feed) }
        }
    }

    private func row(_ p: Post, lastID: String?) -> some View {
        VStack(spacing: 0) {
            SwipeRow(liked: p.liked,
                     onLike: { Task { await store.toggleLike(p) } },
                     onReply: { open(PostRoute(postID: p.id, focusReply: true)) }) {
                PostRow(post: p,
                        onOpen: { open(PostRoute(postID: p.id, focusReply: false)) },
                        onReply: { open(PostRoute(postID: p.id, focusReply: true)) })
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
            }
            Divider()
        }
        .onAppear {
            if p.id == lastID { Task { await store.loadMore(feed) } }
        }
    }
}
