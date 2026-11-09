import Foundation

enum Network: String { case x, bluesky }

/// Network-agnostic post. Both X and Bluesky sources map into this so the merged feed is trivial.
struct Post: Identifiable, Hashable {
    let id: String
    let network: Network
    let authorHandle: String
    let authorName: String
    let avatarURL: URL?
    let text: String
    let createdAt: Date
    let likeCount: Int
    let repostCount: Int
    var repostedBy: String? = nil
}

/// Each network implements this. Keeps X's breakage isolated from Bluesky.
protocol FeedSource {
    func fetchHome(cursor: String?) async throws -> (posts: [Post], nextCursor: String?)
}
