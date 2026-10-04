import Foundation

/// Only PDFs attached to or named by this chat become downloadable document IDs.
enum CompanionDocuments {
    static func referenced(in text: String, folder: String?) -> [URL] {
        var urls = PathLinks.referencedFiles(in: text, folder: folder).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        if let regex = try? NSRegularExpression(pattern: #"\]\(<?([^)>]+)>?\)"#) {
            let source = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                if let url = resolve(source.substring(with: match.range(at: 1)), text: text, folder: folder), !urls.contains(url) { urls.append(url) }
            }
        }
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }

    }

    static func metadata(id: UUID, url: URL, name: String? = nil) -> Companion.File {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let revision = values.map { "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0)-\($0.fileSize ?? 0)" }
        return .init(id: id, name: name ?? url.lastPathComponent, mediaType: "application/pdf", isImage: false,
                     revision: revision, byteCount: values?.fileSize.map(Int64.init))
    }

    /// Portable IDs replace local Mac paths in Markdown links; the stored transcript is untouched.
    static func rewrite(_ text: String, folder: String?, documents: [(URL, UUID)]) -> String {
        guard !documents.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\]\(<?([^)>]+)>?\)"#) else { return text }
        let source = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let raw = source.substring(with: match.range(at: 1))
            guard let path = resolve(raw, text: text, folder: folder)?.path,
                  let id = documents.first(where: { $0.0.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path })?.1,
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "](chatterbox-document://\(id.uuidString))")
        }
        return result
    }
    private static func resolve(_ raw: String, text: String, folder: String?) -> URL? {
        let path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? raw) : (raw.removingPercentEncoding ?? raw)
        guard !path.contains("://"), (path as NSString).pathExtension.lowercased() == "pdf" else { return nil }
        let candidates = path.hasPrefix("/") || path.hasPrefix("~")
            ? [(path as NSString).expandingTildeInPath]
            : PathLinks.context(for: text, folder: folder).bases.map { ($0 as NSString).appendingPathComponent(path) }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

}
