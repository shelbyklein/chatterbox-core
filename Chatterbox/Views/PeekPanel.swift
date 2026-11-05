import AppKit
import SwiftUI

// The peek view (plans/work-threads.md, "Next: peek at a work thread in the thread sidebar"):
// on the Mac, clicking a work thread or a sidechat from its front thread (its Work chips, the
// links in its transcript, the thread sidebar's Task & work) doesn't replace the view. It opens
// in the right-hand sidebar column beside the conversation, live: its status, transcript,
// approvals and its own composer, with Open in Full, and Back (or Esc) to return the column to
// About this thread. Several open as tabs. Nothing opens when a work thread is made, only on a
// click. The front thread stays readable and typeable beside it (on a window too narrow for
// both, the column slides over the right side instead). The Desk's Open and the session list
// still open the full view (`model.selectedID`).

/// Each front thread's open peeks: its tabs, in the order they were opened, and the one shown.
/// Kept for the app's run, so a front thread shows its peeks again when you come back to it.
@MainActor @Observable final class PeekStore {
    static let shared = PeekStore()

    struct Panel: Equatable {
        var tabs: [UUID] = []
        var selected: UUID?
    }
    private(set) var panels: [UUID: Panel] = [:]

    func panel(of front: UUID) -> Panel { panels[front] ?? Panel() }

    /// Opens `id` beside `front`, as a new tab or the one already open, and shows it.
    func open(_ id: UUID, in front: UUID) {
        var panel = panel(of: front)
        if !panel.tabs.contains(id) { panel.tabs.append(id) }
        panel.selected = id
        panels[front] = panel
    }

    func select(_ id: UUID, in front: UUID) {
        guard panels[front]?.tabs.contains(id) == true else { return }
        panels[front]?.selected = id
    }

    /// Closes one tab; the one beside it is shown, or the column goes back to About when it was the last.
    func close(_ id: UUID, in front: UUID) {
        guard var panel = panels[front], let index = panel.tabs.firstIndex(of: id) else { return }
        panel.tabs.remove(at: index)
        if panel.selected == id { panel.selected = panel.tabs.isEmpty ? nil : panel.tabs[min(index, panel.tabs.count - 1)] }
        panels[front] = panel.tabs.isEmpty ? nil : panel
    }

    /// Back to About: every tab closes.
    func closeAll(in front: UUID) { panels[front] = nil }
}

extension AppModel {
    /// Opens `id` in the peek panel beside the front thread `front` (plans/work-threads.md). A
    /// thread that isn't here, or the front thread itself, opens the ordinary way.
    func peek(_ id: UUID, from front: UUID) {
        guard id != front, sessions.contains(where: { $0.id == id }) else { selectedID = id; return }
        PeekStore.shared.open(id, in: front)
    }

    /// Shows a peeked thread full size, in place of its front thread; its tab closes.
    func openPeekInFull(_ id: UUID, from front: UUID) {
        PeekStore.shared.close(id, in: front)
        selectedID = id
    }
}

#if DEBUG
/// Frames for the Mac render test (tests/mac-desk): "peekColumn", "peekTab:<id>", "peekOpenFull",
/// "peekBack", "peekFront" (the front thread's chat, beside or under the column).
@MainActor enum PeekDebug {
    static var frames: [String: CGRect] = [:]
}
#endif

private extension View {
    func peekFrame(_ key: String) -> some View {
        #if DEBUG
        return onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PeekDebug.frames[key] = $0 }
        #else
        return self
        #endif
    }
}

extension View {
    /// The front thread's chat, with the peek view in a column on its right (ChatView).
    func peekPanel(front: ChatSession, enabled: Bool) -> some View {
        modifier(PeekPanelHost(front: front, enabled: enabled))
    }
}

/// Puts the peek column beside the front thread's chat, or over its right side when the window
/// is too narrow for both, and handles Esc and which of the two has the keyboard.
struct PeekPanelHost: ViewModifier {
    let front: ChatSession
    let enabled: Bool
    @Environment(AppModel.self) private var model
    private let store = PeekStore.shared
    @State private var width: CGFloat = 1200
    /// The peek has the keyboard's chat shortcuts after a click in it, the front thread after a
    /// click outside it.
    @State private var peekFocused = false
    @State private var columnFrame: CGRect = .zero
    @State private var monitor: Any?
    @State private var window = WindowReference()

    /// Wider than About's 288: a live transcript and composer need the room.
    static let columnWidth: CGFloat = 440
    /// The front thread keeps at least this much beside the column, or the column slides over it.
    static let frontMinimum: CGFloat = ChatView.minWidth + 80

    /// The tabs still open (a thread deleted meanwhile drops out), and the one shown.
    private var open: (tabs: [ChatSession], shown: ChatSession)? {
        guard enabled else { return nil }
        let panel = store.panel(of: front.id)
        let tabs = panel.tabs.compactMap { id in model.sessions.first { $0.id == id } }
        guard let shown = tabs.first(where: { $0.id == panel.selected }) ?? tabs.first else { return nil }
        return (tabs, shown)
    }
    private var docked: Bool { width >= Self.columnWidth + 1 + Self.frontMinimum }

