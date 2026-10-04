import AppKit
import SwiftUI

struct PreviewLink: Identifiable {
    let url: URL
    var id: URL { url }
}

enum PreviewDestination: String, CaseIterable, Identifiable {
    case sidebar, fullScreen, window, chrome, chromium, safari
    var id: Self { self }
    var title: String {
        switch self {
        case .sidebar: "Sidebar"
        case .fullScreen: "Full Screen"
        case .window: "New Chatterbox Window"
        case .chrome: "Open in Chrome"
        case .chromium: "Open in Chromium"
        case .safari: "Open in Safari"
        }
    }
    var icon: String {
        switch self {
        case .sidebar: "sidebar.right"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .window: "macwindow"
        default: "globe"
        }
    }
    var bundleID: String? {
        switch self {
        case .chrome: "com.google.Chrome"
        case .chromium: "org.chromium.Chromium"
        case .safari: "com.apple.Safari"
        default: nil
        }
    }
    var application: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
    var available: Bool { bundleID == nil || application != nil }
    var detail: String {
        switch self {
        case .sidebar: "Beside this chat"
        case .fullScreen: "A full-screen preview window"
        case .window: "A separate resizable preview"
        default: available ? "Outside Chatterbox" : "Not installed on this Mac"
        }
    }
}

/// No WebPage/WKWebView here: presenting choices must not load the linked page.
struct PreviewDestinationChooser: View {
    let url: URL
    let choose: (PreviewDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open preview").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Cancel")
            }
            Text(url.isFileURL ? url.lastPathComponent : url.absoluteString)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ForEach(PreviewDestination.allCases) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.icon).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!option.available)
                .accessibilityLabel(option.title).accessibilityHint(option.detail)
            }
        }
        .padding(20).frame(width: 420)
    }
}

/// Separate windows are created only after a destination is selected.
@MainActor final class BrowserPreviewWindows: NSObject, NSWindowDelegate {
    static let shared = BrowserPreviewWindows()
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    func open(_ url: URL, fullScreen: Bool) {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1100, frame.width), height: min(800, frame.height)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = url.isFileURL ? url.lastPathComponent : "Preview"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = NSHostingView(rootView: WebPaneView(page: WebPage(url: url)) { [weak window] in window?.close() })
        windows[ObjectIdentifier(window)] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        if fullScreen { window.toggleFullScreen(nil) }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeValue(forKey: ObjectIdentifier(window))
    }
}
