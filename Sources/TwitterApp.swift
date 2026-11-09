import SwiftUI

extension Color {
    static let twitterBlue = Color(red: 29 / 255, green: 161 / 255, blue: 242 / 255)
}

@main
struct TwitterApp: App {
    @StateObject private var store = FeedStore()
    @StateObject private var config = FeedConfig()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(config)
                .tint(.twitterBlue)
                .task { await store.bootstrap() }
        }
    }
}

/// Bottom bar mirrors the Bluesky app: Home, Search, Messages, Notifications, Profile.
/// Only Home and Profile (settings) do anything yet.
struct RootView: View {
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

struct HomeView: View {
    @EnvironmentObject var config: FeedConfig
    let openSettings: () -> Void
    @State private var selected = ""
    @State private var showCompose = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if config.shown.isEmpty {
                Spacer()
                Text("No feeds selected.\nChoose some in Settings > Choose feeds.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
            } else {
                FeedTabBar(feeds: config.shown, selected: $selected)
                TabView(selection: $selected) {
                    ForEach(config.shown) { f in
                        FeedPage(feed: f, isActive: f.id == selected).tag(f.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { showCompose = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.twitterBlue, in: Circle())
                    .shadow(radius: 4, y: 2)
            }
            .padding(16)
        }
        .onAppear(perform: ensureSelection)
        .onChange(of: config.shown) { _ in ensureSelection() }
        .alert("Posting is coming soon", isPresented: $showCompose) {
            Button("OK", role: .cancel) {}
        }
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
                .font(.title2).foregroundStyle(Color.twitterBlue)
            Spacer()
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
}

struct FeedTabBar: View {
    let feeds: [FeedDef]
    @Binding var selected: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(feeds) { f in
                            let on = selected == f.id
                            Button {
                                withAnimation { selected = f.id }
                            } label: {
                                VStack(spacing: 6) {
                                    Text(f.title)
                                        .font(.subheadline.weight(on ? .bold : .regular))
                                        .foregroundStyle(on ? Color.primary : Color.secondary)
                                    Capsule().fill(on ? Color.twitterBlue : Color.clear).frame(height: 3)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(f.id)
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
}

struct FeedPage: View {
    let feed: FeedDef
    let isActive: Bool
    @EnvironmentObject var store: FeedStore

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
                PostRow(post: p)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    .onAppear {
                        if p.id == state.posts.last?.id { Task { await store.loadMore(feed) } }
                    }
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
}

// MARK: - Post row

struct PostRow: View {
    let post: Post

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: post.avatarURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.gray.opacity(0.25))
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                if let by = post.repostedBy {
                    Label("\(post.network == .x ? "Retweeted" : "Reposted") by \(by)",
                          systemImage: "arrow.2.squarepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(post.authorName).fontWeight(.bold).lineLimit(1)
                    Text("@\(post.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
                    Text("· \(shortAge(post.createdAt))").foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 0)
                    Text(post.network == .x ? "Twitter" : "Bluesky")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.twitterBlue.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.twitterBlue)
                }
                .font(.subheadline)

                if !post.text.isEmpty {
                    Text(linkified(post.text)).font(.body)
                }
                if !post.images.isEmpty {
                    ImageGrid(urls: post.images).padding(.top, 2)
                }
                actions.padding(.top, 4)
            }
        }
    }

    private var actions: some View {
        HStack {
            Label(compact(post.replyCount), systemImage: "bubble.left")
            Spacer()
            Label(compact(post.repostCount), systemImage: "arrow.2.squarepath")
            Spacer()
            Label(compact(post.likeCount), systemImage: "heart")
            Spacer()
            Image(systemName: "bookmark")
            Spacer()
            if let url = post.url {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
            Spacer()
            Image(systemName: "ellipsis")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }
}

struct ImageGrid: View {
    let urls: [URL]

    var body: some View {
        let shown = Array(urls.prefix(4))
        if shown.count == 1 {
            AsyncImage(url: shown[0]) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 220)
            }
            .frame(maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(shown, id: \.self) { u in
                    Color.clear
                        .frame(height: shown.count == 2 ? 220 : 130)
                        .overlay(
                            AsyncImage(url: u) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Color.gray.opacity(0.2)
                            }
                        )
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Formatting helpers

func shortAge(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    if s < 86_400 * 7 { return "\(s / 86_400)d" }
    return d.formatted(.dateTime.month(.abbreviated).day())
}

func compact(_ n: Int) -> String {
    if n <= 0 { return "" }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func linkified(_ s: String) -> AttributedString {
    let ms = NSMutableAttributedString(string: s)
    if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        for m in det.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            if let url = m.url { ms.addAttribute(.link, value: url, range: m.range) }
        }
    }
    return (try? AttributedString(ms)) ?? AttributedString(s)
}
