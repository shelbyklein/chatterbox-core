import Foundation
import CryptoKit

extension ChatSession {
    /// GIFs, videos, and Lottie files a reply points to that exist, to play under it.
    static func referencedMedia(in text: String, folder: String?) -> [URL] {
        PathLinks.referencedFiles(in: text, folder: folder).map { URL(fileURLWithPath: $0) }
            .filter { MediaKind.of($0) != nil }
    }

    /// Screenshots, renders, and proofs a reply points to, to show under it: image files it
    /// names, and the images in a folder it names for review ("Review Screenshots/"). At most 8.
    static func referencedImages(in text: String, folder: String?) -> [URL] {
        let fm = FileManager.default
        var images: [URL] = []
        for path in PathLinks.referencedFiles(in: text, folder: folder) {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if MediaKind.isStillImage(path) { images.append(url) }
            } else if url.lastPathComponent.range(of: "screenshot|review|proof|preview|render|mockup", options: [.regularExpression, .caseInsensitive]) != nil {
                // Not every folder: "Links/" full of placed photos isn't for review.
                let inside = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .filter { MediaKind.isStillImage($0.path) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                images += inside
            }
        }
        var seen = Set<String>()
        return Array(images.filter { seen.insert($0.path).inserted }.prefix(8))
    }

    /// Same bounded latest-image lookup for Mac tiles and mobile previews. Cache by
    /// transcript structure so list polling does not repeatedly scan long conversations.
    func latestThumbnailURL() -> URL? {
        if let listSummary { return listSummary.thumbnailPath.map { URL(fileURLWithPath: $0) } }
        let key = "\(workingFolder ?? "")|\(items.count)|\(items.last?.id.uuidString ?? "")|\(items.last?.phase.rawValue ?? "")"
        if thumbnailLookupKey == key { return thumbnailLookupURL }
        thumbnailLookupKey = key
        let fm = FileManager.default
        func usable(_ url: URL) -> Bool {
            (MediaKind.isStillImage(url.path) || url.pathExtension.lowercased() == "gif") && fm.fileExists(atPath: url.path)
        }
        thumbnailLookupURL = nil
        for item in items.suffix(300).reversed() {
            switch item.kind {
            case .image, .user:
                thumbnailLookupURL = item.attachments?.map(\.url).last(where: usable)
            case .assistant where item.phase == .final:
                thumbnailLookupURL = (Self.referencedImages(in: item.text, folder: workingFolder) + Self.madeFiles(item, folder: workingFolder).images).last(where: usable)
            default: break
            }
            if thumbnailLookupURL != nil { break }
        }
        // The app holds only the newest part of most chats: with no image in it, keep the one
        // found before, while its file is still there.
        if let url = thumbnailLookupURL { ThumbnailMemory.remember(url, for: id) }
        else if let path = ThumbnailMemory.path(for: id), fm.fileExists(atPath: path), usable(URL(fileURLWithPath: path)) {
            thumbnailLookupURL = URL(fileURLWithPath: path)
        }
        return thumbnailLookupURL
    }

    /// A stable id for a file a reply points to, so the phone can fetch it.
    static func mediaID(_ path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Each chat's last image found, kept on disk (one file per process, so the app and the
/// background service never overwrite each other's).
@MainActor
enum ThumbnailMemory {
    private static var file: URL {
        RuntimePaths.data.appendingPathComponent("Thumbnails-\(ProcessInfo.processInfo.processName).json")
    }
    private static var paths: [String: String] = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]

    static func path(for chat: UUID) -> String? { paths[chat.uuidString] }

    static func remember(_ url: URL, for chat: UUID) {
        guard paths[chat.uuidString] != url.path else { return }
        paths[chat.uuidString] = url.path
        try? JSONEncoder().encode(paths).write(to: file, options: .atomic)
    }
}


/// What a turn made, shown under its reply even when the reply only links it or doesn't name
/// it (Shelby, November 24: "some turns just provide links, no images, video, pdf"). Read by
/// the service as a turn ends: media changed in the session's folder (and Codex's generated
/// images) while it ran, and web images, videos and PDFs the reply links, copied locally.
enum TurnOutputs {
    static let limit = 12
    /// Folders never looked in: build products, dependencies, caches.
    static let skipped: Set<String> = ["node_modules", "build", "DerivedData", "Pods", ".build", "Library", "Caches", "venv", ".venv", "__pycache__", "vendor", "Reply Media"]

