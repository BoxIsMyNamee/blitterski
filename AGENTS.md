# AGENTS.md — Blitterski ("Twitter")

Briefing for any coding agent working on this repo. Read it fully before changing code.

## What this is

A personal iOS app (iPhone, iOS 16+, SwiftUI) that merges **Twitter/X** and **Bluesky** into one client. It is themed as **Twitter, never "X"** (display name "Twitter", the UI says "Twitter"). The layout copies the **Bluesky app**: bottom tabs (Home, Search, Messages, Alerts, Me), swipeable feed tabs on Home, post rows with avatar column, a compose button.

The owner (Harper) sideloads an **unsigned IPA** (LiveContainer / SideStore / Feather style). There is no App Store, no Apple developer account, no server. Everything runs **on-device**, same philosophy as the sibling project `BoxIsMyNamee/aotybox`.

- Repo: `BoxIsMyNamee/blitterski`, branch `main`.
- Every push to `main` builds on GitHub Actions and publishes a release. Latest IPA: `https://github.com/BoxIsMyNamee/blitterski/releases/latest/download/Twitter.ipa`
- Sideloader source: `source.json` in the repo root (AltStore-style).

## Environment realities (important)

- **You probably cannot compile Swift locally** (Linux sandbox). The only compile check is the Actions build. Push, wait ~2 minutes, check the run. Compile errors surface as `::error::` annotations. You can poll `https://api.github.com/repos/BoxIsMyNamee/blitterski/actions/runs?per_page=1`.
- **You cannot reach x.com** from a sandbox, so X behaviour (GraphQL shapes, DOM selectors) is **untested by you**. Treat all X parsing/DOM code as best-effort and write it defensively (optional chaining, no force unwraps, never throw away a whole feed over one bad entry).
- You cannot run the app. Be conservative: small, compile-safe changes. Swift is strict about type-checking inside big expressions and `ViewBuilder` closures — keep them simple.
- Builds use `macos-26` with the Xcode 26 SDK so Liquid Glass APIs compile. Anything iOS 26+ must be guarded with `#if compiler(>=6.2)` **and** `#available(iOS 26…)` with a fallback (see `Glass.swift`, `NativeRoot` in `TwitterApp.swift`).
- Commit messages: end with the attribution trailers the harness asks for. Fetch before pushing (`git fetch origin main`).

## Build system

- **XcodeGen**: `project.yml` generates the Xcode project in CI (`brew install xcodegen`). Do not commit an `.xcodeproj`. New source files in `Sources/` are picked up automatically. Info.plist keys go in `project.yml` under `info.properties` (e.g. `NSPhotoLibraryAddUsageDescription`).
- Target `TwitterApp`, product name `Twitter`, bundle id `com.boxismynamee.twitterclient`.
- `.github/workflows/build.yml`: `xcodebuild` unsigned (`CODE_SIGNING_ALLOWED=NO`) → zips `Payload/Twitter.app` into `Twitter.ipa` → release tag `build-N`.
- App icon: `Resources/Assets.xcassets/AppIcon.appiconset/icon.png` (original artwork, a blue speech bubble).

## Architecture

Model: `Post` (Sources/Post.swift) is the network-agnostic post (`Network` = `.x` / `.bluesky`). Both clients map into it so feeds can merge. Also `PostVideo`, `QuotedPost`. `Post` is `Codable` (used for the on-disk feed cache). **Memberwise-init argument order matters** — new properties go in declaration order and callers pass labels in that order.

### X / Twitter (no API key, no official API)

Uses X's private web GraphQL by driving the real x.com in **hidden WKWebViews**, riding the user's own login. Never reimplement request signing; let X's own JS make the requests.

