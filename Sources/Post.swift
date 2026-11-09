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
    var videos: [PostVideo] = []
    var repostedBy: String? = nil
    var url: URL? = nil

    // Interaction state
    var liked: Bool = false
    var reposted: Bool = false

    // Bluesky-only bookkeeping
    var cid: String? = nil
    var likeRecord: String? = nil
    var repostRecord: String? = nil
    var rootURI: String? = nil
    var rootCID: String? = nil
}

struct PostVideo: Hashable, Identifiable {
    let url: URL
    let poster: URL?
    var gif = false
    var id: URL { url }
    /// Plain files can be saved to Photos; HLS playlists can't.
    var savable: Bool { url.pathExtension.lowercased() == "mp4" }
}
