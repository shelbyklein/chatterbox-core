
#if !CHATTERBOX_HEADLESS
import AppKit
#endif
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file the user attached to a message. The file is copied into Application Support,
/// so the chat keeps working if the original moves.
struct Attachment: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case image, pdf, text, document, other }

    var id = UUID()
    var name: String
    /// The app's own copy of the file.
    var path: String
    var mediaType: String
    var kind: Kind

    var url: URL { URL(fileURLWithPath: path) }
}

/// What the user sent: text plus any attachments. Also used for messages sent mid-turn.
struct UserMessage {
    var text: String
    var attachments: [Attachment] = []
}

enum Attachments {
    /// Claude resizes anything larger, so sending more only costs upload time.
    static let maxImageEdge = 2576
    static let maxImageBytes = 5 * 1024 * 1024

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("Chatterbox", isDirectory: true)
        let dir = root.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Import

    /// Copies a file into the attachment store, converting images Claude can't read (HEIC, TIFF, …).
    static func importFile(_ source: URL) throws -> Attachment {
        let type = UTType(filenameExtension: source.pathExtension) ?? .data
        // Only photos and screenshots are resized for the agent. Design files that macOS also
        // counts as images (Illustrator, Photoshop, EPS, SVG) are kept as the original file.
        if rasterTypes.contains(where: type.conforms(to:)) {
            return try importImage(at: source, name: source.deletingPathExtension().lastPathComponent)
        }
        let id = UUID()
        let dest = try folder(for: id).appendingPathComponent(safeName(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: dest)
        return Attachment(id: id, name: source.lastPathComponent, path: dest.path,
                          mediaType: type.preferredMIMEType ?? "application/octet-stream", kind: kind(of: type, at: dest))
    }

    static let rasterTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp]

    /// Imports raw image data, such as a pasted screenshot.
    static func importImageData(_ data: Data, name: String = "Pasted image") throws -> Attachment {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try importImage(at: temp, name: name)
    }

    private static func importImage(at source: URL, name: String) throws -> Attachment {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw AttachmentError("\(name) isn't an image macOS can read.")
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sourceType = (CGImageSourceGetType(src) as String?).flatMap(UTType.init) ?? .image
        let native: [UTType] = [.png, .jpeg, .gif, .webP]
        let id = UUID()
        let folder = try folder(for: id)

        // Already fine as-is: keep the original bytes.
        if native.contains(sourceType), max(width, height) <= maxImageEdge, size <= maxImageBytes {
            let ext = sourceType.preferredFilenameExtension ?? "png"
            let dest = folder.appendingPathComponent(safeName(name) + "." + ext)
            try FileManager.default.copyItem(at: source, to: dest)
            return Attachment(id: id, name: dest.lastPathComponent, path: dest.path,
                              mediaType: sourceType.preferredMIMEType ?? "image/png", kind: .image)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height, 1), maxImageEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw AttachmentError("Couldn't convert \(name).")
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let outType: UTType = hasAlpha ? .png : .jpeg
        let dest = folder.appendingPathComponent(safeName(name) + "." + (outType.preferredFilenameExtension ?? "png"))
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, outType.identifier as CFString, 1, nil) else {
            throw AttachmentError("Couldn't convert \(name).")
        }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw AttachmentError("Couldn't convert \(name).") }
        return Attachment(id: id, name: dest.lastPathComponent, path: dest.path,
                          mediaType: outType.preferredMIMEType ?? "image/png", kind: .image)
    }

    private static func kind(of type: UTType, at url: URL) -> Attachment.Kind {
        if type.conforms(to: .pdf) { return .pdf }
        if [UTType.rtf, .rtfd, .html, .webArchive].contains(where: type.conforms(to:))
            || ["doc", "docx", "odt"].contains(url.pathExtension.lowercased()) {
            return .document
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || isUTF8Text(url) { return .text }
        return .other
    }

    private static func isUTF8Text(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 8192)) ?? Data()
        return !sample.contains(0) && String(data: sample, encoding: .utf8) != nil
    }

    private static func folder(for id: UUID) throws -> URL {
        let url = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// File names the Files API accepts: no path separators or reserved characters.
    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "<>:\"|?*\\/").union(.controlCharacters)
        let cleaned = String(name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) }).prefix(200)
        return cleaned.isEmpty ? "file" : String(cleaned)
    }

    /// Deletes the app's own copies. Anything outside the attachment store (such as a file
    /// an agent wrote in the user's project, shown as a preview) is never touched.
    static func remove(_ attachments: [Attachment]) {
        let store = directory.standardizedFileURL.path + "/"
        for attachment in attachments {
            let folder = attachment.url.deletingLastPathComponent().standardizedFileURL
            guard folder.path.hasPrefix(store), folder.path != store.dropLast() else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A reference to a file in place, for previews of files an agent wrote.
    static func reference(_ url: URL) -> Attachment {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return Attachment(name: url.lastPathComponent, path: url.path,
                          mediaType: type.preferredMIMEType ?? "text/html", kind: type.conforms(to: .image) && url.pathExtension.lowercased() != "svg" ? .image : .text)
    }

    // MARK: - Pasteboard

    /// Attachments on the pasteboard: copied files first, otherwise image data (screenshots, copied images).
    /// Returns nil when the pasteboard holds nothing to attach, so a normal text paste proceeds.
    #if !CHATTERBOX_HEADLESS
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [Attachment]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap { try? importFile($0) }
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                                                         NSPasteboard.PasteboardType(UTType.heic.identifier)]
        // Rich text copied from a page can carry an image too; paste that as text.
        guard pasteboard.string(forType: .string) == nil,
              let type = pasteboard.availableType(from: imageTypes),
              let data = pasteboard.data(forType: type) else { return nil }
        return (try? importImageData(data)).map { [$0] }
    }

    #endif

    // MARK: - Claude Code content

    /// Content for a Claude Code user message: images inline, other files by path so
    /// Claude Code opens them with its own tools (it reads PDFs, code, and documents).
    static func claudeContent(for message: UserMessage) -> [JSON] {
        var blocks: [JSON] = []
        for image in message.attachments where image.kind == .image {
            guard let data = try? Data(contentsOf: image.url) else { continue }
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType),
                                                         "data": .string(data.base64EncodedString())]])
        }
        var text = message.text
        let files = message.attachments.filter { $0.kind != .image }
        if !files.isEmpty {
            let list = files.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
            text += (text.isEmpty ? "" : "\n\n") + "Attached files (read them from these paths):\n" + list
        }
        if !text.isEmpty { blocks.append(.text(text)) }
        return blocks
    }
}

struct AttachmentError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
