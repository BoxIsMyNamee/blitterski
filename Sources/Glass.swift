import SwiftUI

/// Real Liquid Glass on iOS 26 (needs the Xcode 26 SDK at build time), blurred material before that.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        #endif
    }
}

/// Shared UI state: selected feed, compose sheet, and whether the floating bars are visible.
@MainActor
final class Nav: ObservableObject {
    @Published var tab = 0
    @Published var feed = ""
    @Published var showCompose = false
    @Published var hideBars = false
    /// Extra scroll room needed under the custom floating bars (0 when the system tab bar is used).
    @Published var bottomInset: CGFloat = 150
}

struct FloatingBars: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var config: FeedConfig
    @EnvironmentObject var theme: Theme

    private let tabs: [(String, String)] = [
        ("house.fill", "Home"), ("magnifyingglass", "Search"),
        ("bubble.left.and.bubble.right.fill", "Messages"), ("bell.fill", "Alerts"),
        ("person.crop.circle.fill", "Me"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            if nav.tab == 0 && !config.shown.isEmpty { feedRow }
            tabBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .offset(y: nav.hideBars ? 200 : 0)
        .opacity(nav.hideBars ? 0 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: nav.hideBars)
    }

    private var feedRow: some View {
        HStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(config.shown) { f in
                            let on = nav.feed == f.id
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { nav.feed = f.id }
                            } label: {
                                Text(config.title(f))
                                    .font(.subheadline.weight(on ? .semibold : .regular))
                                    .foregroundStyle(on ? theme.accent : Color.primary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(on ? theme.accent.opacity(0.18) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(f.id)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: nav.feed) { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .glass(in: Capsule())
            .clipShape(Capsule())

            Button { nav.showCompose = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 48, height: 48)
                    .glass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                let on = nav.tab == i
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { nav.tab = i }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.0).font(.system(size: 19))
                        Text(t.1).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(on ? theme.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(on ? theme.accent.opacity(0.16) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glass(in: Capsule())
    }
}

// MARK: - Swipe row

/// Light-touch swipe: a short pull reveals the action and registers on release.
/// Right = like, left = reply. The pan only begins for mostly-horizontal drags, so
/// vertical scrolling is never blocked.
struct SwipeRow<Content: View>: View {
    let liked: Bool
    let onLike: () -> Void
    let onReply: () -> Void
    @ViewBuilder let content: () -> Content

    @EnvironmentObject var theme: Theme
    @State private var dx: CGFloat = 0
    @State private var armed = false

    private let trigger: CGFloat = 40

    var body: some View {
        content()
            .background(Color(.systemBackground))
            .offset(x: dx)
            .background(alignment: dx >= 0 ? .leading : .trailing) { reveal }
            .background(SwipeCatcher(onChange: change, onEnd: end))
    }

    private func change(_ t: CGFloat) {
        let a = abs(t)
        let eased = a <= trigger ? a : trigger + (a - trigger) * 0.35
        dx = t < 0 ? -eased : eased
        let now = a >= trigger
        if now != armed {
            armed = now
            if now { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    private func end() {
        let fire = armed
        let right = dx > 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dx = 0 }
        armed = false
        if fire { if right { onLike() } else { onReply() } }
    }

    private var reveal: some View {
        let right = dx >= 0
        let on = abs(dx) >= trigger
        return ZStack(alignment: right ? .leading : .trailing) {
            (right ? Color.pink : theme.accent).opacity(on ? 1 : 0.7)
            Image(systemName: right ? (liked ? "heart.slash.fill" : "heart.fill") : "bubble.left.fill")
                .foregroundStyle(.white)
                .font(.title3)
                .scaleEffect(on ? 1.15 : 0.8)
                .padding(.horizontal, 20)
        }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

/// Attaches a horizontal-only pan recognizer to the enclosing scroll view, scoped to this row's frame.
struct SwipeCatcher: UIViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.onWindow = { [weak c = context.coordinator, weak v] in if let c, let v { c.attach(to: v) } }
        return v
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    static func dismantleUIView(_ uiView: Probe, coordinator: Coordinator) { coordinator.detach() }

    final class Probe: UIView {
        var onWindow: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { onWindow?() } }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private weak var probe: UIView?
        private weak var host: UIView?
        private var pan: UIPanGestureRecognizer?

        func attach(to v: UIView) {
            probe = v
            guard pan == nil else { return }
            var cur: UIView? = v.superview
            while let c = cur, !(c is UIScrollView) { cur = c.superview }
            guard let scroll = cur else { return }
            let g = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            g.delegate = self
            g.cancelsTouchesInView = true
            scroll.addGestureRecognizer(g)
            pan = g; host = scroll
        }

        func detach() {
            if let g = pan { host?.removeGestureRecognizer(g) }
            pan = nil
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let probe else { return false }
            let p = pan.location(in: probe)
            guard probe.bounds.contains(p) else { return false }
            let vel = pan.velocity(in: probe)
            return abs(vel.x) > abs(vel.y) * 1.4
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let probe else { return }
            switch g.state {
            case .changed: onChange(g.translation(in: probe).x)
            case .ended, .cancelled, .failed: onEnd()
            default: break
            }
        }
    }
}
