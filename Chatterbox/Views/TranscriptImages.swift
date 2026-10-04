import AppKit
import ImageIO

/// Pictures in the transcript, read once and off the main thread. Sizes come from the file's
/// metadata (no decode), so a placeholder can hold the final shape; thumbnails are made at
/// the size they're drawn and kept, so switching back to a chat doesn't read them again.
enum TranscriptImages {
    private final class Box: NSObject {
        let size: CGSize
        init(_ size: CGSize) { self.size = size }
    }
    nonisolated(unsafe) private static let sizes: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        return cache
    }()
    nonisolated(unsafe) private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    nonisolated(unsafe) private static let animated: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    /// The image's size in points as NSImage would report it (pixels at its DPI), from its
    /// metadata alone. Cached.
    static func size(of url: URL) -> CGSize? {
        let key = url.path as NSString
        if let box = sizes.object(forKey: key) { return box.size }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Double,
              var height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        // Rotated photos report their stored size; show them as they're meant to stand.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&width, &height) }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let size = CGSize(width: width * 72 / dpi, height: height * 72 / dpi)
        sizes.setObject(Box(size), forKey: key)
        return size
    }

    /// The size, looked up off the main thread the first time.
    static func loadSize(of url: URL) async -> CGSize? {
        if let box = sizes.object(forKey: url.path as NSString) { return box.size }
        return await Task.detached(priority: .userInitiated) { size(of: url) }.value
    }

    /// A thumbnail no bigger than `maxPixels` on its long side, at `pointsPerPixel` (1 for
    /// photos drawn at their pixel size, 0.5 for retina screenshots). Cached.
    static func cachedThumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
        thumbnails.object(forKey: "\(maxPixels)|\(url.path)" as NSString)
    }

    static func thumbnail(_ url: URL, maxPixels: Int, pointsPerPixel: Double = 1) async -> NSImage? {
        let key = "\(maxPixels)|\(url.path)" as NSString
        if let hit = thumbnails.object(forKey: key) { return hit }
        let made = await Task.detached(priority: .userInitiated) { () -> (CGImage, Int)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { return nil }
            return (cg, cg.bytesPerRow * cg.height)
        }.value
        guard let (cg, cost) = made else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) * pointsPerPixel, height: Double(cg.height) * pointsPerPixel))
        thumbnails.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// An animated image (a GIF), its bytes read off the main thread once. Frames decode as it plays.
    static func cachedAnimated(_ url: URL) -> NSImage? { animated.object(forKey: url.path as NSString) }

    static func animatedImage(_ url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let hit = animated.object(forKey: key) { return hit }
        guard let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url) }).value,
              let image = NSImage(data: data) else { return nil }
        animated.setObject(image, forKey: key, cost: data.count)
        return image
    }
}