    func body(content: Content) -> some View {
        let open = open
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .peekFrame("peekFront")
            if let open, docked {
                Divider()
                column(open)
            }
        }
        .overlay(alignment: .trailing) {
            if let open, !docked {
                column(open)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .shadow(radius: 10)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.2), value: open?.tabs.map(\.id))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(WindowReader(reference: window))
        .onChange(of: open != nil, initial: true) { _, isOpen in
            if isOpen { install() } else { remove(); peekFocused = false }
        }
        .onDisappear(perform: remove)
    }

    private func column(_ open: (tabs: [ChatSession], shown: ChatSession)) -> some View {
        PeekColumn(front: front, tabs: open.tabs, shown: open.shown, focused: peekFocused, focus: { peekFocused = true })
            .frame(width: docked ? Self.columnWidth : min(Self.columnWidth, max(320, width - 40)))
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { columnFrame = $0 }
    }

    private func install() {
        guard monitor == nil else { return }
        let front = front
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in handle(event, front: front) }
    }
    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, front: ChatSession) -> NSEvent? {
        guard let window = window.window, event.window === window, let open else { return event }
        switch event.type {
        case .leftMouseDown:
            // SwiftUI's global frames are the window's content, from its top left.
            let height = window.contentView?.bounds.height ?? window.frame.height
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            peekFocused = columnFrame.contains(point)
            return event
        case .keyDown:
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  window.attachedSheet == nil else { return event }
            // A find bar or another field takes its own Esc; so does a reply that Esc stops, and
            // a "/" menu that Esc closes, in whichever thread has the keyboard.
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return event }
            let active = peekFocused ? open.shown : front
            if active.canStop || active.draft.hasPrefix("/") { return event }
            store.closeAll(in: front.id)
            return nil
        default:
            return event
        }
    }
}

/// The peek column: Back, the tabs and Open in Full across the top, the shown thread's status,
/// and the thread itself, live (its transcript, approvals and composer).
private struct PeekColumn: View {
    let front: ChatSession
    let tabs: [ChatSession]
    let shown: ChatSession
    let focused: Bool
    let focus: () -> Void
    @Environment(AppModel.self) private var model
    private let store = PeekStore.shared
    private let appearance = ReaderStyleSettings()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { store.closeAll(in: front.id) } label: {
                    Label("Back", systemImage: "chevron.backward").labelStyle(.iconOnly)
                }
                .help("Back to About this thread (Esc). The threads stay where they were.")
                .accessibilityLabel("Back")
                .accessibilityIdentifier("peekBack")
                .peekFrame("peekBack")
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            PeekTab(session: tab, selected: tab.id == shown.id, closeOnly: tabs.count == 1,
                                    select: { store.select(tab.id, in: front.id) },
                                    close: { store.close(tab.id, in: front.id) })
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
                Button { model.openPeekInFull(shown.id, from: front.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open \u{201C}\(shown.title)\u{201D} in full, in place of this thread")
                .accessibilityLabel("Open in Full")
                .accessibilityIdentifier("peekOpenFull")
                .peekFrame("peekOpenFull")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.bar)
            Divider()
            PeekStatus(session: shown)
            Divider()
            ChatView(session: shown)
                .id(shown.id)
                .environment(\.compactChat, true)
                .environment(\.commandCenterTile, CommandCenterTileContext(isActive: focused, activate: focus))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            // Which one has the keyboard: a line in the thread's colour while it's the peek.
            if focused { Rectangle().fill(appearance.style.agentColor(for: shown)).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .peekFrame("peekColumn")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peek: \(shown.title)")
        .accessibilityIdentifier("peekColumn")
    }
}

/// One tab: the thread's state and name; its close button shows on the selected or hovered tab.
private struct PeekTab: View {
    let session: ChatSession
    let selected: Bool
    /// The only tab: no close of its own (Back does it).
    let closeOnly: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        let state = WorkThreadState(session)
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: state.icon).foregroundStyle(state.color).font(.caption)
                    Text(session.title).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
                        .frame(maxWidth: closeOnly ? 260 : 150, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(session.title): \(state.label)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("\(session.title), \(state.label)")
            .peekFrame("peekTab:\(session.id)")
            if !closeOnly && (selected || hovered) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Close this tab")
                    .accessibilityLabel("Close \(session.title)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.11 : hovered ? 0.06 : 0)))
        .onHover { hovered = $0 }
    }
}

/// Under the tabs: where the shown thread stands (Working and its step, Needs you, Ready, Done),
/// its agent, and for a work thread whom it reports to.
private struct PeekStatus: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = WorkThreadState(session)
        let step = state == .working ? session.lastActionSummary.map { DeskStore.short($0, limit: 120) } : nil
        let kind = session.isWorkThread ? "Work thread" : session.isSidequest ? "Sidequest" : "Sidechat"
        HStack(spacing: 6) {
            if state == .working { ProgressView().controlSize(.mini) } else { Image(systemName: state.icon).foregroundStyle(state.color) }
            Text(state.label).fontWeight(.semibold)
            Text(step ?? "\(kind) \u{00B7} \(session.record.backend.label)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(state == .needsYou ? Color.attention.opacity(0.12) : Color.primary.opacity(0.03))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("peekStatus")
    }
}

/// The window the host is in, for its event monitor.
private final class WindowReference { weak var window: NSWindow? }

private struct WindowReader: NSViewRepresentable {
    let reference: WindowReference
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.reference = reference; return view }
    func updateNSView(_ view: Probe, context: Context) { view.reference = reference; reference.window = view.window }
    final class Probe: NSView {
        var reference: WindowReference?
        override func viewDidMoveToWindow() { reference?.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
