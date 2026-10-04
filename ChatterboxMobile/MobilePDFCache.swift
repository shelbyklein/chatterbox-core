import CoreGraphics
import Foundation

/// Persistent, private copies. Exporting to Files is separate from this review library.
enum MobilePDFCache {
    struct Entry: Codable, Identifiable {
        var file: Companion.File
        var chat: UUID
        var savedAt: Date
        var id: String { chat.uuidString + "-" + file.id.uuidString }
        var url: URL { MobilePDFCache.directory(file.id, chat: chat).appendingPathComponent(MobilePDFCache.safeName(file.name)) }
    }

    private static var root: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["CHATTERBOX_PDF_CACHE_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFReviews", isDirectory: true)
    }

    private static func directory(_ file: UUID, chat: UUID) -> URL {
        root.appendingPathComponent(chat.uuidString, isDirectory: true).appendingPathComponent(file.uuidString, isDirectory: true)
    }

    private static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        return base.lowercased().hasSuffix(".pdf") ? base : (base.isEmpty ? "Document.pdf" : base + ".pdf")
    }

    static func cached(_ file: Companion.File, chat: UUID) -> Entry? {
        let meta = directory(file.id, chat: chat).appendingPathComponent("entry.json")
        guard let data = try? Data(contentsOf: meta),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.chat == chat, entry.file.id == file.id, FileManager.default.fileExists(atPath: entry.url.path) else { return nil }
        return entry
    }

    static func save(_ temporary: URL, file: Companion.File, chat: UUID) throws -> Entry {
        // Inspect by file URL, never by loading the entire PDF into Data.
        guard CGPDFDocument(temporary as CFURL) != nil else {
            throw MobileError(message: "This file isn't a readable PDF. The saved copy hasn't been replaced.")
        }
        let fm = FileManager.default
        var folder = directory(file.id, chat: chat)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let entry = Entry(file: file, chat: chat, savedAt: Date())
        let incoming = folder.appendingPathComponent("incoming-" + UUID().uuidString + ".pdf")
        defer { try? fm.removeItem(at: incoming) }
        try fm.copyItem(at: temporary, to: incoming)
        if fm.fileExists(atPath: entry.url.path) {
            _ = try fm.replaceItemAt(entry.url, withItemAt: incoming)
        } else { try fm.moveItem(at: incoming, to: entry.url) }
        try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
        return entry
    }

    static func entries() -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [Entry] = []
        for case let url as URL in enumerator where url.lastPathComponent == "entry.json" {
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  fm.fileExists(atPath: entry.url.path) else { continue }
            result.append(entry)
        }
        return result.sorted { $0.savedAt > $1.savedAt }
    }

    static func remove(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: directory(entry.file.id, chat: entry.chat))
    }
}

/// URLSession writes to a temporary file while these callbacks update the progress display.
final class PDFDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @MainActor @Sendable (Int64, Int64) -> Void
    init(update: @escaping @MainActor @Sendable (Int64, Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in update(totalBytesWritten, totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
