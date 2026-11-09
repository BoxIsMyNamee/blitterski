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

/// Bottom bar mirrors the Bluesky app: Home, Search, Messages, Notifications, Profile.
/// Only Home and Profile (settings) do anything yet.
struct RootView: View {
    @EnvironmentObject var store: FeedStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView(openSettings: { tab = 4 })
                .tabItem { Image(systemName: "house.fill") }.tag(0)
            PlaceholderView(title: "Search")
                .tabItem { Image(systemName: "magnifyingglass") }.tag(1)
            PlaceholderView(title: "Messages")
                .tabItem { Image(systemName: "bubble.left.and.bubble.right") }.tag(2)
            PlaceholderView(title: "Notifications")
                .tabItem { Image(systemName: "bell") }.tag(3)
            SettingsView()
                .tabItem { Image(systemName: "person.crop.circle") }.tag(4)
        }
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
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
    let openSettings: () -> Void
    @State private var selected = ""
    @State private var showCompose = false
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
                    FeedTabBar(feeds: config.shown, selected: $selected)
                    // All pages stay alive (keeps scroll positions); only the selected one is visible.
                    // No paging gesture, so row swipe actions don't fight it.
                    ZStack {
                        ForEach(config.shown) { f in
                            FeedPage(feed: f, isActive: f.id == selected, open: { path.append($0) })
                                .opacity(f.id == selected ? 1 : 0)
                                .allowsHitTesting(f.id == selected)
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) { fab }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PostRoute.self) { PostDetailView(route: $0) }
        }
        .sheet(isPresented: $showCompose) { ComposeView() }
        .onAppear(perform: ensureSelection)
        .onChange(of: config.shown) { _ in ensureSelection() }
    }

    private var fab: some View {
        Button { showCompose = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.title2).foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(theme.accent, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .padding(16)
    }

    private func ensureSelection() {
        if !config.shown.contains(where: { $0.id == selected }) {
            selected = config.shown.first?.id ?? ""
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

struct FeedTabBar: View {
    let feeds: [FeedDef]
    @Binding var selected: String
    @EnvironmentObject var theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(feeds) { f in
                            tab(f)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: selected) { id in
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Divider()
        }
        .padding(.top, 4)
    }

    private func tab(_ f: FeedDef) -> some View {
        let on = selected == f.id
        return Button {
            withAnimation { selected = f.id }
        } label: {
            VStack(spacing: 6) {
                Text(f.title)
                    .font(.subheadline.weight(on ? .bold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                Capsule().fill(on ? theme.accent : Color.clear).frame(height: 3)
            }
        }
        .buttonStyle(.plain)
        .id(f.id)
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
        List {
            if let e = state.error {
                Text(e).font(.footnote).foregroundStyle(.red).listRowSeparator(.hidden)
            }
            if state.posts.isEmpty && state.loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if state.posts.isEmpty && !state.loading && state.error == nil && state.loadedOnce {
                Text("Nothing here yet. Connect your accounts in Settings (profile tab).")
                    .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            ForEach(state.posts) { p in
                row(p, lastID: state.posts.last?.id)
            }
            if state.loading && !state.posts.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh(feed) }
        .task(id: isActive) {
            if isActive && !store.state(for: feed).loadedOnce { await store.refresh(feed) }
        }
    }

    private func row(_ p: Post, lastID: String?) -> some View {
        PostRow(post: p,
                onOpen: { open(PostRoute(postID: p.id, focusReply: false)) },
                onReply: { open(PostRoute(postID: p.id, focusReply: true)) })
            .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
            // Swipe right: like. Swipe left: open the post ready to reply.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await store.toggleLike(p) }
                } label: {
                    Label(p.liked ? "Unlike" : "Like", systemImage: p.liked ? "heart.slash.fill" : "heart.fill")
                }
                .tint(.pink)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    open(PostRoute(postID: p.id, focusReply: true))
                } label: {
                    Label("Reply", systemImage: "bubble.left.fill")
                }
                .tint(theme.accent)
            }
            .onAppear {
                if p.id == lastID { Task { await store.loadMore(feed) } }
            }
    }
}
