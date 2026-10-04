import SwiftUI
import UIKit
import WebKit

/// What a preview shows: markup from a code block, or a page an agent wrote (fetched from
/// the Mac as text).
enum PreviewSource: Equatable {
    case html(String)
    case svg(String)
    case file(URL)
}

/// The iPhone and iPad version of the Mac's live preview: HTML or SVG in a reply, sandboxed,
/// keeping no cookies or storage, and opening links in Safari. Pages get at least a 16:9
/// frame; SVGs size to their drawing.
struct HTMLPreview: View {
    let source: PreviewSource
    var maxHeight: CGFloat = 640
    @State private var height: CGFloat = 160
    @State private var width: CGFloat = 360

    private var isPage: Bool {
        if case .svg = source { return false }
        return true
    }

    private var frameHeight: CGFloat {
        let content = min(max(height, 40), max(maxHeight, width * 9 / 16))
        return isPage ? max(content, width * 9 / 16) : content
    }

    var body: some View {
        PreviewWebView(source: source, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: frameHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct PreviewWebView: UIViewRepresentable {
    let source: PreviewSource
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing persists between previews, and nothing is shared with Safari.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        config.userContentController.addUserScript(WKUserScript(source: Self.sizeReporter, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // The chat scrolls; the preview inside it doesn't.
        webView.scrollView.isScrollEnabled = false
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loaded != source else { return }
        load(into: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = source
        switch source {
        case .html(let html):
            webView.loadHTMLString(Self.fittingPhone(html), baseURL: nil)
        case .svg(let svg):
            webView.loadHTMLString("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;padding:12px;display:flex;justify-content:center;background:#fff}svg{max-width:100%;height:auto}</style>
            </head><body>\(svg)</body></html>
            """, baseURL: nil)
        case .file(let url):
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Without a viewport, iOS lays a page out at desktop width and shrinks it to fit, so a
    /// snippet comes out tiny in a tall blank frame. This lays it out at the phone's width.
    static func fittingPhone(_ html: String) -> String {
        guard html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil,
              html.range(of: "name='viewport'", options: .caseInsensitive) == nil else { return html }
        let meta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        if let head = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: head, with: "<head>" + meta)
        }
        return meta + html
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

        /// The first load stays in the preview; tapped links open in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if (action.navigationType == .linkActivated || action.targetFrame == nil), let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
