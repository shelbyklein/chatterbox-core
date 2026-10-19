import AppKit
import SwiftUI

/// Sidebar, transcript and inspector are siblings in one bounded geometry container.
struct ChatColumns: View {
    var sidebar: AnyView?
    var chat: AnyView
    var inspector: AnyView? = nil
    var floatingGolem: AnyView? = nil
    var inspectorMinimum: CGFloat = 260
    var inspectorIdeal: CGFloat = 320
    var inspectorMaximum: CGFloat = 460
    var closeInspector: () -> Void = {}
    /// A right panel drawn inside `chat` (the main window's chat draws its own): sized for
    /// here, so the sidebar makes room for it as it would for one of these columns' own.
    var inspectorReserve: InspectorSize? = nil
    @Environment(AppModel.self) private var model
    /// The sidebar can't be hidden; only a window too narrow for it shows it as a slide-over.
    private let sidebarOpen = true
    @AppStorage("mainSidebarWidth") private var sidebarWidth = 260.0
    @AppStorage("golemInspectorWidth") private var golemWidth = 0.0
    @AppStorage("issuesInspectorWidth") private var issuesWidth = 0.0
    @AppStorage("previewInspectorWidth") private var previewWidth = 0.0
    private var rightMinimum: CGFloat { inspectorReserve?.minimum ?? inspectorMinimum }
    private var rightIdeal: CGFloat { inspectorReserve?.ideal ?? inspectorIdeal }
    private var rightMaximum: CGFloat { inspectorReserve?.maximum ?? inspectorMaximum }
    private var hasRight: Bool { inspector != nil || inspectorReserve != nil }
    private var inspectorWidth: Double {
        get { rightMinimum == 360 ? previewWidth : (rightMinimum == 300 ? issuesWidth : golemWidth) }
        nonmutating set {
            if rightMinimum == 360 { previewWidth = newValue }
            else if rightMinimum == 300 { issuesWidth = newValue }
            else { golemWidth = newValue }
        }
    }
    @AppStorage(Theme.backgroundKey) private var themeBackground = "standard"
    @State private var sidebarOverlay = false
    /// A Studio's sidebar has the Studios down its left as well (see ContentView.sidebarColumn).
    static let studioRailWidth: CGFloat = 160
    private var sidebarExtra: CGFloat { model.showingStudiosSidebar ? Self.studioRailWidth + 1 : 0 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let rightWidth = inspectorWidth > 0 ? inspectorWidth : rightIdeal
            let sizes = ChatColumnWidths(window: width, sidebarOpen: sidebar != nil && sidebarOpen,
                sidebarDesired: sidebarWidth + sidebarExtra, inspectorOpen: hasRight,
                inspectorDesired: min(rightWidth, rightMaximum), inspectorMinimum: rightMinimum,
                sidebarMinimum: 230 + sidebarExtra)
            // A reserved panel is drawn by the chat itself, in the room after its column.
            let chatWidth = inspector == nil && inspectorReserve != nil ? width - sizes.chatX : sizes.chat
            ZStack(alignment: .topLeading) {
                pane(AnyView(ChatSwitchSurface(content: chat)), role: "chat", width: chatWidth, height: geometry.size.height)
                    .offset(x: sizes.chatX)
                if let sidebar, sizes.sidebar > 0 {
                    pane(sidebar, role: "sidebar", width: sizes.sidebar, height: geometry.size.height)
                    handle { delta in sidebarWidth = min(420, max(230, sizes.sidebar - sidebarExtra + delta)) }
                        .offset(x: sizes.sidebar)
                }
                if let inspector, sizes.inspector > 0 {
                    pane(inspector, role: "inspector", width: sizes.inspector, height: geometry.size.height)
                        .offset(x: sizes.inspectorX)
                    handle { delta in inspectorWidth = min(inspectorMaximum, max(inspectorMinimum, sizes.inspector - delta)) }
                        .offset(x: sizes.chatX + sizes.chat)
                }
                if sidebarOverlay, let sidebar {
                    Color.black.opacity(0.22).onTapGesture { sidebarOverlay = false }
                    pane(sidebar, role: "sidebar-overlay", width: min(300 + sidebarExtra, width - 24), height: geometry.size.height)
                        .shadow(radius: 10)
                        .overlay(alignment: .topTrailing) { closeButton { sidebarOverlay = false }.padding(8) }
                } else if sizes.inspectorOverlay, let inspector {
                    // The close button keeps a panel usable even when its toolbar item overflows.
                    pane(inspector, role: "inspector-overlay", width: min(max(inspectorMinimum, rightWidth), width - 32), height: geometry.size.height)
                        .shadow(radius: 10)
                        .overlay(alignment: .topTrailing) { closeButton(action: closeInspector).padding(8) }
                        .offset(x: max(0, width - min(max(inspectorMinimum, rightWidth), width - 32)))
                }
                if let floatingGolem {
                    let anchorWidth = min(max(260, golemWidth > 0 ? golemWidth : 320), width - 32)
                    floatingGolem.frame(width: 120, height: 120)
                        .background(ColumnProbe(role: "floating-golem"))
                        .offset(x: width - anchorWidth / 2 - 60, y: 18)
                        .zIndex(2)
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .onAppear {
                if model.sidebarRevealRequest > 0 && sizes.sidebar == 0 { sidebarOverlay = true }
            }
            .onChange(of: model.sidebarRevealRequest) {
                sidebarOverlay = sizes.sidebar == 0
            }
            .onChange(of: model.sidebarToggleRequest) {
                if width < 636 + sidebarExtra + (hasRight ? rightMinimum + 6 : 0) { sidebarOverlay.toggle() }
                else { sidebarOverlay = false }
            }
            .onChange(of: sizes.sidebar) { _, value in if value > 0 { sidebarOverlay = false } }
        }
    }

    private func pane(_ content: AnyView, role: String, width: CGFloat, height: CGFloat) -> some View {
        content.frame(width: max(0, width), height: max(0, height))
            .clipped()
            .background(Theme.background(themeBackground) ?? Color(nsColor: .windowBackgroundColor))
            .background(ColumnProbe(role: role))
    }
    private func handle(_ resize: @escaping (CGFloat) -> Void) -> some View {
        ColumnResizeHandle(resize: resize)
            .frame(width: ChatColumnWidths.divider)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.08))
            .accessibilityLabel("Resize session column")
            .accessibilityAdjustableAction { direction in resize(direction == .increment ? 20 : -20) }
    }
    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill").font(.title3) }
            .buttonStyle(.plain).help("Close panel").accessibilityLabel("Close panel")
    }
}

/// Native drag handling works without interfering with transcript scrolling or focus.
struct ColumnResizeHandle: NSViewRepresentable {
    var resize: (CGFloat) -> Void
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.resize = resize }
    final class Handle: NSView {
        var resize: ((CGFloat) -> Void)?
        private var lastX: CGFloat = 0
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }
        override func mouseDragged(with event: NSEvent) {
            let delta = event.locationInWindow.x - lastX
            lastX = event.locationInWindow.x
            resize?(delta)
        }
    }
}

/// Native frame probes used by isolated regression tests; no state or user data.
struct ColumnProbe: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.role = role; return view }
    func updateNSView(_ view: Probe, context: Context) { view.role = role }
    final class Probe: NSView { var role = ""; override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}

/// A native hit region remains aligned while the underlying transcript reflows.
struct FloatingGolemHitTarget: NSViewRepresentable {
    var label: String
    var action: () -> Void
    func makeNSView(context: Context) -> HitView { HitView() }
    func updateNSView(_ view: HitView, context: Context) {
        view.action = action
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
    }
    final class HitView: NSView {
        var action: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { action?() }
        override func accessibilityPerformPress() -> Bool { action?(); return true }
    }
}
