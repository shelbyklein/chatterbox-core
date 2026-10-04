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

    /// A stable id for a file a reply points to, so the phone can fetch it.
    static func mediaID(_ path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
