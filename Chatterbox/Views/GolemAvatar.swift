#if GOLEM_APP
import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Golem's animations, from the assistant's Avatar folder. With a rig there (`golem.json` and
/// its stone images, see Shared/GolemRig.swift) he's drawn live and moves between moods; without
/// one, `<mood>.mov` files play (HEVC with alpha, on a shared stage; see
/// scripts/make-golem-avatar.py). Either way `head.png` is his still head. Changes there are
/// picked up the next time the folder is looked at.
@MainActor
@Observable
final class GolemAvatar {
    static let shared = GolemAvatar()

    /// What Golem is up to, most pressing first.
    enum Mood: String, CaseIterable {
        /// Something waits on you (an approval or a question in his chat).
        case waiting
        /// Working on a reply.
        case thinking
        /// Has replies you haven't read.
        case news
        case idle

        /// The file to play, or a stand-in when this mood hasn't been made yet.
        var fallbacks: [Mood] { self == .idle ? [.idle] : [self, .idle] }
    }

    private(set) var files: [String: URL] = [:]
    private(set) var head: NSImage?
    /// His live rig, when the folder has one; preferred over the videos.
    private(set) var rig: GolemRig?
    /// Bumped when the files change, so players reload.
    private(set) var revision = 0
    @ObservationIgnored private var checked = Date.distantPast
    @ObservationIgnored private var stamp = ""

    static var folder: URL { URL(fileURLWithPath: AppModel.dotFolder).appendingPathComponent("Avatar", isDirectory: true) }

    var hasAnimations: Bool { rig != nil || files["idle"] != nil }

    func url(for mood: Mood) -> URL? {
        refreshIfStale()
        return mood.fallbacks.lazy.compactMap { self.files[$0.rawValue] }.first
    }

    /// Animations that aren't a mood (playful, sneeze…): little flourishes now and then.
    var flourishes: [URL] {
        refreshIfStale()
        return files.filter { Mood(rawValue: $0.key) == nil }.map(\.value).sorted { $0.path < $1.path }
    }

    /// Re-reads the folder at most every few seconds, and only reloads when something changed.
    func refreshIfStale() {
        guard Date().timeIntervalSince(checked) > 5 else { return }
        checked = Date()
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newStamp = entries.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return url.lastPathComponent + "@\(date.timeIntervalSince1970)"
        }.sorted().joined(separator: "|")
        guard newStamp != stamp else { return }
        stamp = newStamp
        var found: [String: URL] = [:]
        for url in entries where url.pathExtension.lowercased() == "mov" {
            found[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        // Mutated outside a view update, so observers redraw cleanly.
        DispatchQueue.main.async {
            self.files = found
            self.head = NSImage(contentsOf: Self.folder.appendingPathComponent("head.png"))
            self.rig = GolemRig.load(from: Self.folder)
            self.revision += 1
        }
    }

    /// The mood for Golem's chat right now.
    static func mood(of dot: ChatSession?) -> Mood {
        guard let dot else { return .idle }
        if dot.isWaitingOnYou { return .waiting }
        if dot.isRunning { return .thinking }
        if Attention.shared.dotUnreadCount(dot) > 0 { return .news }
        return .idle
    }
}

/// Golem's head, still, for small places like the sidebar.
struct GolemHead: View {
    var size: CGFloat = 18
    private let avatar = GolemAvatar.shared

    var body: some View {
        let _ = avatar.refreshIfStale()
        if let head = avatar.head {
            Image(nsImage: head)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 1.6, height: size)
        } else {
            Image(systemName: "circle.circle.fill").foregroundStyle(Color.highlight)
        }
    }
}

/// Golem, animated. With his rig, drawn live: changing mood plays a transition between poses.
/// Otherwise the current mood's video loops, crossfading when it changes, with a flourish
/// (a sneeze, a playful moment) now and then while idle. Square; transparent around him.
struct GolemAnimated: View {
    let mood: GolemAvatar.Mood
    private let avatar = GolemAvatar.shared

    var body: some View {
        let _ = avatar.refreshIfStale()
        if let rig = avatar.rig {
            GolemRigView(rig: rig, mood: mood.rawValue)
                .id(avatar.revision)
        } else {
            videos
        }
    }

    private var videos: some View {
        let url = avatar.url(for: mood)
        return ZStack {
            if let url {
                LoopingVideo(url: url, flourishes: mood == .idle ? avatar.flourishes : [], revision: avatar.revision)
                    .id(url)
                    .transition(.opacity)
            } else {
                GolemHead(size: 24)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: url)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Golem, \(mood.rawValue)")
    }
}

/// A transparent HEVC video, looping, that occasionally plays a flourish once in between.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL
    let flourishes: [URL]
    let revision: Int

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url, flourishes: flourishes)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.flourishes = flourishes
        if view.revision != revision { view.revision = revision; view.play(url, flourishes: flourishes) }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: NSView {
        var revision = 0
        var flourishes: [URL] = []
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var mainItem: AVPlayerItem?
        private var timer: Timer?
        private var observer: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = .clear
            layer.isOpaque = false
            self.layer = layer
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        required init?(coder: NSCoder) { fatalError() }

        func play(_ url: URL, flourishes: [URL]) {
            self.flourishes = flourishes
            stopLoop()
            let item = AVPlayerItem(url: url)
            mainItem = item
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
            scheduleFlourish()
        }

        /// Every 40–90 seconds of idling, one flourish plays once, then the loop carries on.
        private func scheduleFlourish() {
            timer?.invalidate()
            guard !flourishes.isEmpty else { return }
            timer = Timer.scheduledTimer(withTimeInterval: .random(in: 40...90), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.playFlourish() }
            }
        }

        private func playFlourish() {
            guard let flourish = flourishes.randomElement(), let mainURL = (mainItem?.asset as? AVURLAsset)?.url, window != nil else {
                scheduleFlourish()
                return
            }
            stopLoop()
            let item = AVPlayerItem(url: flourish)
            player.insert(item, after: nil)
            player.play()
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.play(mainURL, flourishes: self?.flourishes ?? []) }
            }
        }

        private func stopLoop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
        }

        func stop() {
            timer?.invalidate()
            stopLoop()
            player.pause()
        }

        override var isOpaque: Bool { false }
    }
}

#endif
