import SwiftUI

// MARK: - Post row

struct PostRow: View {
    let post: Post
    var onOpen: () -> Void = {}
    var onReply: () -> Void = {}
    @EnvironmentObject var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let by = post.repostedBy {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.2.squarepath").frame(width: 44, alignment: .trailing)
                    Text("\(post.network == .x ? "Retweeted" : "Reposted") by \(by)").lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                Avatar(url: post.avatarURL, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    header
                    if !post.text.isEmpty {
                        Text(linkified(post.text))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !post.images.isEmpty {
                        ImageGrid(urls: post.images, ratio: post.imageRatio).padding(.top, 2)
                    }
                    ForEach(post.videos) { InlineVideo(video: $0).padding(.top, 2) }
                    PostActions(post: post, onReply: onReply).padding(.top, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(post.authorName).fontWeight(.bold).lineLimit(1).layoutPriority(1)
            Text("@\(post.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
            Text("· \(shortAge(post.createdAt))").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            NetworkBadge(network: post.network)
        }
        .font(.subheadline)
    }
}

struct Avatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url { CachedImage(url: url, fill: true) } else { Color.gray.opacity(0.25) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct NetworkBadge: View {
    let network: Network
    @EnvironmentObject var theme: Theme

    var body: some View {
        Text(network == .x ? "Twitter" : "Bluesky")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(theme.accent)
            .fixedSize()
    }
}

// MARK: - Actions

/// Reply / repost / like / share / more. Equal-width columns so rows line up.
struct PostActions: View {
    let post: Post
    var onReply: () -> Void = {}
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onReply) {
                ActionLabel(icon: "bubble.left", count: post.replyCount, active: false, color: theme.accent)
            }
            .tint(Color.secondary)
            .column()

            Menu {
                Button {
                    Task { await store.toggleRepost(post) }
                } label: {
                    Label(post.reposted ? "Undo repost" : "Repost", systemImage: "arrow.2.squarepath")
                }
            } label: {
                ActionLabel(icon: "arrow.2.squarepath", count: post.repostCount, active: post.reposted, color: .green)
            }
            .tint(post.reposted ? Color.green : Color.secondary)
            .column()

            Button {
                Task { await store.toggleLike(post) }
            } label: {
                ActionLabel(icon: post.liked ? "heart.fill" : "heart", count: post.likeCount,
                            active: post.liked, color: .pink)
            }
            .tint(post.liked ? Color.pink : Color.secondary)
            .column()

            Group {
                if let url = post.url {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 20) }
                } else {
                    Color.clear.frame(width: 20, height: 1)
                }
            }
            .tint(Color.secondary)
            .column()

            Menu {
                Button { UIPasteboard.general.string = post.text } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
                if let url = post.url {
                    Button { UIPasteboard.general.url = url } label: {
                        Label("Copy link", systemImage: "link")
                    }
                    Link(destination: url) { Label("Open original", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20)
            }
            .tint(Color.secondary)
            .column()
        }
        .font(.footnote)
        .buttonStyle(.borderless)
    }
}

private struct ActionLabel: View {
    let icon: String
    let count: Int
    let active: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).frame(width: 20)
            Text(compact(count)).monospacedDigit()
        }
        .foregroundStyle(active ? color : Color.secondary)
    }
}

private extension View {
    func column() -> some View { frame(maxWidth: .infinity, alignment: .leading) }
}

// MARK: - Images

struct ImageGrid: View {
    let urls: [URL]
    var ratio: CGFloat? = nil
    @State private var viewer: GalleryItem?

    var body: some View {
        let shown = Array(urls.prefix(4))
        Group {
            if shown.count == 1 {
                Color.clear
                    .aspectRatio(ratio ?? 4 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .overlay(CachedImage(url: shown[0], fill: true))
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { viewer = GalleryItem(id: 0) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, u in
                        Color.clear
                            .frame(height: shown.count == 2 ? 220 : 130)
                            .overlay(CachedImage(url: u, fill: true))
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { viewer = GalleryItem(id: i) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .fullScreenCover(item: $viewer) { GalleryView(urls: urls, index: $0.id) }
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
