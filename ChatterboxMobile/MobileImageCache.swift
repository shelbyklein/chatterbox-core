import CryptoKit
import UIKit

/// Images from the Mac, kept on this phone: in memory while the app runs, and on disk in
/// Caches (which iOS may clear when space is short), so an image seen once shows at once
/// afterwards, after relaunching too, and while the Mac can't be reached. Keyed by chat, file,
/// its revision and the size asked for, so a changed file or a bigger copy is fetched anew.
@MainActor
final class MobileImageCache {
    static let shared = MobileImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL
    /// Disk use is kept under this; the least recently used images go first.
    static let diskLimit: Int64 = 400 * 1024 * 1024

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Images", isDirectory: true)) {
        self.folder = folder
        memory.totalCostLimit = 96 * 1024 * 1024
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task.detached(priority: .background) { [folder] in Self.prune(folder) }
    }

    /// "thumb" for list pictures, a pixel size for the chat, "full" for the original.
    static func key(chat: UUID, file: Companion.File, size: String) -> String {
        "\(chat.uuidString)|\(file.id.uuidString)|\(file.revision ?? "")|\(size)"
    }

    func image(_ key: String) -> UIImage? {
        if let image = memory.object(forKey: key as NSString) { return image }
        let url = path(key)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        // Touch it, so pruning keeps what's in use.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        remember(image, key)
        return image
    }

    func store(_ data: Data, as key: String) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        try? data.write(to: path(key), options: .atomic)
        remember(image, key)
        return image
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func remember(_ image: UIImage, _ key: String) {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        memory.setObject(image, forKey: key as NSString, cost: pixels * 4)
    }

    private func path(_ key: String) -> URL {
        folder.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Drops the least recently used images once the folder is over the limit.
    nonisolated static func prune(_ folder: URL, limit: Int64 = diskLimit) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.2 }
        guard total > limit else { return }
        entries.sort { $0.1 < $1.1 }
        for (url, _, size) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
