import Foundation

enum Network: String, Codable { case x, bluesky }

/// Network-agnostic post. Both X and Bluesky map into this so merged feeds are trivial.
struct Post: Identifiable, Hashable, Codable {
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
    var quote: QuotedPost? = nil
    var imageRatio: CGFloat? = nil   // width/height of the first image, to reserve space before it loads
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

struct QuotedPost: Hashable, Codable {
    let name: String
    let handle: String
    let avatar: URL?
    let text: String
    var id: String = ""
    var network: Network = .x
    var date: Date = Date()
    var images: [URL] = []
    var url: URL? = nil
    var cid: String? = nil

    /// A full post so the quoted one can be opened, liked and replied to like any other.
    var asPost: Post {
        Post(id: id, network: network, authorHandle: handle, authorName: name, avatarURL: avatar,
             text: text, createdAt: date, images: images, url: url, cid: cid, rootURI: id, rootCID: cid)
    }
}

struct PostVideo: Hashable, Identifiable, Codable {
    let url: URL
    let poster: URL?
    var gif = false
    var id: URL { url }
    /// Plain files can be saved to Photos; HLS playlists can't.
    var savable: Bool { url.pathExtension.lowercased() == "mp4" }
}
