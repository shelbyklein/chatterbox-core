import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A logo for each project folder, shown on its Home tile and in the sidebar.
///
/// One you chose ("Set Project Icon…") is copied into Chatterbox's data, so moving or
/// deleting the original doesn't lose it. Otherwise the folder's own logo is used when it has
/// one: an app icon in an asset catalog, a logo or icon file, or a favicon. Looked up once per
/// folder, off the main thread, and kept as a small thumbnail.
@MainActor
@Observable
final class ProjectIcons {
    static let shared = ProjectIcons()
    private(set) var icons: [String: NSImage] = [:]
    @ObservationIgnored private var looked: Set<String> = []

    /// Where chosen icons are kept, beside the conversations (tests keep theirs apart).
    private static var directory: URL {
        let base: URL
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"], !dir.isEmpty {
            base = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Chatterbox", isDirectory: true)
        }
        return base.appendingPathComponent("ProjectIcons", isDirectory: true)
    }

    nonisolated private static func customFile(for folder: String, in directory: URL) -> URL {
        let key = SHA256.hash(data: Data(folder.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key).png")
    }

    /// Finds the folder's icon the first time it's asked for.
    func load(_ folder: String?) {
        guard let folder, looked.insert(folder).inserted else { return }
        let directory = Self.directory
        Task.detached(priority: .utility) {
            let custom = Self.customFile(for: folder, in: directory)
            let source = FileManager.default.fileExists(atPath: custom.path) ? custom : Self.detect(in: folder)
            let image = source.flatMap { Self.thumbnail($0, side: 128) }
            await MainActor.run { if let image { self.icons[folder] = image } }
        }
    }

    /// Asks for an image and keeps a copy of it as the project's icon.
    func choose(for folder: String) {
        let panel = NSOpenPanel()
        panel.message = "Choose an image to use as this project's icon"
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: folder)
        guard panel.runModal() == .OK, let url = panel.url,
              let image = Self.thumbnail(url, side: 256),
              let png = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:])
        else { return }
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: Self.customFile(for: folder, in: directory), options: .atomic)
        icons[folder] = Self.thumbnail(Self.customFile(for: folder, in: directory), side: 128) ?? image
    }

    /// Back to the folder's own logo, or none.
    func remove(for folder: String) {
        try? FileManager.default.removeItem(at: Self.customFile(for: folder, in: Self.directory))
        icons[folder] = nil
        looked.remove(folder)
        load(folder)
    }

    func hasCustom(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.customFile(for: folder, in: Self.directory).path)
    }

    // MARK: - Finding a folder's own logo

    /// Folders that hold dependencies or build output, never the project's own logo.
    nonisolated private static let skipped: Set<String> = ["node_modules", ".git", "build", "DerivedData", "Pods", ".build",
                                                           "vendor", "dist", ".next", "Carthage", "wp-includes", "wp-admin",
                                                           "plugins", "mu-plugins", "upgrade", "cache"]

    /// The best logo in the folder, searched a few levels deep.
    nonisolated static func detect(in folder: String) -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        var appIcons: [URL] = [], logos: [URL] = [], favicons: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                let lower = name.lowercased()
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if lower == "appicon.appiconset" { appIcons += largestImage(in: entry).map { [$0] } ?? []; continue }
                    if depth < 4, !skipped.contains(name) { queue.append((entry, depth + 1)) }
                    continue
                }
                let ext = entry.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "svg", "ico", "icns", "webp"].contains(ext) else { continue }
                let base = (lower as NSString).deletingPathExtension
                if base == "logo" || base.hasPrefix("logo-") || base.hasPrefix("logo_") || base == "icon" || base == "app-icon" || base == "appicon" {
                    logos.append(entry)
                } else if base == "favicon" || base.hasPrefix("apple-touch-icon") {
                    favicons.append(entry)
                }
            }
        }
        // Shallower first, then the biggest file of the kind.
        func best(_ urls: [URL]) -> URL? {
            urls.min { a, b in
                let da = a.pathComponents.count, db = b.pathComponents.count
                if da != db { return da < db }
                return fileSize(a) > fileSize(b)
            }
        }
        return appIcons.max { fileSize($0) < fileSize($1) } ?? best(logos) ?? best(favicons)
    }

    nonisolated private static func largestImage(in folder: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .max { fileSize($0) < fileSize($1) }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    nonisolated private static func thumbnail(_ url: URL, side: Int) -> NSImage? {
        if url.pathExtension.lowercased() == "svg" {
            // ImageIO doesn't read SVG; AppKit does.
            guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
            let size = NSSize(width: side, height: side)
            return NSImage(size: size, flipped: false) { rect in image.draw(in: rect); return true }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
