import Foundation

enum Network: String, Codable { case x, bluesky }

/// Network-agnostic post. Both X and Bluesky map into this so merged feeds are trivial.
struct Post: Identifiable, Hashable {
    let id: String
    let network: Network
    let authorHandle: String
    let authorName: String
    let avatarURL: URL?
    let text: String
    let createdAt: Date
    var replyCount: Int = 0
    var repostCount: Int = 0
    var likeCount: Int = 0
    var images: [URL] = []
    var repostedBy: String? = nil
    var url: URL? = nil
}
