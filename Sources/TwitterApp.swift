import SwiftUI

extension Color {
    static let twitterBlue = Color(red: 29 / 255, green: 161 / 255, blue: 242 / 255)
}

@main
struct TwitterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().tint(.twitterBlue)
        }
    }
}

struct ContentView: View {
    @State private var creds = XKeychain.load()
    @State private var posts: [Post] = []
    @State private var status: String?
    @AppStorage("transport") private var transportMode = "webview"
    @StateObject private var transport = XWebViewTransport()

    var body: some View {
        NavigationStack {
            Group {
                if creds == nil {
                    XLoginView { c in
                        try? XKeychain.save(c)
                        creds = c
                    }
                    .navigationTitle("Sign in")
                    .navigationBarTitleDisplayMode(.inline)
                } else {
                    timeline
                        .navigationTitle("Home")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { menu }
                        .onAppear { if posts.isEmpty { refresh() } }
                }
            }
        }
    }

    private var timeline: some View {
        ZStack {
            List {
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(posts) { TweetRow(post: $0) }
            }
            .listStyle(.plain)
            .refreshable { await refreshAsync() }
            HiddenWebView(transport: transport).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Transport", selection: $transportMode) {
                    Text("Webview (recommended)").tag("webview")
                    Text("Direct").tag("direct")
                }
                Button("Refresh") { refresh() }
                Button("Log out", role: .destructive) {
                    XKeychain.clear(); creds = nil; posts = []
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func refresh() { Task { await refreshAsync() } }

    private func refreshAsync() async {
        guard let creds else { return }
        status = "Loading..."
        if transportMode == "direct" {
            do {
                let r = try await XClient(creds: creds).fetchHome(cursor: nil)
                posts = r.posts
                status = r.posts.isEmpty ? "No tweets returned" : nil
            } catch {
                status = "Direct failed: \(error.localizedDescription)"
            }
        } else {
            transport.onTimeline = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r): posts = r.posts; status = r.posts.isEmpty ? "No tweets returned" : nil
                    case .failure(let e): status = "Parse failed: \(e.localizedDescription)"
                    }
                }
            }
            transport.refresh()
        }
    }
}

struct TweetRow: View {
    let post: Post

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: post.avatarURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.gray.opacity(0.25))
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                if let by = post.repostedBy {
                    Label("\(by) Retweeted", systemImage: "arrow.2.squarepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(post.authorName).bold().lineLimit(1)
                    Text("@\(post.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
                    Text("· \(Self.relative(post.createdAt))").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                Text(post.text).font(.body)
                HStack(spacing: 36) {
                    Image(systemName: "bubble.left")
                    Label("\(post.repostCount)", systemImage: "arrow.2.squarepath")
                    Label("\(post.likeCount)", systemImage: "heart")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
