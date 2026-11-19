import SwiftUI

struct PostDetailView: View {
    let route: PostRoute
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var theme: Theme
    @Environment(\.openPost) private var openPost
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let post = store.post(id: route.postID) {
                content(post)
            } else {
                Text("Post unavailable").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ post: Post) -> some View {
        let parents = store.parents(for: post)
        let replies = store.replies(for: post)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !parents.isEmpty {
                    ForEach(parents) { p in
                        SwipeRow(liked: p.liked,
                                 onLike: { Task { await store.toggleLike(p) } },
                                 onReply: { openPost(PostRoute(postID: p.id, focusReply: true)) }) {
                            VStack(alignment: .leading, spacing: 0) {
                                PostRow(post: p,
                                        onOpen: { openPost(PostRoute(postID: p.id, focusReply: false)) },
                                        onReply: { openPost(PostRoute(postID: p.id, focusReply: true)) })
                                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 4, trailing: 14))
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.35))
                                        .frame(width: 2, height: 18)
                                        .padding(.leading, 14 + 21)
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    authorRow(post)
                    if !post.text.isEmpty {
                        Text(linkified(post.text))
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !post.images.isEmpty { ImageGrid(urls: post.images, ratio: post.imageRatio) }
                    ForEach(post.videos) { InlineVideo(video: $0) }
                    if let q = post.quote { QuoteCard(quote: q) }
                    Text(post.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(.secondary)

                    Divider()
                    counts(post)
                    Divider()
                    PostActions(post: post, onReply: { focused = true })
                    Divider()

                    composer(post)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }

                    Divider()
                    if replies.loading && replies.posts.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                    } else if let e = replies.error, replies.posts.isEmpty {
                        VStack(spacing: 8) {
                            Text(e).font(.footnote).foregroundStyle(.red)
                            Button("Try again") { Task { await store.loadThread(post) } }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else if replies.loadedOnce && replies.posts.isEmpty {
                        Text("No replies yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(14)

                ForEach(replies.posts) { r in
                    SwipeRow(liked: r.liked,
                             onLike: { Task { await store.toggleLike(r) } },
                             onReply: { openPost(PostRoute(postID: r.id, focusReply: true)) }) {
                        PostRow(post: r,
                                onOpen: { openPost(PostRoute(postID: r.id, focusReply: false)) },
                                onReply: { openPost(PostRoute(postID: r.id, focusReply: true)) })
                            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                    }
                    Divider()
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.loadThread(post) }
        .task(id: post.id) { await store.loadThread(post) }
        .task(id: parents.count + replies.posts.count) {
            let all = parents + replies.posts
            let urls = all.prefix(40).flatMap { p in
                [p.avatarURL].compactMap { $0 } + p.images + p.videos.compactMap(\.poster)
            }
            await ImageLoader.shared.prefetch(urls)
        }
        .onAppear {
            if route.focusReply {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
            }
        }
    }

    private func authorRow(_ post: Post) -> some View {
        HStack(spacing: 10) {
            Avatar(url: post.avatarURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.authorName).font(.headline).lineLimit(1)
                Text("@\(post.authorHandle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            NetworkBadge(network: post.network)
        }
    }

    private func counts(_ post: Post) -> some View {
        HStack(spacing: 16) {
            countLabel(post.replyCount, "replies")
            countLabel(post.repostCount, "reposts")
            countLabel(post.likeCount, "likes")
        }
        .font(.subheadline)
    }

    private func countLabel(_ n: Int, _ word: String) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").fontWeight(.bold)
            Text(word).foregroundStyle(.secondary)
        }
    }

    private func composer(_ post: Post) -> some View {
        let limit = post.network == .x ? 280 : 300
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Reply to @\(post.authorHandle)", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(10)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    send(post)
                } label: {
                    if sending { ProgressView() } else { Text("Reply").fontWeight(.semibold) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || trimmed.isEmpty || text.count > limit)
            }
            if !text.isEmpty {
                Text("\(text.count)/\(limit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(text.count > limit ? Color.red : Color.secondary)
            }
        }
    }

    private func send(_ post: Post) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            sending = true
            error = nil
            do {
                try await store.reply(to: post, text: body)
                text = ""
                focused = false
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