    /// One spelling per file ("/private/var/…" and "/var/…" are the same), to compare paths.
    nonisolated static func normal(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }
    static let documentExtensions: Set<String> = ["pdf"]

    /// Whether a file is something to show: a picture, GIF, video, animation, 3D model or PDF.
    nonisolated static func shows(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if MediaKind.isStillImage(path) || documentExtensions.contains(ext) || ext == "gif" || ext == "lottie" || ext == "usdz" { return true }
        return MediaKind.videoExtensions.contains(ext) || MediaKind.modelExtensions.contains(ext)
    }

    /// Media files in `folders` changed at or after `since`, oldest first. Bounded: a few levels
    /// deep (one in the home folder), skipping hidden and build folders, 40,000 entries at most.
    nonisolated static func scan(folders: [String], since: Date) -> [(path: String, date: Date)] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var found: [(path: String, date: Date)] = []
        var seen = Set<String>()
        for folder in folders {
            let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
            guard root.path != "/", fm.fileExists(atPath: root.path) else { continue }
            let depth = root.path == home ? 1 : 4
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var visited = 0
            while let url = walker.nextObject() as? URL {
                visited += 1
                if visited > 40_000 { break }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if walker.level >= depth || skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard shows(url.path), let date = values?.contentModificationDate, date >= since.addingTimeInterval(-2),
                      (values?.fileSize ?? 0) > 0, seen.insert(normal(url.path)).inserted else { continue }
                found.append((normal(url.path), date))
            }
        }
        return found.sorted { $0.date < $1.date }
    }

    /// Of what the scan found, what this turn made: every file whose name the turn's rows
    /// mention ("Writing banner.png", a command that saved it), every image Codex generated,
    /// and the rest only when there are a few (a folder others are busy in shouldn't flood it).
    nonisolated static func choose(_ found: [(path: String, date: Date)], mentioned: String, generated: String?) -> [String] {
        let named = found.filter { item in
            (generated.map { item.path.hasPrefix(normal($0)) } ?? false) || mentioned.contains((item.path as NSString).lastPathComponent)
        }.map(\.path)
        let rest = found.map(\.path).filter { !named.contains($0) }
        return Array((named + (rest.count <= 3 ? rest : [])).suffix(limit))
    }

    // MARK: Web media

    static let webExtensions: Set<String> = MediaKind.stillImageExtensions.union(MediaKind.videoExtensions).union(["gif", "pdf"])

