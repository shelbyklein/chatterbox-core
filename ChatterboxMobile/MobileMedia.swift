import AVKit
import ImageIO
import SwiftUI
import UIKit

/// A GIF, video, or Lottie animation from the chat, fetched from the Mac and playing.
struct RemoteMedia: View {
    let file: Companion.File
    let chat: UUID
    @Environment(MobileStore.self) private var store
    @State private var loaded: Loaded?
    @State private var failed = false

    enum Loaded {
        case gif(UIImage)
        case video(URL)
        case page(String)
    }

    static func isMedia(_ file: Companion.File) -> Bool {
        MediaKind.of(name: file.name, contents: { nil }) != nil || (file.name as NSString).pathExtension.lowercased() == "json"
    }

    var body: some View {
        Group {
            switch loaded {
            case .gif(let image):
                AnimatedImageView(image: image)
                    .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                    .frame(maxWidth: 360)
            case .video(let url):
                LoopingVideo(url: url).frame(maxWidth: 520)
            case .page(let html):
                HTMLPreview(source: .html(html), maxHeight: 480)
            case nil:
                RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 160)
                    .overlay { if failed { Text("Couldn't load \(file.name)").font(.caption).foregroundStyle(.secondary) } else { ProgressView() } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: file.id) { await load() }
    }

    private func load() async {
        guard loaded == nil, let data = try? await store.file(file, in: chat) else { failed = true; return }
        switch MediaKind.of(name: file.name, contents: { data }) {
        case .animatedImage:
            if let image = Self.animatedImage(data) { loaded = .gif(image) } else { failed = true }
        case .video:
            // AVPlayer plays from a file: keep a copy in the app's caches.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.id.uuidString + "." + (file.name as NSString).pathExtension)
            do { try data.write(to: url); loaded = .video(url) } catch { failed = true }
        case .lottie:
            loaded = .page(MediaKind.lottiePage(json: String(decoding: data, as: UTF8.self)))
        case .dotLottie:
            loaded = .page(MediaKind.dotLottiePage(base64: data.base64EncodedString()))
        case nil:
            failed = true
        }
    }

    /// A GIF's frames as one animating image, at its own timing.
    static func animatedImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += delay < 0.02 ? 0.1 : delay
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}

/// UIImageView plays an animated UIImage; SwiftUI's Image shows only its first frame.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}
}

/// A video that plays muted and loops, with the usual controls.
private struct LoopingVideo: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var aspect: CGFloat = 16 / 9

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(aspect, contentMode: .fit)
            .task(id: url) {
                let queue = AVQueuePlayer()
                queue.isMuted = true
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                player = queue
                queue.play()
                if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                   let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let shown = natural.applying(transform)
                    if abs(shown.height) > 0 { aspect = abs(shown.width) / abs(shown.height) }
                }
            }
            .onDisappear { player?.pause() }
    }
}
