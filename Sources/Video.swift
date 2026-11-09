import SwiftUI
import AVFoundation
import Combine

/// Global mute preference. Videos start muted; whatever you pick sticks across videos and launches.
final class VideoPrefs: ObservableObject {
    static let shared = VideoPrefs()
    @Published var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: "video.muted"); applySession() }
    }

    init() {
        muted = UserDefaults.standard.object(forKey: "video.muted") as? Bool ?? true
        applySession()
    }

    private func applySession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(muted ? .ambient : .playback)
        try? s.setActive(true)
    }
}

final class LoopingPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var ratio: CGFloat?
    private var bag = Set<AnyCancellable>()
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .none
        player.isMuted = VideoPrefs.shared.muted
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                if size.width > 0, size.height > 0 { self?.ratio = size.width / size.height }
            }
            .store(in: &bag)
        VideoPrefs.shared.$muted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.player.isMuted = m }
            .store(in: &bag)
    }

    deinit {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        player.pause()
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var fill = false

    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layer_: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> V {
        let v = V()
        v.layer_.player = player
        v.layer_.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: V, context: Context) { v.layer_.player = player }
}

struct MuteButton: View {
    @ObservedObject private var prefs = VideoPrefs.shared
    var body: some View {
        Button { prefs.muted.toggle() } label: {
            Image(systemName: prefs.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Autoplays (muted by default) and loops while on screen; tap opens the full-screen viewer.
struct InlineVideo: View {
    let video: PostVideo
    @State private var active = false
    @State private var viewing: PostVideo?

    var body: some View {
        ZStack {
            if active { Player(video: video, inline: true) }
            else if let p = video.poster { CachedImage(url: p, fill: true) }
            else { Color.gray.opacity(0.2) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { viewing = video }
        .onAppear { active = true }
        .onDisappear { active = false }
        .fullScreenCover(item: $viewing) { VideoViewer(video: $0) }
    }
}

/// Owns the player for one video; created when it appears, torn down when it leaves.
struct Player: View {
    let video: PostVideo
    var inline = false
    @StateObject private var lp: LoopingPlayer

    init(video: PostVideo, inline: Bool = false) {
        self.video = video
        self.inline = inline
        _lp = StateObject(wrappedValue: LoopingPlayer(url: video.url))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PlayerLayerView(player: lp.player)
            if !video.gif { MuteButton().padding(8) }
        }
        .onAppear { lp.player.play() }
        .onDisappear { lp.player.pause() }
    }
}

struct VideoViewer: View {
    let video: PostVideo
    @State private var dragY: CGFloat = 0
    @State private var confirmSave = false
    @State private var note: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(max(0.15, 1 - Double(abs(dragY)) / 350)).ignoresSafeArea()
            Player(video: video)
                .ignoresSafeArea()
                .offset(y: dragY)
                .gesture(
                    DragGesture()
                        .onChanged { dragY = $0.translation.height }
                        .onEnded { v in
                            if abs(v.translation.height) > 110 || abs(v.predictedEndTranslation.height) > 400 {
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragY = 0 }
                            }
                        }
                )
                .onLongPressGesture(minimumDuration: 0.45) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    confirmSave = true
                }
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
            }
        }
        .confirmationDialog("Video", isPresented: $confirmSave, titleVisibility: .hidden) {
            Button("Save to Photos") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() async {
        guard video.savable else { flash("Saving isn't supported for this video"); return }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: video.url)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try FileManager.default.moveItem(at: tmp, to: dest)
            let saver = PhotoSaver { ok in flash(ok ? "Saved to Photos" : "Couldn't save (allow Photos access)") }
            PhotoSaver.keep = saver
            UISaveVideoAtPathToSavedPhotosAlbum(dest.path, saver, #selector(PhotoSaver.videoDone(_:error:context:)), nil)
        } catch {
            flash("Couldn't download the video")
        }
    }

    private func flash(_ s: String) {
        withAnimation { note = s }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { note = nil } }
    }
}
