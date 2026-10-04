#if GOLEM_APP
import AVFoundation
import Observation
import SwiftUI
import UIKit

/// The assistant's animations on the phone: fetched from the Mac once and kept in Caches,
/// fetched again only when a file there changes. Moods match the Mac's. With a rig among them
/// (golem.json and its stones) he's drawn live, like on the Mac; otherwise the videos play.
@MainActor
@Observable
final class MobileGolem {
    static let shared = MobileGolem()

    enum Mood: String {
        case waiting, thinking, news, idle
    }

    private(set) var files: [String: URL] = [:]
    private(set) var head: UIImage?
    private(set) var rig: GolemRig?
    /// Bumped when the cache is re-read, so a live Golem picks up a new rig.
    private(set) var revision = 0
    @ObservationIgnored private var loading = false

    private static var cache: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GolemAvatar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var hasAnimations: Bool { rig != nil || files["idle"] != nil }

    func url(for mood: Mood) -> URL? { files[mood.rawValue] ?? files["idle"] }

    static func mood(_ chat: Companion.ChatSummary) -> Mood {
        if chat.isWaitingOnYou { return .waiting }
        if chat.isRunning { return .thinking }
        if (chat.unread ?? 0) > 0 { return .news }
        return .idle
    }

    /// Brings the cache up to date with the Mac's Avatar folder.
    func load(from store: MobileStore) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // What's cached already shows at once, even before the Mac answers.
        if files.isEmpty { readCache() }
        guard let list = try? await store.avatarList() else { return }
        let fm = FileManager.default
        for file in list.files {
            let target = Self.cache.appendingPathComponent(file.name)
            let have = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard abs(have.timeIntervalSince(file.modified)) > 1 || !fm.fileExists(atPath: target.path) else { continue }
            guard let data = try? await store.avatarFile(file.name) else { continue }
            try? data.write(to: target, options: .atomic)
            try? fm.setAttributes([.modificationDate: file.modified], ofItemAtPath: target.path)
        }
        // Files removed on the Mac go here too.
        let names = Set(list.files.map(\.name))
        for url in (try? fm.contentsOfDirectory(at: Self.cache, includingPropertiesForKeys: nil)) ?? [] where !names.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
        readCache()
    }

    private func readCache() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: Self.cache, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for url in entries where url.pathExtension.lowercased() == "mov" {
            found[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        files = found
        head = UIImage(contentsOfFile: Self.cache.appendingPathComponent("head.png").path)
        rig = GolemRig.load(from: Self.cache)
        revision += 1
    }
}

/// The assistant's head, still, for the chat list.
struct MobileGolemHead: View {
    var size: CGFloat = 16
    private let golem = MobileGolem.shared

    var body: some View {
        if let head = golem.head {
            Image(uiImage: head).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size * 1.6, height: size)
        } else {
            Image(systemName: "circle.circle.fill")
        }
    }
}

/// The assistant, animated: live from his rig when there is one, else looping its current mood.
struct MobileGolemAnimated: View {
    let mood: MobileGolem.Mood
    private let golem = MobileGolem.shared

    var body: some View {
        if let rig = golem.rig {
            GolemRigView(rig: rig, mood: mood.rawValue).id(golem.revision)
        } else {
            videos
        }
    }

    private var videos: some View {
        let url = golem.url(for: mood)
        return ZStack {
            if let url {
                MobileLoopingVideo(url: url).id(url).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: url)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Golem, \(mood.rawValue)")
    }
}

private struct MobileLoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: UIView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            let layer = self.layer as! AVPlayerLayer
            layer.player = player
            layer.videoGravity = .resizeAspect
            layer.isOpaque = false
            player.isMuted = true
            // The phone's own music keeps playing.
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        required init?(coder: NSCoder) { fatalError() }

        func play(_ url: URL) {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        func stop() {
            looper?.disableLooping()
            player.pause()
        }
    }
}

#endif
