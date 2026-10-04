import AppKit
import Observation
import SwiftUI
import WebKit

/// A website open inside Chatterbox (from a pin). It takes the chat's place, and the chat
/// floats in the corner so the conversation can go on with the page up. Sites keep their
/// cookies, so a login sticks the way it would in a browser.
@MainActor
@Observable
final class WebPage {
    private(set) var url: URL
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    @ObservationIgnored fileprivate weak var webView: WKWebView?

    init(url: URL) { self.url = url }

    func load(_ url: URL) {
        self.url = url
        if let webView { Self.open(url, in: webView) }
    }

    /// A file on the Mac gets to read its own folder (its images, scripts, styles).
    fileprivate static func open(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    fileprivate func update(from webView: WKWebView) {
        if let current = webView.url, current != url { url = current }
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }
}

/// The page with a slim bar above it: back, forward, reload, the address, open in the
/// browser, and close (which brings the chat back).
struct WebPaneView: View {
    let page: WebPage
    let onClose: () -> Void
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: page.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!page.canGoBack).help("Back")
                Button(action: page.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!page.canGoForward).help("Forward")
                Button(action: page.reload) { Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise") }
                    .help("Reload")
                TextField("Address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($editingAddress)
                    .onSubmit {
                        if let url = PinStore.normalizedURL(address) { page.load(url) }
                        editingAddress = false
                    }
                Button { NSWorkspace.shared.open(page.url) } label: { Image(systemName: "safari") }
                    .help("Open in your browser")
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .help("Close the page and go back to the chat")
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            WebPageView(page: page)
        }
        .onAppear { address = page.url.absoluteString }
        .onChange(of: page.url) { _, url in if !editingAddress { address = url.absoluteString } }
    }
}

private struct WebPageView: NSViewRepresentable {
    let page: WebPage

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Some sites turn away browsers they don't recognize.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)
        page.webView = webView
        WebPage.open(page.url, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // A different page (another pin) replaces this one.
        if context.coordinator.page !== page {
            context.coordinator.page = page
            page.webView = webView
            WebPage.open(page.url, in: webView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var page: WebPage
        private var observations: [NSKeyValueObservation] = []

        init(page: WebPage) { self.page = page }

        func observe(_ webView: WKWebView) {
            let changed: (WKWebView) -> Void = { [weak self] view in MainActor.assumeIsolated { self?.page.update(from: view) } }
            observations = [
                webView.observe(\.url) { view, _ in changed(view) },
                webView.observe(\.title) { view, _ in changed(view) },
                webView.observe(\.canGoBack) { view, _ in changed(view) },
                webView.observe(\.canGoForward) { view, _ in changed(view) },
                webView.observe(\.isLoading) { view, _ in changed(view) },
            ]
        }

        // Links that would open a new window open here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        // Files the page can't show (a PDF download, a zip) open in their own app.
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            if !response.canShowMIMEType, let url = response.response.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { page.update(from: webView) }
    }
}

private struct CompactChatKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The chat is the small one floating over a page: fewer controls, tighter margins.
    var compactChat: Bool {
        get { self[CompactChatKey.self] }
        set { self[CompactChatKey.self] = newValue }
    }
}

/// The chat, small, in the corner over a page. It can shrink to a round bubble, or go
/// back to full size (which closes the page).
struct FloatingChat: View {
    let session: ChatSession
    let onExpand: () -> Void
    /// The bubble's symbol (Dot has its own).
    var icon = "bubble.left.and.bubble.right.fill"
    @AppStorage private var collapsed: Bool
    private let appearance = ReaderStyleSettings()

    /// `storageKey` remembers whether this one is shrunk to its bubble.
    init(session: ChatSession, icon: String = "bubble.left.and.bubble.right.fill", storageKey: String = "floatingChatCollapsed",
         onExpand: @escaping () -> Void) {
        self.session = session
        self.icon = icon
        self.onExpand = onExpand
        _collapsed = AppStorage(wrappedValue: false, storageKey)
    }

    var body: some View {
        if collapsed {
            bubble
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(session.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button { collapsed = true } label: { Image(systemName: "minus") }
                        .help("Shrink the chat")
                    Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Close the page and show the chat full size")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
                ChatView(session: session)
                    .id(session.id)
                    .environment(\.compactChat, true)
            }
            .frame(width: 400, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        }
    }

    /// The chat shrunk to a round bubble. It shows when the agent is working, and turns
    /// yellow when it's waiting on you.
    @ViewBuilder
    private var bubble: some View {
        #if GOLEM_APP
        if session.isDot, GolemAvatar.shared.hasAnimations {
            golemBubble
        } else {
            roundBubble
        }
        #else
        roundBubble
        #endif
    }

    /// Golem himself stands in for the bubble: thinking while he works, perking up with news,
    /// a count of unread replies, and a yellow ring when something waits on you.
    #if GOLEM_APP
    private var golemBubble: some View {
        let unread = Attention.shared.dotUnreadCount(session)
        return Button { collapsed = false } label: {
            GolemAnimated(mood: GolemAvatar.mood(of: session))
                .frame(width: 84, height: 84)
                .background(Circle().fill(session.isWaitingOnYou ? Color.yellow.opacity(0.18) : .clear).padding(6))
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.onHighlight)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.highlight))
                            .offset(x: -6, y: 8)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.isWaitingOnYou ? "\(session.title) is waiting on you"
              : unread > 0 ? "\(unread) new from \(session.title)" : "Show \(session.title)")
    }

    #endif
    private var roundBubble: some View {
        let color = appearance.style.color(for: session.record.backend)
        return Button { collapsed = false } label: {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().strokeBorder(session.isWaitingOnYou ? Color.yellow : Color.primary.opacity(0.15),
                                      lineWidth: session.isWaitingOnYou ? 2 : 1)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                if session.isRunning {
                    ActivitySpinner(color: color).frame(width: 12, height: 12)
                        .offset(x: 17, y: -17)
                }
            }
            .frame(width: 52, height: 52)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(session.isWaitingOnYou ? "\(session.title) is waiting on you" : "Show the chat: \(session.title)")
    }
}
