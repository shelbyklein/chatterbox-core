import Foundation
#if canImport(AppKit) && !CHATTERBOX_HEADLESS
import AppKit
#endif

struct PathLinks {
    static let scheme = "chatterbox-reveal"

    /// Folders to look in for relative paths, most specific first.
    var bases: [String]
    /// Whether disk lookups go through the short-lived memo (see `FileProbe`).
    var cached = true

    /// Looks a path up on disk, or in the memo when `cached`.
    private func probe(_ path: String) -> FileProbe.Result {
        cached ? FileProbe.shared.lookup(path) : FileProbe.read(path)
    }

    /// The folders a reply names in code, then the chat's folder.
    static func context(for text: String, folder: String?) -> PathLinks {
        context(for: text, folder: folder, cached: true)
    }

    static func context(for text: String, folder: String?, cached: Bool) -> PathLinks {
        var bases: [String] = []
        let links = PathLinks(bases: [], cached: cached)
        for code in codeSpans(in: text) where code.hasPrefix("/") || code.hasPrefix("~") {
            let path = (code as NSString).expandingTildeInPath
            let found = links.probe(path)
            guard found.exists else { continue }
            let base = found.isDirectory ? path : (path as NSString).deletingLastPathComponent
            if !bases.contains(base) { bases.append(base) }
        }
        if let folder, !bases.contains(folder) { bases.append(folder) }
        return PathLinks(bases: bases, cached: cached)
    }

    /// A link for `code` if it names a file or folder that exists.
    func url(for code: String) -> URL? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard Self.looksLikePath(text), let path = resolve(text) else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.path = path
        return components.url
    }

    private func resolve(_ text: String) -> String? {
        let candidates: [String]
        if text.hasPrefix("/") || text.hasPrefix("~") {
            candidates = [(text as NSString).expandingTildeInPath]
        } else {
            candidates = bases.map { ($0 as NSString).appendingPathComponent(text) }
        }
        for candidate in candidates {
            if probe(candidate).exists { return candidate }
            // "file.swift:42" names a line in the file.
            if let range = candidate.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
                let trimmed = String(candidate[..<range.lowerBound])
                if probe(trimmed).exists { return trimmed }
            }
        }
        return nil
    }

    /// Something shaped like a path or a file name, before checking the disk.
    private static func looksLikePath(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 1024, !text.contains("\n"), !text.contains("://") else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return true }
        if text.contains(" ") { return false }
        return text.contains("/") || text.range(of: #"^[\w@+\-.]+\.[A-Za-z][A-Za-z0-9]{0,5}$"#, options: .regularExpression) != nil
    }

    private static func codeSpans(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "`([^`\n]+)`") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Files a reply points to, in code (`out/logo.mp4`) or as links, that exist: absolute,
    /// or found in a folder the reply names, or the chat's folder.
    static func referencedFiles(in text: String, folder: String?) -> [String] {
        let context = context(for: text, folder: folder)
        var targets = codeSpans(in: text)
        if let regex = try? NSRegularExpression(pattern: #"\]\(<?([^)>]+)>?\)"#) {
            let ns = text as NSString
            targets += regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        var seen: [String] = []
        for target in targets {
            let cleaned = target.hasPrefix("file://") ? (URL(string: target)?.path ?? target) : (target.removingPercentEncoding ?? target)
            guard let path = context.url(for: cleaned)?.path, !seen.contains(path) else { continue }
            seen.append(path)
        }
        return seen
    }

    #if canImport(AppKit) && !CHATTERBOX_HEADLESS
    /// Opens a folder in Finder, or shows a file selected in its folder.
    static func reveal(_ url: URL) {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return NSSound.beep() }
        let file = URL(fileURLWithPath: path)
        if isDirectory.boolValue, file.pathExtension != "app" {
            NSWorkspace.shared.open(file)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
    #endif
}

/// A short-lived memo of whether paths exist, so rendering ~40 messages doesn't hit the disk
/// for every code span on every render. Entries expire after `ttl` seconds, so a file the
/// agent has just written becomes a link on the next render after that. Bounded; thread-safe.
final class FileProbe: @unchecked Sendable {
    struct Result: Equatable {
        var exists: Bool
        var isDirectory: Bool
    }

    static let shared = FileProbe()

    private let ttl: TimeInterval
    private let limit: Int
    private let lock = NSLock()
    private var entries: [String: (result: Result, at: TimeInterval)] = [:]

    init(ttl: TimeInterval = 3, limit: Int = 4000) {
        self.ttl = ttl
        self.limit = limit
    }

    static func read(_ path: String) -> Result {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return Result(exists: exists, isDirectory: exists && isDirectory.boolValue)
    }

    func lookup(_ path: String) -> Result {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let entry = entries[path], now - entry.at < ttl {
            lock.unlock()
            return entry.result
        }
        lock.unlock()
        let result = Self.read(path)
        lock.lock()
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[path] = (result, now)
        lock.unlock()
        return result
    }
}
