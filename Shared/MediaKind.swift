import Foundation

/// Files that play rather than sit still: GIFs, videos, and Lottie animations. Shared with
/// the iPhone app.
enum MediaKind: Equatable {
    case animatedImage
    case video
    /// A Lottie animation as JSON (Bodymovin), or as a .lottie (dotLottie) archive.
    case lottie
    case dotLottie

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    /// Pictures that sit still (screenshots, renders, proofs), shown under a reply that names them.
    static let stillImageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff", "bmp"]

    static func isStillImage(_ name: String) -> Bool { stillImageExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// What a file is, by its name (and, for .json, a look inside to tell Lottie from data).
    static func of(name: String, contents: () -> Data?) -> MediaKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "gif" { return .animatedImage }
        if videoExtensions.contains(ext) { return .video }
        if ext == "lottie" { return .dotLottie }
        if ext == "json", let data = contents(), isLottie(data) { return .lottie }
        return nil
    }

    static func of(_ url: URL) -> MediaKind? {
        of(name: url.lastPathComponent) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4096)
        }
    }

    /// Lottie JSON starts with its version, frame rate, size, and layers.
    static func isLottie(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        return head.contains("\"layers\"") || (head.contains("\"fr\"") && head.contains("\"ip\"") && head.contains("\"op\""))
    }

    /// A page that plays a Lottie animation, looping, centered on white. Lottie's player
    /// loads from a CDN.
    static func lottiePage(json: String) -> String {
        // The animation's own shape (its w and h), as large as fits up to 360 points tall.
        var aspect = "16 / 9"
        if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let w = object["w"] as? Double, let h = object["h"] as? Double, w > 0, h > 0 {
            aspect = "\(w) / \(h)"
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:#fff}#a{aspect-ratio:\(aspect);max-height:360px;margin:0 auto}</style>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js"></script>
        </head><body><div id="a"></div><script>
        lottie.loadAnimation({container: document.getElementById('a'), renderer: 'svg', loop: true, autoplay: true,
          animationData: \(json)});
        </script></body></html>
        """
    }

    /// The same for a .lottie archive, with the dotLottie player.
    static func dotLottiePage(base64: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:#fff}canvas{width:100%;aspect-ratio:1;max-height:360px;display:block;margin:0 auto;object-fit:contain}</style>
        </head><body><canvas id="c"></canvas><script type="module">
        import { DotLottie } from 'https://cdn.jsdelivr.net/npm/@lottiefiles/dotlottie-web/+esm';
        const bytes = Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0));
        new DotLottie({ canvas: document.getElementById('c'), data: bytes.buffer, loop: true, autoplay: true });
        </script></body></html>
        """
    }
}
