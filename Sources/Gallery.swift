import SwiftUI
import UIKit

/// Small shared image cache so thumbnails and the full-screen viewer don't re-download.
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 300 * 1024 * 1024
        return c
    }()
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// Downloads once even if many views ask, and decodes off the main thread so scrolling doesn't hitch.
    func load(_ url: URL) async -> UIImage? {
        if let c = cached(url) { return c }
        lock.lock()
        let task: Task<UIImage?, Never>
        if let t = inflight[url] {
            task = t
        } else {
            task = Task.detached(priority: .userInitiated) { [cache] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let raw = UIImage(data: data) else { return nil }
                let img = await raw.byPreparingForDisplay() ?? raw
                let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
                cache.setObject(img, forKey: url as NSURL, cost: cost)
                return img
            }
            inflight[url] = task
        }
        lock.unlock()
        let result = await task.value
        lock.lock(); inflight[url] = nil; lock.unlock()
        return result
    }

    /// Fetch a batch ahead of time, a few at a time.
    func prefetch(_ urls: [URL]) async {
        let todo = urls.filter { cached($0) == nil }
        await withTaskGroup(of: Void.self) { g in
            var it = todo.makeIterator()
            for _ in 0..<4 { if let u = it.next() { g.addTask { _ = await self.load(u) } } }
            while await g.next() != nil {
                if Task.isCancelled { g.cancelAll(); return }
                if let u = it.next() { g.addTask { _ = await self.load(u) } }
            }
        }
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

    init(url: URL, fill: Bool = false) {
        self.url = url
        self.fill = fill
        _image = State(initialValue: ImageLoader.shared.cached(url)) // no gray flash for cached images
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                    .transition(.opacity)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task(id: url) {
            if let c = ImageLoader.shared.cached(url) { image = c }
            if image == nil {
                let img = await ImageLoader.shared.load(url)
                withAnimation(.easeIn(duration: 0.15)) { image = img }
            }
        }
    }
}

struct GalleryItem: Identifiable { let id: Int }

struct GalleryView: View {
    let urls: [URL]
    @State var index: Int
    @State private var dragY: CGFloat = 0
    @State private var note: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(max(0.15, 1 - Double(abs(dragY)) / 350)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    ZoomableImage(
                        url: u,
                        onDrag: { dragY = $0 },
                        onDragEnd: { dy, vy in
                            if abs(dy) > 110 || abs(vy) > 900 {
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragY = 0 }
                            }
                        },
                        onSave: { Task { await save() } })
                    .tag(i).ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .offset(y: dragY)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .padding(16)
            .opacity(dragY == 0 ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            if let note {
                Text(note).font(.footnote).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
    }

    private func save() async {
        let u = urls[index]
        let img = await ImageLoader.shared.load(ImageLoader.fullSize(u)) ?? ImageLoader.shared.cached(u)
        guard let img else { flash("Couldn't load the image"); return }
        let saver = PhotoSaver { ok in flash(ok ? "Saved to Photos" : "Couldn't save (allow Photos access)") }
        PhotoSaver.keep = saver
        UIImageWriteToSavedPhotosAlbum(img, saver, #selector(PhotoSaver.done(_:error:context:)), nil)
    }

    private func flash(_ s: String) {
        withAnimation { note = s }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { note = nil } }
    }
}

final class PhotoSaver: NSObject {
    static var keep: PhotoSaver?
    let result: (Bool) -> Void
    init(_ r: @escaping (Bool) -> Void) { result = r }
    @objc func videoDone(_ path: String, error: NSError?, context: UnsafeRawPointer?) {
        DispatchQueue.main.async { self.result(error == nil); PhotoSaver.keep = nil }
    }
    @objc func done(_ image: UIImage, error: NSError?, context: UnsafeRawPointer?) {
        DispatchQueue.main.async { self.result(error == nil); PhotoSaver.keep = nil }
    }
}

/// Pinch and double-tap zoom, pan when zoomed. Shows the already-loaded thumbnail instantly,
/// then swaps in the full-size image.
struct ZoomableImage: UIViewRepresentable {
    let url: URL
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        context.coordinator.parent = self
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

        // Vertical pan to dismiss (only when not zoomed).
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        sv.addGestureRecognizer(pan)
        // Native long-press menu: appears at the finger, like Photos.
        iv.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))

        let thumb = ImageLoader.shared.cached(url)
        iv.image = thumb
        let full = ImageLoader.fullSize(url)
        Task { @MainActor in
            if let img = await ImageLoader.shared.load(full) { iv.image = img; context.coordinator.layout() }
        }
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) { context.coordinator.parent = self; context.coordinator.layout() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        var parent: ZoomableImage?
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func layout() {
            guard let sv = scroll, let iv = imageView, sv.bounds.width > 0, sv.zoomScale == 1 else { return }
            iv.frame = sv.bounds
            sv.contentSize = sv.bounds.size
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let sv = scroll else { return true }
            let v = pan.velocity(in: sv)
            return sv.zoomScale <= 1.01 && abs(v.y) > abs(v.x) * 1.2
        }

        func contextMenuInteraction(_ i: UIContextMenuInteraction, configurationForMenuAtLocation l: CGPoint) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [UIAction(title: "Save to Photos", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    self?.parent?.onSave()
                }])
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let sv = scroll else { return }
            switch g.state {
            case .changed: parent?.onDrag(g.translation(in: sv).y)
            case .ended, .cancelled, .failed:
                parent?.onDragEnd(g.translation(in: sv).y, g.velocity(in: sv).y)
            default: break
            }
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
