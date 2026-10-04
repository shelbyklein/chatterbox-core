import AppKit
import Observation
import SwiftUI

/// The main window's toolbar, owned by AppKit (#29).
///
/// SwiftUI rebuilds every item of a `.toolbar` — all of them, whichever view declares them —
/// whenever a view with a changed `.id` is replaced anywhere in the window. A chat switch does
/// exactly that, so each switch re-created and re-laid-out about a dozen toolbar items:
/// roughly 300 ms of main-thread work after every switch. Here the items are made once.
/// Plain buttons are native; the menus are SwiftUI, each in a hosting view kept for the
/// window's life that reads the open chat from `ChatToolbarBridge` and updates in place.
/// The window title and which items show are set from the same state.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    private enum ID {
        static let sidebar = NSToolbarItem.Identifier("chatterbox.sidebar")
        static let home = NSToolbarItem.Identifier("chatterbox.home")
        static let commandCenter = NSToolbarItem.Identifier("chatterbox.commandCenter")
        static let settings = NSToolbarItem.Identifier("chatterbox.settings")
        static let newChat = NSToolbarItem.Identifier("chatterbox.newChat")
        static let tone = NSToolbarItem.Identifier("chatterbox.tone")
        static let place = NSToolbarItem.Identifier("chatterbox.place")
        static let repo = NSToolbarItem.Identifier("chatterbox.repo")
        static let golem = NSToolbarItem.Identifier("chatterbox.golem")
        static let remote = NSToolbarItem.Identifier("chatterbox.remote")
        static let images = NSToolbarItem.Identifier("chatterbox.images")
        static let terminal = NSToolbarItem.Identifier("chatterbox.terminal")
        static let all: [NSToolbarItem.Identifier] = [sidebar, home, commandCenter, settings, newChat, .flexibleSpace,
                                                       tone, place, repo, golem, remote, images, terminal]
        static let chat: [NSToolbarItem.Identifier] = [tone, place, repo, golem, remote, images, terminal]
    }

    private let model: AppModel
    private let bridge: ChatToolbarBridge
    private let newStudio: () -> Void
    private let toolbar = NSToolbar(identifier: "chatterbox.main")
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var window: NSWindow?

    #if DEBUG
    /// For tests: every toolbar made, and what each has attached.
    static var made: [WindowToolbar] = []
    var debugState: String { "session=\(bridge.session?.title ?? "nil") installed=\(window?.toolbar === toolbar)" }
    #endif

    init(model: AppModel, bridge: ChatToolbarBridge, newStudio: @escaping () -> Void) {
        self.model = model
        self.bridge = bridge
        self.newStudio = newStudio
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        #if DEBUG
        Self.made.append(self)
        #endif
    }

    /// Puts the toolbar on the window, once, and keeps it current from then on.
    func install(in window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Some SwiftUI pages (Settings' tabs) put a toolbar of their own on the window, which
        // would drop this one; put it back.
        replaced = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, window.toolbar !== self.toolbar else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, window.toolbar !== self.toolbar else { return }
                    window.toolbar = self.toolbar
                    self.apply()
                }
            }
        }
        track()
    }
    private var replaced: NSKeyValueObservation?

    // MARK: - Keeping it current

    /// Re-applies the title, the Home icon and which chat items show whenever what they read changes.
    private func track() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func apply() {
        let session = bridge.session
        let title = model.showingSettings ? "Settings" : model.showingCommandCenter ? "Command Center"
            : model.showingHome ? "Chatterbox" : session?.title ?? "Chatterbox"
        if window?.title != title { window?.title = title }

        if let home = items[ID.home] {
            let back = model.showingHome
            home.image = NSImage(systemSymbolName: back ? "arrow.left" : "house", accessibilityDescription: back ? "Back to Chat" : "Home")
            home.label = back ? "Back to Chat" : "Home"
            home.toolTip = back ? "Return to the open thread" : "Home: full-window thread cards"
        }

        // A chat's own items show only with a chat, and only those that apply to it.
        let repo = session.flatMap { s in GitStatusStore.shared.status(for: s.record.projectFolder)?.remote(preferring: s.record.gitRemote)?.repo }
        let shown: [NSToolbarItem.Identifier: Bool] = [
            ID.tone: session != nil, ID.place: session != nil, ID.repo: repo != nil,
            ID.golem: session?.isDot == true, ID.remote: session?.record.backend == .claude,
            ID.images: session != nil, ID.terminal: session != nil,
        ]
        for (id, visible) in shown { setVisible(id, visible) }
    }

    private func setVisible(_ id: NSToolbarItem.Identifier, _ visible: Bool) {
        guard let item = items[id] else { return }
        if #available(macOS 15.0, *) {
            if item.isHidden == visible { item.isHidden = !visible }
        } else {
            item.isEnabled = visible
            item.view?.isHidden = !visible
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ID.all }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ID.all }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = items[id] { return item }
        let item: NSToolbarItem
        switch id {
        case ID.sidebar:
            item = button(id, "sidebar.left", "Toggle Sidebar", "Show or hide sidebar (\u{2303}\u{2318}S)", #selector(toggleSidebar))
        case ID.home:
            item = button(id, "house", "Home", "Home: full-window thread cards", #selector(toggleHome))
        case ID.commandCenter:
            item = button(id, "rectangle.split.2x2", "Command Center", "Several live chats in one window", #selector(toggleCommandCenter))
        case ID.settings:
            item = button(id, "gearshape", "Settings", "Settings (\u{2318},)", #selector(toggleSettings))
        case ID.newChat:
            item = hosted(id, "New Chat", NewChatMenu(newStudio: newStudio))
        case ID.tone:
            item = hosted(id, "Tone", ToneSlot(bridge: bridge))
        case ID.place:
            item = hosted(id, "Project", PlaceSlot(bridge: bridge))
        case ID.repo:
            item = hosted(id, "Repository", RepoSlot(bridge: bridge))
        case ID.golem:
            item = hosted(id, "Golem", GolemSlot(bridge: bridge))
        case ID.remote:
            item = hosted(id, "Remote Control", RemoteSlot(bridge: bridge))
        case ID.images:
            item = button(id, "photo.on.rectangle.angled", "Images", "Every image made in this chat", #selector(showImages))
        case ID.terminal:
            item = button(id, "terminal", "Terminal", "A terminal in this chat's folder, at the bottom of the window (\u{2303}`)", #selector(toggleTerminal))
        default:
            return nil
        }
        items[id] = item
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ tip: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    /// A SwiftUI control, hosted once for the window's life.
    private func hosted(_ id: NSToolbarItem.Identifier, _ label: String, _ content: some View) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let host = NSHostingView(rootView: AnyView(content.environment(model).fixedSize()))
        host.sizingOptions = [.intrinsicContentSize]
        item.view = host
        item.label = label
        item.paletteLabel = label
        return item
    }

    // MARK: - Actions

    @objc private func toggleSidebar() { model.sidebarToggleRequest += 1 }
    @objc private func toggleHome() { model.showingHome.toggle(); model.showingSettings = false }
    @objc private func toggleCommandCenter() { model.showingCommandCenter.toggle() }
    @objc private func toggleSettings() { model.showingSettings.toggle() }
    @objc private func showImages() { bridge.showImages() }
    @objc private func toggleTerminal() { bridge.toggleTerminal() }
}

/// New Chat: a click starts one; holding opens the choices.
private struct NewChatMenu: View {
    let newStudio: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let studio = model.selected.flatMap(model.studio(for:)), studio.archivedAt == nil {
                Button("New Chat in \u{201C}\(studio.name)\u{201D}") { model.newChat(in: studio) }
                Divider()
            }
            Button("New Claude Chat") { model.newChat(backend: .claude) }
            Button("New Codex Chat") { model.newChat(backend: .codex) }
            Divider()
            Button("New Project\u{2026}") { model.showingNewProject = true }
            Button("Open Project\u{2026}") { model.chooseAndOpenProject() }
            Button("New Project from GitHub\u{2026}") { model.showingCloneFromGitHub = true }
            Divider()
            if !model.activeStudios.isEmpty {
                Menu("New Chat in Studio") {
                    ForEach(model.activeStudios) { studio in
                        Button(studio.name) { model.newChat(in: studio) }
                    }
                }
            }
            Button("New Studio\u{2026}") { newStudio() }
        } label: {
            Image(systemName: "square.and.pencil")
        } primaryAction: {
            model.newChat()
        }
        .menuStyle(.borderlessButton)
        .help("New chat (\u{2318}N). Hold to pick Claude, Codex, or a project folder.")
        .accessibilityLabel("New Chat")
    }
}

/// The window's keyboard shortcuts that used to live on toolbar buttons. Toolbar items aren't
/// in the window's content, so the shortcuts are kept here, on invisible buttons.
struct WindowToolbarShortcuts: View {
    let bridge: ChatToolbarBridge
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Button("Toggle Sidebar") { model.sidebarToggleRequest += 1 }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Terminal") { bridge.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(!bridge.hasChat)
            Button("Issues") { bridge.issuesPanel?.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(bridge.issuesPanel == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
