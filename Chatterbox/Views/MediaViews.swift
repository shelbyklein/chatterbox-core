import AVKit
import ImageIO
import SwiftUI

/// A GIF, video, or Lottie animation in the chat, playing. Videos loop silently with
/// controls; Open shows the file in its own app.
struct MediaPreview: View {
    let url: URL
    let kind: MediaKind

    var body: some View {
        Group {
            switch kind {
            case .animatedImage: AnimatedImage(url: url)
            case .video: LoopingVideo(url: url)
            case .lottie: lottie { (try? String(contentsOf: url, encoding: .utf8)).map(MediaKind.lottiePage(json:)) }
            case .dotLottie: lottie { (try? Data(contentsOf: url)).map { MediaKind.dotLottiePage(base64: $0.base64EncodedString()) } }
            }
        }
        // Bottom corner: a page preview keeps its own buttons at the top.
        .overlay(alignment: .bottomTrailing) {
            Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
                .help("Open \(url.lastPathComponent)")
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @ViewBuilder
    private func lottie(_ page: () -> String?) -> some View {
        if let page = page() {
            // Near the animation's own size, not the reply's full width.
            HTMLPreview(source: .html(page), maxHeight: 400).frame(maxWidth: 420)
        } else {
            Text("Couldn't read \(url.lastPathComponent).").foregroundStyle(.secondary)
        }
    }
}

/// A GIF that animates, at its own size (up to 480 points).
private struct AnimatedImage: View {
    let url: URL
    @State private var size: CGSize?
    @State private var image: NSImage?

    init(url: URL) {
        self.url = url
        // Seen before: show it at once, at its size.
        _image = State(initialValue: TranscriptImages.cachedAnimated(url))
        _size = State(initialValue: TranscriptImages.cachedAnimated(url) == nil ? nil : TranscriptImages.size(of: url))
    }

    var body: some View {
        // Up to its own size but free to shrink: a fixed width here set the whole window's
        // minimum width, because the split view's minimum is the sum of its columns' contents.
        Group {
            if let image {
                AnimatedImageView(image: image)
            } else {
                // Holds the GIF's shape while it's read, so the transcript doesn't jump.
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
            }
        }
        .aspectRatio(size.map { $0.width / max($0.height, 1) } ?? 4 / 3, contentMode: .fit)
        .frame(maxWidth: min(size?.width ?? 480, 480), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            if size == nil { size = await TranscriptImages.loadSize(of: url) }
            if image == nil { image = await TranscriptImages.animatedImage(url) }
        }
    }
}

private struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.canDrawSubviewsIntoLayer = true
        view.image = image
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    /// Any size it's offered, at the image's shape, so it never sets a minimum width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        let natural = image.size
        let width = min(proposal.width ?? natural.width, natural.width)
        return CGSize(width: width, height: width * natural.height / max(natural.width, 1))
    }
}

/// A video that plays muted and loops, with the usual controls, at the video's own shape.
private struct LoopingVideo: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var aspect: CGFloat = 16 / 9

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: 640, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: url) {
                let item = AVPlayerItem(url: url)
                let queue = AVQueuePlayer()
                queue.isMuted = true
                looper = AVPlayerLooper(player: queue, templateItem: item)
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

/// Screenshots and renders a reply points to: one shown large, or several as a grid of
/// thumbnails. Clicking one opens it in the image viewer.
struct ReplyImages: View {
    let urls: [URL]
    @Environment(\.reviewImage) private var review

    var body: some View {
        if urls.count == 1, let url = urls.first {
            thumbnail(url, maxHeight: 520).frame(maxWidth: 640, alignment: .leading)
        } else if urls.count > 1 {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(urls, id: \.self) { thumbnail($0, maxHeight: 260) }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func thumbnail(_ url: URL, maxHeight: CGFloat) -> some View {
        Button { review.open(Attachment(name: url.lastPathComponent, path: url.path, mediaType: "image/" + url.pathExtension.lowercased(), kind: .image)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                AsyncLocalImage(url: url)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                Text(url.deletingPathExtension().lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("View \(url.lastPathComponent)")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// A picture from disk, read once off the main thread and downsized for the chat. Its shape
/// is held from the file's metadata while it loads.
private struct AsyncLocalImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var aspect: CGFloat?

    init(url: URL) {
        self.url = url
        _image = State(initialValue: TranscriptImages.cachedThumbnail(url, maxPixels: 1400))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if let aspect {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)).aspectRatio(aspect, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)).frame(height: 120)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            if let size = await TranscriptImages.loadSize(of: url), size.height > 0 { aspect = size.width / size.height }
            image = await TranscriptImages.thumbnail(url, maxPixels: 1400, pointsPerPixel: 0.5)
        }
    }
}
