import SwiftUI

struct PostDetailView: View {
    let route: PostRoute
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var theme: Theme
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
        let replies = store.replies(for: post)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                authorRow(post)
                if !post.text.isEmpty {
                    Text(linkified(post.text))
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !post.images.isEmpty { ImageGrid(urls: post.images) }
                ForEach(post.videos) { InlineVideo(video: $0) }
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
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    if let e = replies.error {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    } else if replies.loadedOnce && replies.posts.isEmpty {
                        Text("No replies yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(replies.posts) { r in
                        PostRow(post: r)
                        Divider()
                    }
                }
            }
            .padding(14)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: post.id) { await store.loadThread(post) }
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
            .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
