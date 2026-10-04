import AppKit
import SwiftUI
import WebKit

/// What a preview shows: markup from a code block, or a file an agent wrote.
enum PreviewSource: Hashable {
    case html(String)
    case svg(String)
    case file(URL)
}

/// A live, sandboxed preview of HTML or SVG inside a reply. It sizes itself to its content
/// (up to a cap), keeps no cookies or storage, opens links in the browser, and can be
/// captured as an image for review.
struct HTMLPreview: View {
    let source: PreviewSource
    var maxHeight: CGFloat = 640
    @Environment(\.reviewImage) private var review
    @State private var height: CGFloat
    @State private var width: CGFloat = 640
    @State private var snapshotter = Snapshotter()
    /// The web view is made once the chat has settled (see `body`), not while it's opening.
    @State private var live = false

    /// Heights previews last reported, so switching back to a chat reserves the same room.
    @MainActor private static var knownHeights: [PreviewSource: CGFloat] = [:]
    /// How long after appearing a preview starts loading, staggered so several don't all
    /// start in the same frame.
    @MainActor private static var stagger = 0

    init(source: PreviewSource, maxHeight: CGFloat = 640) {
        self.source = source
        self.maxHeight = maxHeight
        _height = State(initialValue: Self.knownHeights[source] ?? 160)
    }

    /// Pages get at least a 16:9 frame so full-window layouts have room; SVGs size to their drawing.
    private var isPage: Bool {
        switch source {
        case .html: return true
        case .svg: return false
        case .file(let url): return url.pathExtension.lowercased() != "svg"
        }
    }

    private var frameHeight: CGFloat {
        let content = min(max(height, 40), max(maxHeight, width * 9 / 16))
        return isPage ? max(content, width * 9 / 16) : content
    }

    var body: some View {
        Group {
            if live {
                WebPreview(source: source, height: $height, snapshotter: snapshotter)
            } else {
                // Same frame as the preview will have, so nothing moves when it arrives.
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
            }
        }
            .frame(maxWidth: .infinity)
            .frame(height: frameHeight)
            .task(id: source) {
                // A chat switch lays out every row at once; making a WKWebView for each preview
                // then is most of what a preview-heavy chat costs to open. Wait for it to settle.
                Self.stagger = (Self.stagger + 1) % 4
                try? await Task.sleep(for: .milliseconds(250 + Self.stagger * 60))
                guard !Task.isCancelled else { return }
                live = true
            }
            .onChange(of: height) { _, new in
                if Self.knownHeights.count > 500 { Self.knownHeights.removeAll() }
                Self.knownHeights[source] = new
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Button { capture() } label: { Label("Review", systemImage: "pencil.and.scribble") }
                        .help("Capture this preview and mark it up")
                    if case .file(let url) = source {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "safari") }
                            .help("Open \(url.lastPathComponent) in your browser")
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
            }
    }

    private func capture() {
        snapshotter.capture { image in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  let attachment = try? Attachments.importImageData(png, name: "Preview") else { return }
            review.open(attachment)
        }
    }
}

/// Lets the SwiftUI view ask its web view for a snapshot.
@MainActor
final class Snapshotter {
    weak var webView: WKWebView?

    func capture(_ done: @escaping (NSImage?) -> Void) {
        guard let webView else { return done(nil) }
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, _ in done(image) }
    }
}

private struct WebPreview: NSViewRepresentable {
    let source: PreviewSource
    @Binding var height: CGFloat
    let snapshotter: Snapshotter

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PreviewContainer {
        let config = WKWebViewConfiguration()
        // Nothing persists between previews, and nothing is shared with the user's browser.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        config.userContentController.addUserScript(WKUserScript(source: Self.sizeReporter, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        snapshotter.webView = webView
        load(into: webView, coordinator: context.coordinator)
        return PreviewContainer(webView: webView)
    }

    func updateNSView(_ container: PreviewContainer, context: Context) {
        guard context.coordinator.loaded != source else { return }
        load(into: container.webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ container: PreviewContainer, coordinator: Coordinator) {
        let webView = container.webView
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    /// Keep WebKit's remote layers and clipping inside an AppKit-owned layer tree.
    /// SwiftUI clipping a bare WKWebView in a scrolling transcript can invalidate the
    /// surrounding renderer on macOS 26, blanking the transcript and even sidebar rows.
    final class PreviewContainer: NSView {
        let webView: WKWebView

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.cgColor
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = source
        switch source {
        case .html(let html):
            webView.loadHTMLString(html, baseURL: nil)
        case .svg(let svg):
            webView.loadHTMLString("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;padding:12px;display:flex;justify-content:center;background:#fff}svg{max-width:100%;height:auto}</style>
            </head><body>\(svg)</body></html>
            """, baseURL: nil)
        case .file(let url):
            // Read access to the file's own folder, so its local images and styles load.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Reports the page's height now and whenever it changes.
    private static let sizeReporter = """
    (function () {
      function report() {
        var h = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
        window.webkit.messageHandlers.size.postMessage(h);
      }
      report();
      if (window.ResizeObserver) { new ResizeObserver(report).observe(document.documentElement); }
      window.addEventListener('load', report);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var loaded: PreviewSource?

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value > 0 else { return }
            let new = CGFloat(value)
            if abs(new - height.wrappedValue) > 1 {
                DispatchQueue.main.async { self.height.wrappedValue = new }
            }
        }

        /// The first load stays in the preview; clicked links open in the default browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else if action.targetFrame == nil, let url = action.request.url {
                // target="_blank" and window.open.
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
