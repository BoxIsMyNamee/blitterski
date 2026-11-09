import SwiftUI
import UIKit

/// Small shared image cache so thumbnails and the full-screen viewer don't re-download.
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let c = cached(url) { return c }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }

    /// Full-size variant for X media (pbs.twimg.com serves ?name=large).
    static func fullSize(_ url: URL) -> URL {
        guard url.host == "pbs.twimg.com", url.query == nil,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = [URLQueryItem(name: "name", value: "large")]
        return c.url ?? url
    }
}

struct CachedImage: View {
    let url: URL
    var fill = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task(id: url) {
            image = ImageLoader.shared.cached(url)
            if image == nil { image = await ImageLoader.shared.load(url) }
        }
    }
}

struct GalleryItem: Identifiable { let id: Int }

struct GalleryView: View {
    let urls: [URL]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    ZoomableImage(url: u, onSingleTap: {}).tag(i).ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .padding(16)
        }
    }
}

/// Pinch and double-tap zoom, pan when zoomed. Shows the already-loaded thumbnail instantly,
/// then swaps in the full-size image.
struct ZoomableImage: UIViewRepresentable {
    let url: URL
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.bouncesZoom = true
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        sv.addSubview(iv)
        context.coordinator.imageView = iv
        context.coordinator.scroll = sv
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)

        let thumb = ImageLoader.shared.cached(url)
        iv.image = thumb
        let full = ImageLoader.fullSize(url)
        Task { @MainActor in
            if let img = await ImageLoader.shared.load(full) { iv.image = img; context.coordinator.layout() }
        }
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) { context.coordinator.layout() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func layout() {
            guard let sv = scroll, let iv = imageView, sv.bounds.width > 0, sv.zoomScale == 1 else { return }
            iv.frame = sv.bounds
            sv.contentSize = sv.bounds.size
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = scroll else { return }
            if sv.zoomScale > 1 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let w = sv.bounds.width / 2.5, h = sv.bounds.height / 2.5
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}