    /// Web links in a reply that are pictures, videos or PDFs: by their file name, or written
    /// as a Markdown image. At most six.
    nonisolated static func webMedia(in text: String) -> [URL] {
        var urls: [URL] = []
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let source = text as NSString
        let images = (try? NSRegularExpression(pattern: #"!\[[^\]]*\]\((https?://[^)\s]+)\)"#))?
            .matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { URL(string: source.substring(with: $0.range(at: 1))) } ?? []
        for url in images where !urls.contains(url) { urls.append(url) }
        for match in detector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  webExtensions.contains(url.pathExtension.lowercased()), !urls.contains(url) else { continue }
            urls.append(url)
        }
        return Array(urls.prefix(6))
    }

    static var cache: URL { RuntimePaths.data.appendingPathComponent("Reply Media", isDirectory: true) }

    /// A web file's copy is named by its address: "<hash>.<extension>".
    nonisolated static func digest(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fileExtension(_ url: URL, type: String) -> String {
        let ext = url.pathExtension.lowercased()
        if webExtensions.contains(ext) { return ext }
        if type == "application/pdf" { return "pdf" }
        if type.hasPrefix("video/") { return type == "video/quicktime" ? "mov" : "mp4" }
        let image = String(type.dropFirst("image/".count)).replacingOccurrences(of: "jpeg", with: "jpg")
        return webExtensions.contains(image) ? image : "png"
    }

    /// Local copies of `urls` (kept ones reused). Pictures, videos and PDFs only, 100 MB at most each.
    nonisolated static func download(_ urls: [URL], folder: URL) async -> [String] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copies: [String] = []
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for url in urls {
            let key = digest(url)
            if let copy = kept.first(where: { $0.hasPrefix(key + ".") }) { copies.append(normal(folder.appendingPathComponent(copy).path)); continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Chatterbox", forHTTPHeaderField: "User-Agent")
            guard let (file, response) = try? await URLSession.shared.download(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
            let type = (http.mimeType ?? "").lowercased()
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard type.hasPrefix("image/") || type.hasPrefix("video/") || type == "application/pdf", size > 0, size <= 100 * 1024 * 1024 else {
                try? FileManager.default.removeItem(at: file); continue
            }
            let target = folder.appendingPathComponent(key + "." + fileExtension(url, type: type))
            try? FileManager.default.removeItem(at: target)
            guard (try? FileManager.default.moveItem(at: file, to: target)) != nil else { continue }
            copies.append(normal(target.path))
        }
        return copies
    }
}

extension ChatSession {
    /// As a turn ends: what it made, on its final reply (TurnOutputs). Runs off the main thread.
    func noteTurnOutputs(since started: Date?) {
        guard let started,
              let index = record.items.lastIndex(where: { $0.kind == .assistant && $0.phase == .final }),
              record.items[index...].allSatisfy({ $0.kind != .user || $0.steered }),
              (record.items[index].timestamp ?? .distantPast) >= started else { return }
        let final = record.items[index]
        let turn = record.items.filter { ($0.timestamp ?? .distantPast) >= started }
        let mentioned = turn.map { $0.text + " " + ($0.detail ?? "") }.joined(separator: "\n")
        var folders = [workingFolder].compactMap { $0 }
        var generated: String?
        if let thread = record.codex?.threadId, !thread.isEmpty {
            generated = NSHomeDirectory() + "/.codex/generated_images/" + thread
            folders.append(generated!)
        }
        let named = Set(PathLinks.referencedFiles(in: final.text, folder: workingFolder).map(TurnOutputs.normal))
        let links = TurnOutputs.webMedia(in: final.text)
        let cache = TurnOutputs.cache
        Task { @MainActor [weak self] in
            let local = await Task.detached(priority: .utility) {
                TurnOutputs.choose(TurnOutputs.scan(folders: folders, since: started), mentioned: mentioned, generated: generated)
            }.value
            let web = links.isEmpty ? [] : await TurnOutputs.download(links, folder: cache)
            var made: [String] = []
            for path in local where !named.contains(path) && !made.contains(path) { made.append(path) }
            for path in web where !made.contains(path) { made.append(path) }
            guard !made.isEmpty, let self, let at = self.record.items.firstIndex(where: { $0.id == final.id }) else { return }
            self.record.items[at].made = Array(made.prefix(TurnOutputs.limit))
            self.onChange?(self)
        }
    }

    /// A reply's made files that still exist and it doesn't already name: images, playable
    /// media and documents, to show under it.
    static func madeFiles(_ item: DisplayItem, folder: String?) -> (images: [URL], media: [URL], documents: [URL]) {
        guard let made = item.made, !made.isEmpty else { return ([], [], []) }
        let named = Set(PathLinks.referencedFiles(in: item.text, folder: folder).map(TurnOutputs.normal))
        let fm = FileManager.default
        var seen = Set<String>()
        let urls = made.map(TurnOutputs.normal).filter { !named.contains($0) && fm.fileExists(atPath: $0) && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
        return (urls.filter { MediaKind.isStillImage($0.path) },
                urls.filter { !MediaKind.isStillImage($0.path) && $0.pathExtension.lowercased() != "pdf" && MediaKind.of($0) != nil },
                urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }
}