- `XAuth.swift`: login webview (`https://x.com/i/flow/login`), polls cookies for `auth_token` + `ct0`, shared default `WKWebsiteDataStore`, shared desktop Safari UA (`xUserAgent`).
- `XWebSource.swift`: loads `x.com/home` offscreen (attached to the key window at x=-2000 so iOS doesn't throttle it). A JS hook wraps `fetch`/`XMLHttpRequest` and posts `HomeTimeline` (For You) / `HomeLatestTimeline` (Following) responses to a `WKScriptMessageHandler`. Clicks the right tab, scrolls to load more, retries nudges, 25–28s timeout. One fetch at a time (`AsyncLock`).
- `XTimelineParser.swift`: JSON → `[Post]`. Only `tweet-*` entries. Handles retweets (shows the original, sets `repostedBy`), note tweets, t.co expansion, media (images, video/gif variants → highest-bitrate mp4), quoted tweets, image aspect ratio. Also `parseDetail` for TweetDetail replies.
- `XActions.swift`: write actions (like, retweet, reply, post) by loading the status page in a second hidden webview and clicking real buttons via `data-testid` selectors (`like`, `unlike`, `retweet`, `unretweet`, `retweetConfirm`, `reply`, `tweetTextarea_0`, `tweetButton`). Also captures `TweetDetail` to load replies.
- Known fragility: X changes markup/GraphQL shape. When something breaks, fix selectors/parsing, keep failures non-fatal and visible (toast / error line).

### Bluesky

`BlueskyClient.swift` (an `actor`): AT Protocol over `https://bsky.social/xrpc` with an **app password** login (stored via `Secrets`). Session refresh on `ExpiredToken`. Timeline, custom feeds (`getFeed`, saved feeds via preferences), thread/replies, like/unlike/repost/unrepost/post/reply, search (`searchPosts`), notifications (`listNotifications` + `getPosts`). Wire types are tolerant on purpose (a bad embed must never break a whole feed decode — see `BskyRecordView`).

### App state

- `Feeds.swift`: `FeedDef` (kinds: combined, xForYou, xFollowing, bskyTimeline, bskyGenerator), `FeedConfig` (which feeds show as tabs, order, in-app **renames**, and which sources make up **Combined**; persisted in UserDefaults), `FeedStore` (all loading: refresh, loadMore, per-feed `State`, on-disk cache of last refresh, de-duplication by post id, optimistic like/repost with revert + toast, thread loading, notifications, search).
- **Combined feed**: user-chosen sources; Twitter and Bluesky posts alternate 1:1, Bluesky is shuffled each load so refresh feels fresh; per-source Bluesky cursors are encoded as a JSON dict in the single cursor string.
- `Secrets.swift`: Keychain with UserDefaults fallback (sideload containers often break the keychain).

### UI

- `TwitterApp.swift`: `@main`, `RootView`, `HomeView` (NavigationStack), `FeedPage` (ScrollView + LazyVStack), prefetching, retry button, refresh-on-foreground. iOS 26.1+ uses the system `TabView` + `tabViewBottomAccessory` (feed switcher pill + compose button) for real Liquid Glass; older iOS uses custom floating bars from `Glass.swift` (`FloatingBars`). Both paths must keep working.
- `Glass.swift`: `.glass(in:)` helper, `Nav` (shared selected tab/feed/compose/hide-bars/bottom inset), and **`SwipeRow`**: light-touch swipe (≈40pt) — right = like, left = reply — implemented with a UIKit pan recognizer attached to the enclosing scroll view that only begins for mostly-horizontal drags (SwiftUI `DragGesture` broke vertical scrolling earlier; don't go back to it).
- `PostViews.swift`: `PostRow`, `Avatar`, `PostActions`, `ImageGrid` (reserves space from known aspect ratio), `QuoteCard` (tappable → opens the quoted post as its own post).
- `PostDetailView.swift`: detail + reply composer + replies (Bluesky `getPostThread`, X via TweetDetail capture).
- `Gallery.swift`: `ImageLoader` (NSCache, coalesced downloads, off-main decode, prefetch), `CachedImage`, full-screen `GalleryView` (zoom, swipe-down dismiss, native long-press menu → Save to Photos).
- `Video.swift`: inline videos autoplay **muted, loop**, mute choice is global and persisted; players only run when `mediaActive` (hidden feed pages/tabs/pushed screens must not play); full-screen `VideoViewer` with save (mp4 only; Bluesky HLS can't be saved).
- `Screens.swift`: Search and Notifications (Bluesky).
- `SettingsViews.swift`: accounts (X webview login, Bluesky app password), choose/reorder/rename feeds, Combined sources, accent color picker. `Theme.swift`: accent color persisted.
- `ComposeView.swift`: new post to Twitter and/or Bluesky (280/300 limits).

## Rules / gotchas learned the hard way

1. **Duplicate post ids break SwiftUI lists.** Always de-dupe (`unique`) before storing.
2. **Hidden pages stay alive** (all feed pages live in a ZStack to keep scroll position). Anything that autoplays or loads must respect visibility (`mediaActive`).
3. **Images popping in** was a recurring complaint: keep cache-first `State` initialisation, reserved aspect ratios, prefetch, off-main decoding. Don't swap back to `AsyncImage`.
4. Never block scrolling: gesture work must not claim vertical drags.
5. Treat X as hostile/unstable: timeouts, retries, soft failures; a failed "load more" must not permanently stop pagination.
6. Optimistic UI for like/repost, revert + toast on failure.
7. The product is **Twitter-themed, not X**. Keep wording consistent.
8. No secrets in the repo. Credentials live only on the device.

## Not done / ideas

Twitter-side search and notifications, Messages/DMs (placeholder), profiles (tapping an avatar does nothing), threads shown above a reply, link preview cards, polls, Bluesky video saving, Twitter lists/bookmarks, scroll-to-top on tab re-tap, push notifications (impossible without a server), widgets.

## How to work

Make a focused change → commit → push to `main` → confirm the Actions run succeeded → report what changed and what you could not verify on a device. If the user reports a bug from a screen recording, reason from the symptoms; you cannot reproduce it locally.
