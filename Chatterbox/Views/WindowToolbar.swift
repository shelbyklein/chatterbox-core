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
        static let studios = NSToolbarItem.Identifier("chatterbox.studios")
        static let commandCenter = NSToolbarItem.Identifier("chatterbox.commandCenter")
        static let settings = NSToolbarItem.Identifier("chatterbox.settings")
        static let newChat = NSToolbarItem.Identifier("chatterbox.newChat")
        /// Chat view, Studios and Command Center, as one segmented group.
        static let views = NSToolbarItem.Identifier("chatterbox.views")
        /// The window's title, drawn as the first item: macOS leaves a stretchy gap after its own
        /// title, which pushed the view buttons toward the middle.
        static let title = NSToolbarItem.Identifier("chatterbox.title")
        static let pins = NSToolbarItem.Identifier("chatterbox.pins")
        static let remote = NSToolbarItem.Identifier("chatterbox.remote")
        static let images = NSToolbarItem.Identifier("chatterbox.images")
        static let usage = NSToolbarItem.Identifier("chatterbox.usage")
        static let terminal = NSToolbarItem.Identifier("chatterbox.terminal")
        static let finished = NSToolbarItem.Identifier("chatterbox.finished")
        static let automations = NSToolbarItem.Identifier("chatterbox.automations")
        static let feedback = NSToolbarItem.Identifier("chatterbox.feedback")
        /// The views on the left (chat, Studios, Command Center); usage and the terminal; Settings last.
        /// New chats start from the sidebar, the Studios page and Cmd-N, not the toolbar.
        static let all: [NSToolbarItem.Identifier] = [title, views, .flexibleSpace,
                                                       automations, usage, terminal, finished, feedback, .space, settings, newChat]
        static let chat: [NSToolbarItem.Identifier] = [usage, images, terminal]
    }

    private let model: AppModel
    private let bridge: ChatToolbarBridge
    private let toolbar = NSToolbar(identifier: "chatterbox.main")
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Chatterbox")
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Reserve the same title space on every page so navigation never follows the
        // length of a session name or collapses toward the traffic lights on overview pages.
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return label
    }()
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var window: NSWindow?

    #if DEBUG
    /// For tests: every toolbar made, and what each has attached.
    static var made: [WindowToolbar] = []
    static var reinstalls = 0
    var debugState: String { "session=\(bridge.session?.title ?? "nil") installed=\(window?.toolbar === toolbar)" }
    #endif

    init(model: AppModel, bridge: ChatToolbarBridge) {
        self.model = model
        self.bridge = bridge
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
        // The title is the first toolbar item instead (it's still set, for the Window menu).
        window.titleVisibility = .hidden
        // Home's tabs are saved settings: switching them there moves the toolbar's highlight.
        pageObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let page = AppPreferences.defaults.string(forKey: "macHomePage")
                if page != self.lastHomePage { self.lastHomePage = page; self.apply() }
            }
        }
        applyTheme()
        // Some SwiftUI pages (Settings' tabs) put a toolbar of their own on the window, which
        // would drop this one; put it back.
        replaced = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, window.toolbar !== self.toolbar else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, window.toolbar !== self.toolbar else { return }
                    // Never a tug-of-war: if something keeps replacing it, stop for a moment
                    // (a page that wants its own toolbar) rather than freeze the window.
                    let now = Date()
                    self.recentReinstalls = self.recentReinstalls.filter { now.timeIntervalSince($0) < 2 } + [now]
                    guard self.recentReinstalls.count <= 3 else {
                        NSLog("Chatterbox: the window toolbar keeps being replaced; leaving it for now.")
                        return
                    }
                    #if DEBUG
                    Self.reinstalls += 1
                    #endif
                    window.toolbar = self.toolbar
                    self.apply()
                }
            }
        }
        track()
    }
    private var replaced: NSKeyValueObservation?
    private var pageObserver: NSObjectProtocol?
    private var lastHomePage: String?
    private var recentReinstalls: [Date] = []
    private var lastViewCounts: Attention.ViewCounts?
    /// The view button apply() last highlighted; a click changes one, which tells pickView which.
    private var viewIndex = 0
    /// Projects, Studios, Chats, then Command Center. Automations has its own button, on the right.
    private static let viewSymbols = ["folder", "paintpalette", "bubble.left", "rectangle.split.2x2"]
    private static let viewLabels = ["Projects", "Studios", "Chats", "Command Center"]

    /// Fixed-size icons reserve badge space even when the count is zero.
    private static func viewImage(_ symbol: String, count: Int) -> NSImage {
        NSImage(size: NSSize(width: 44, height: 24), flipped: false) { rect in
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
            // Center the base icon in its full slot. The badge overlaps its corner;
            // reserving space only on the right made every unbadged icon look off-center.
            icon?.draw(in: NSRect(x: 13, y: 3, width: 18, height: 18))
            if count > 0 {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: 24, y: 9, width: 16, height: 15)).fill()
                let text = count > 9 ? "9+" : String(count)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.white]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: NSPoint(x: 32 - size.width / 2, y: 16.5 - size.height / 2), withAttributes: attributes)
            }
            return true
        }
    }

    /// The theme's background (Settings → Appearance) behind the toolbar too, as the SwiftUI
    /// toolbar's background used to be; the system's window color for Standard.
    func applyTheme() {
        guard let window else { return }
        if let color = Theme.currentBackground {
            window.backgroundColor = NSColor(color)
            window.titlebarAppearsTransparent = true
        } else {
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
        }
    }

    // MARK: - Keeping it current

    /// Re-applies the title, the Home icon and which chat items show whenever what they read changes.
    private func track() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func apply() {
        let overview = model.showingSettings || model.showingAutomations || model.showingCommandCenter || model.showingHome
        let session = overview ? nil : bridge.session
        let title = model.showingSettings ? "Settings" : model.showingAutomations ? "Automations" : model.showingCommandCenter ? "Command Center"
            : model.showingHome ? "Studios" : model.selected?.title ?? session?.title ?? "Chatterbox"
        if window?.title != title { window?.title = title }
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        titleLabel.toolTip = title
        // SwiftUI turns the system title back on when some pages appear; keep it off.
        if window?.titleVisibility != .hidden { window?.titleVisibility = .hidden }

        // Which of the left-hand views is showing; none while Settings is.
        if let views = items[ID.views] as? NSToolbarItemGroup {
            let index = model.showingSettings || model.showingAutomations ? -1 : model.showingCommandCenter ? 3 : (model.showingHome || model.showingStudiosSidebar) ? 1 : model.showingChatsSidebar ? 2 : 0
            // Set here, one or none (Settings, Automations): a select-one group always keeps one.
            viewIndex = index
            for i in views.subitems.indices where views.isSelected(at: i) != (i == index) { views.setSelected(i == index, at: i) }
            let counts = Attention.shared.viewCounts(in: model)
            if counts != lastViewCounts {
                lastViewCounts = counts
                let values = [counts.projects, counts.studios, counts.chats, 0]
                for (i, subitem) in views.subitems.enumerated() {
                    guard i < 3 else { continue }
                    subitem.image = Self.viewImage(Self.viewSymbols[i], count: values[i])
                    subitem.toolTip = Self.viewLabels[i] + (values[i] > 0 ? " · \(values[i]) sessions need you (unseen replies or pending requests)" : " · Nothing waiting for you")
                }
            }
        }
        let selected = model.showingSettings ? ID.settings : model.showingAutomations ? ID.automations : nil
        if toolbar.selectedItemIdentifier != selected { toolbar.selectedItemIdentifier = selected }

        // Global actions keep their place even when there is no single chat to act on.
        items[ID.terminal]?.isEnabled = session != nil
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ID.all }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ID.all }
    /// The view buttons mark the view that's showing.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [ID.settings, ID.automations] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = items[id] { return item }
        let item: NSToolbarItem
        switch id {
        case ID.sidebar:
            item = button(id, "sidebar.left", "Chats", "The session view with its sidebar; from there, shows or hides the sidebar (\u{2303}\u{2318}S)", #selector(showChats))
        case ID.home:
            item = button(id, "square.grid.2x2", "Home", "Home: your projects, Studios and sessions", #selector(showHome))
        case ID.studios:
            item = button(id, "paintpalette", "Studios", "Your Studios, as thumbnails", #selector(showStudios))
        case ID.commandCenter:
            item = button(id, "rectangle.split.2x2", "Command Center", "Several live sessions in one window", #selector(toggleCommandCenter))
        case ID.feedback:
            item = button(id, "exclamationmark.bubble", "Feedback", "Feedback: annotate a screenshot of this window, then finish your note in the Chatterbox session", #selector(sendFeedback))
        case ID.settings:
            item = button(id, "gearshape", "Settings", "Settings (\u{2318},)", #selector(toggleSettings))
        case ID.title:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = titleLabel
            item.label = "Title"
            item.isBordered = false
        case ID.views:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: Self.viewSymbols.map { Self.viewImage($0, count: 0) },
                                           selectionMode: .selectAny, labels: Self.viewLabels,
                                           target: self, action: #selector(pickView(_:)))
            group.label = "View"
            group.paletteLabel = "View"
            let tips = ["Projects and their sessions", "Your Studios, as thumbnails", "Standalone chat sessions", "Several live sessions in one window"]
            for (sub, tip) in zip(group.subitems, tips) { sub.toolTip = tip }
            group.selectedIndex = 0
            item = group
        case ID.newChat:
            item = button(id, "plus", "New Chat", "Start a new chat (⌘N)", #selector(startNewChat))
        case ID.pins:
            item = hosted(id, "Global Pins", GlobalPinsToolbar())
        case ID.remote:
            item = hosted(id, "Remote Control", RemoteSlot(bridge: bridge))
        case ID.usage:
            item = hosted(id, "Account Usage", ProxyQuotaToolbarButton(bridge: bridge))
        case ID.images:
            item = button(id, "photo.on.rectangle.angled", "Images", "Every image made in this session", #selector(showImages))
        case ID.terminal:
            item = button(id, "terminal", "Terminal", "A terminal in this session's folder, at the bottom of the window (\u{2303}`)", #selector(toggleTerminal))
            // apply() owns availability; AppKit's action-based validation would
            // re-enable this button on overview pages simply because its target exists.
            item.autovalidates = false
        case ID.finished:
            item = hosted(id, "Finished sessions", FinishedChatsBell())
        case ID.automations:
            item = button(id, "clock.arrow.circlepath", "Automations", "All project automations", #selector(toggleAutomations))
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

    @objc private func startNewChat() {
        model.showingChatsSidebar = true
        AppPreferences.defaults.set(false, forKey: "sidebarChatsCollapsed")
        model.showingAutomations = false
        model.showingHome = false
        model.showingCommandCenter = false
        model.showingSettings = false
        model.askNewChat()
        apply()
    }

    @objc private func pickView(_ sender: NSToolbarItemGroup) {
        // The clicked button is the one whose highlight no longer matches; clicking the
        // highlighted one turns it off, so it differs too.
        let clicked = sender.subitems.indices.first { sender.isSelected(at: $0) != ($0 == viewIndex) } ?? viewIndex
        switch clicked {
        case 1:
            model.showView(.studios)
        case 2:
            AppPreferences.defaults.set(false, forKey: "sidebarChatsCollapsed")
            model.showView(.chats)
        case 3:
            model.showingHome = false; model.showingSettings = false; model.showingAutomations = false
            model.showingCommandCenter = true
        default:
            model.showView(.projects)
        }
        apply()
    }

    /// To the chat view; already there in a window too narrow for the sidebar, it slides it over.
    @objc private func showChats() {
        let wasChats = model.showingChatsSidebar || model.studioSidebarID != nil
        model.studioSidebarID = nil
        model.showingChatsSidebar = false
        if model.showingAutomations || model.showingHome || model.showingCommandCenter || model.showingSettings {
            model.showingAutomations = false
            model.showingHome = false; model.showingCommandCenter = false; model.showingSettings = false
        } else if !wasChats {
            model.sidebarToggleRequest += 1
        }
    }
    @objc private func showHome() {
        // Home opens on Projects; Studios has its own button.
        if AppPreferences.defaults.string(forKey: "macHomePage") == "Studios" { AppPreferences.defaults.set("Projects", forKey: "macHomePage") }
        model.showingHome = true
        apply()
    }
    @objc private func showStudios() {
        AppPreferences.defaults.set("Studios", forKey: "macHomePage")
        model.showingHome = true
        apply()
    }
    @objc private func toggleCommandCenter() { model.showingCommandCenter.toggle() }
    @objc private func toggleSettings() { model.showingSettings.toggle() }
    @objc private func sendFeedback() { model.startFeedback(from: toolbar.items.first?.view?.window ?? NSApp.keyWindow ?? NSApp.mainWindow) }
    @objc private func toggleAutomations() { model.showingAutomations.toggle(); apply() }
    @objc private func showImages() { bridge.showImages() }
    @objc private func toggleTerminal() { bridge.toggleTerminal() }
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
