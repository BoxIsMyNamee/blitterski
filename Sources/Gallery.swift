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
    @State private var dragY: CGFloat = 0
    @State private var confirmSave = false
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
                        onLongPress: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            confirmSave = true
                        })
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
        .confirmationDialog("Photo", isPresented: $confirmSave, titleVisibility: .hidden) {
            Button("Save to Photos") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
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
    var onLongPress: () -> Void = {}

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
        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        lp.minimumPressDuration = 0.45
        sv.addGestureRecognizer(lp)

        let thumb = ImageLoader.shared.cached(url)
        iv.image = thumb
        let full = ImageLoader.fullSize(url)
        Task { @MainActor in
            if let img = await ImageLoader.shared.load(full) { iv.image = img; context.coordinator.layout() }
        }
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) { context.coordinator.parent = self; context.coordinator.layout() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
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

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            a is UILongPressGestureRecognizer || b is UILongPressGestureRecognizer
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

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { parent?.onLongPress() }
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
