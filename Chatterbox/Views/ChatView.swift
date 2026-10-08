import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model
    /// The small chat floating over a page: fewer controls, tighter margins.
    @Environment(\.compactChat) private var compact
    @Environment(\.commandCenterTile) private var tileContext
    private var tileActive: Bool { tileContext?.isActive ?? true }
    private var handlesKeyboard: Bool { tileActive && NSApp.keyWindow?.windowNumber == windowNumber }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.chatSwitchCoordinator) private var switchCoordinator
    private var switchingChats: Bool { switchCoordinator?.switching ?? false }
    let session: ChatSession
    /// The message box's text and attachments. Typing stays in this view; each change is
    /// copied to the chat (ChatSession.draft), so it's still there after looking at another
    /// chat. Binding the field to the chat itself redrew the whole chat on every keystroke,
    /// which garbled wrapped lines.
    @State private var draft: String
    @State private var attachments: [Attachment]

    private let sidebar: AnyView?
    private let standaloneWindow: Bool

    init(session: ChatSession, sidebar: AnyView? = nil, standaloneWindow: Bool = false) {
        self.standaloneWindow = standaloneWindow
        self.sidebar = sidebar
        self.session = session
        _draft = State(initialValue: session.draft)
        _attachments = State(initialValue: session.draftAttachments)
    }
    private var inspectorOpen: Bool { issuesPanel.isOpen || preview != nil || (session.isDot && golemPanelOpen) }
    private func closeInspector() {
        issuesPanel.isOpen = false; preview = nil
        if session.isDot { golemPanelOpen = false }
    }
    @ViewBuilder private var inspectorContent: some View {
        if let preview {
            WebPaneView(page: preview) { self.preview = nil }
        } else if issuesPanel.isOpen || !session.isDot {
            IssuesPanel(session: session, panel: issuesPanel)
        } else {
            #if GOLEM_APP
            GolemSidePanel(session: session, showsAvatar: false)
            #else
            EmptyView()
            #endif
        }
    }
    #if GOLEM_APP
    private var floatingGolem: some View {
        Group {
            if GolemAvatar.shared.hasAnimations && !model.showingDot { GolemAnimated(mood: GolemAvatar.mood(of: session)) }
            else { GolemHead(size: 40) }
        }
        .frame(width: 120, height: 120)
        .overlay {
            FloatingGolemHitTarget(label: golemPanelOpen ? "Hide Golem activity" : "Show Golem activity") {
                golemPanelOpen.toggle()
            }
        }
        .help(golemPanelOpen ? "Hide activity, decisions and schedule" : "Show activity, decisions and schedule")
    }

    #else
    private var floatingGolem:some View {EmptyView()}
    #endif
    private var chatContent: some View {
        VStack(spacing: 0) {
            if session.record.archivedAt != nil { archivedBanner }
            if session.record.backend == .claude, let status = ClaudeModels.shared.statusMessage { claudeBanner(status) }
            if session.record.backend == .codex, let status = CodexAppServer.shared.statusMessage { claudeBanner(status) }
            if find.isOpen { ChatFindBar(find: find) }
            transcript
            ThreadRestartStatus(session: session).padding(.horizontal, 20)
            if let stopStatus { Text(stopStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
            composer
            if showingTerminal {
                TerminalPanel(session: session, onClose: { showingTerminal = false }, pending: $terminalCommand)
            }
        }
        .overlay(alignment: .topLeading) {
            if !compact && tileContext == nil && !session.isDot {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 8) {
                        ChatNotes(scope: PinnedNotesStore.scope(for: session.record), project: session.record.projectFolder != nil,
                                  panelWidth: min(280, max(220, (geometry.size.width - appearance.style.contentWidth) / 2 - 32)))
                            .id(PinnedNotesStore.scope(for: session.record))
                        ChatQuickActions(session: session)
                    }
                    .padding(16)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsPins {
                GeometryReader { geometry in
                    ChatPins(chat: session.record.id, agentName: session.record.backend == .codex ? "Codex" : "Claude",
                             panelWidth: min(280, max(220, (geometry.size.width - appearance.style.contentWidth) / 2 - 32))) { pinJump = $0 }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(16)
                }
            }
        }
    }

    /// Pinned messages show only in the full chat view, not tiles, compact windows or Dot.
    private var showsPins: Bool { !compact && tileContext == nil && !session.isDot }
    /// A pin that was clicked: the transcript goes to its message.
    @State private var pinJump: UUID?
    /// The message a pin just went to, highlighted for a moment.
    @State private var flashedID: UUID?

    @State private var stopStatus: String?
    @State private var requestingStop = false
    @State private var attachError: String?
    @State private var isDropTargeted = false
    @State private var pasteMonitor: Any?
    @State private var windowNumber: Int?
    @State private var projectConflict: ChatSession?
    @State private var reviewing: Attachment?
    @State private var showingImages = false
    @Environment(\.chatToolbarBridge) private var windowToolbar
    /// A window without its own chat toolbar (no ContentView) still gets the controls.
    @State private var ownToolbar = ChatToolbarBridge()
    @State private var toolbarOwner = UUID()
    @State private var showingTerminal = false
    @State private var terminalCommand: String?
    @AppStorage("terminalPanelHeight") private var terminalHeight = 260.0
    @State private var viewingDocument: LocalDocument?
    @State private var commandIndex = 0
    /// The draft at which the user pressed Esc on the "/" menu, so it stays closed for that text.
    @State private var dismissedCommandDraft: String?
    private let commands = ChatCommands.shared
    /// The Issues panel on the right (see IssuesPanel.swift).
    @State private var issuesPanel = IssuesPanelState()
    /// Golem's chat: the column with his activity, decisions and schedule.
    @AppStorage("golemActivityExpanded") private var golemPanelOpen = false
    /// A page or file from the chat, open in the browser panel on the right.
    @State private var preview: WebPage?
    @State private var previewLink: PreviewLink?
    @State private var selectedPreview: (URL, PreviewDestination)?
    @State private var previewOpenError: String?
    /// How many of the newest rows to draw; "Show earlier" adds a page at a time.
    /// A chat opens with `firstRows` so it appears at once, then fills in to `rowPage`.
    @State private var shownRowCount = ChatView.firstRows
    /// ⌘F: searching this chat (ChatFind.swift).
    @State private var find = ChatFind()
    /// Messages around a match far back in the history, drawn in place of the latest ones.
    @State private var findWindow: Range<Int>?
    static let rowPage = 40
    static let firstRows = 12
    /// Step groups you've opened.
    @State private var openStepGroups: Set<UUID> = []
    /// The "Show earlier" count, kept until the history grows (see earlierRowCount).
    @State private var earlierCountCache = EarlierCount()
    @AppStorage("readerGroupSteps") private var groupSteps = true
    @State private var composerFocused = false
    /// The chat's height, so the message box can grow to a good share of it before scrolling.
    @State private var chatHeight: CGFloat = 600
    private let appearance = ReaderStyleSettings()

    /// The narrowest the chat column goes. Nothing inside asks for more (the message box and
    /// the model line truncate instead), so the sidebar and inspector are never pushed out
    /// of the window.
    static let minWidth: CGFloat = 400

    var body: some View {
        Group {
            if sidebar != nil || standaloneWindow {
                ChatColumns(sidebar: sidebar, chat: AnyView(chatContent),
                    inspector: inspectorOpen ? AnyView(inspectorContent) : nil,
                    floatingGolem: session.isDot ? AnyView(floatingGolem) : nil,
                    inspectorMinimum: preview != nil ? 360 : (session.isDot && !issuesPanel.isOpen ? 260 : 300),
                    inspectorIdeal: preview != nil ? 620 : (session.isDot && !issuesPanel.isOpen ? 320 : 380),
                    inspectorMaximum: preview != nil ? 1400 : (session.isDot && !issuesPanel.isOpen ? 460 : 640),
                    closeInspector: closeInspector)
            } else if tileContext != nil {
                ChatColumns(chat: AnyView(chatContent), inspector: preview != nil ? AnyView(inspectorContent) : nil,
                            inspectorMinimum: 360, inspectorIdeal: 420, inspectorMaximum: 640, closeInspector: closeInspector)
            } else { chatContent }
        }
        // The title and toolbar are the window's (see ChatToolbar.swift): this chat only tells
        // it what's open. Any toolbar or title modifier in here would make SwiftUI rebuild the
        // whole toolbar each time a chat replaces this view.
        .modifier(OwnChatToolbar(enabled: tileContext == nil && windowToolbar == nil, bridge: ownToolbar))
        .modifier(ChatWindowTitle(title: session.title, embedded: tileContext != nil || windowToolbar != nil))
        .onAppear {
            if standaloneWindow && session.isDot { golemPanelOpen = true }
            attachToolbar()
            if Attention.shared.isWatching(session) { Attention.shared.markSeen(session.id) }
        }
        .onChange(of: model.showingDot) { _, miniVisible in
            if standaloneWindow && session.isDot && !miniVisible { golemPanelOpen = true }
        }
        .onDisappear { (windowToolbar ?? ownToolbar).detach(owner: toolbarOwner) }
        .background(ChatWindowReader { windowNumber = $0.windowNumber })
        .modifier(FindShortcut(find: find, session: session, enabled: tileContext == nil))
        // Agents often link files by bare path ("/Users/…/Print.pdf"), which macOS can't open as a URL.
        .environment(\.chatFolder, session.workingFolder)
        .environment(\.runInTerminal) { command in
            terminalCommand = command
            withAnimation(.smooth(duration: 0.25)) { showingTerminal = true }
        }
        .environment(\.openURL, OpenURLAction { url in
            let file: URL
            if url.scheme == PathLinks.scheme {
                let path = URL(fileURLWithPath: url.path)
                if !LocalDocument.supports(path), !["html", "htm", "svg"].contains(path.pathExtension.lowercased()),
                   !NSEvent.modifierFlags.contains(.command) {
                    PathLinks.reveal(url)
                    return .handled
                }
                file = path
            } else {
                if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !NSEvent.modifierFlags.contains(.command) {
                    previewLink = PreviewLink(url: url)
                    return .handled
                }
                guard let resolved = FileLink.resolve(url, in: session.workingFolder) else { return .systemAction }
                file = resolved
            }
            // Documents use a large sheet; Command-click retains external opening.
            if LocalDocument.supports(file), !NSEvent.modifierFlags.contains(.command) {
                viewingDocument = LocalDocument(url: file)
                return .handled
            }
            // Web pages and SVGs keep their live browser preview.
            if ["html", "htm", "svg"].contains(file.pathExtension.lowercased()), !NSEvent.modifierFlags.contains(.command) {
                previewLink = PreviewLink(url: file)
                return .handled
            }
            NSWorkspace.shared.open(file)
            return .handled
        })
        .sheet(item: $previewLink, onDismiss: openSelectedPreview) { link in
            PreviewDestinationChooser(url: link.url) { destination in
                selectedPreview = (link.url, destination)
                previewLink = nil
            }
        }
        .alert("Couldn't open preview", isPresented: Binding(get: { previewOpenError != nil }, set: { if !$0 { previewOpenError = nil } })) {
            Button("OK") { previewOpenError = nil }
        } message: { Text(previewOpenError ?? "") }
        .onChange(of: issuesPanel.isOpen) { _, open in if open { preview = nil } }
        // Re-read git when the chat opens, its folder changes, or a turn ends (the agent may have committed).
        .task(id: "\(session.record.projectFolder ?? "")|\(session.isRunning)") {
            guard let folder = session.record.projectFolder, !session.isRunning else { return }
            await GitStatusStore.shared.refresh(folder)
            session.updateGitHubRepo(from: GitStatusStore.shared.status(for: folder))
        }
        .task(id: session.record.backend == .codex ? session.record.codex?.folder : nil) {
            if session.record.backend == .codex, let folder = session.record.codex?.folder {
                await CodexAppServer.shared.refreshSkills(for: folder)
            }
        }
        .onAppear {
            composerFocused = !switchingChats && tileActive
            installPasteMonitor()
        }
        .onChange(of: switchingChats) { _, switching in composerFocused = !switching && tileActive }
        .onChange(of: tileActive) { _, active in if !active { composerFocused = false } }
        .onChange(of: composerFocused) { _, focused in if focused { tileContext?.activate() } }
        .onChange(of: draft) { _, text in session.draft = text }
        #if GOLEM_APP
        .modifier(GolemVoiceDraftSync(session: session, draft: $draft, attachments: $attachments))
        #endif
        .onChange(of: attachments) { _, files in session.draftAttachments = files }
        .onDisappear {
            if tileContext != nil { session.draft = draft; session.draftAttachments = attachments }
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
        .onDrop(of: [.fileURL, .image, .data], isTargeted: $isDropTargeted, perform: handleDrop)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatHeight = $0 }
        .sheet(item: $viewingDocument) { document in
            let window = (NSApp.mainWindow ?? NSApp.keyWindow)?.contentLayoutRect.size ?? NSSize(width: 1200, height: 800)
            DocumentViewer(document: document)
                .frame(width: max(600, window.width - 40), height: max(400, window.height - 40))
        }
        .sheet(isPresented: $showingImages) {
            ChatImageGallery(session: session, onOpen: { reviewing = $0 },
                             onAdd: { urls in add(urls.compactMap(importOrReport)); composerFocused = true })
        }
        .sheet(item: $reviewing) { image in
            // As big as the window allows, so the image or document gets the most room.
            let window = (NSApp.mainWindow ?? NSApp.keyWindow)?.contentLayoutRect.size ?? NSSize(width: 1200, height: 800)
            // Previous and Next step through the chat's images, oldest to newest.
            ImageReviewView(attachment: image, gallery: ChatImageGallery.collect(session).reversed().map(\.url)) { text, files in session.send(text, attachments: files) }
                .frame(width: max(900, window.width - 40), height: max(600, window.height - 40))
        }
        .alert("That folder already has a chat", isPresented: Binding(get: { projectConflict != nil }, set: { if !$0 { projectConflict = nil } }), presenting: projectConflict) { owner in
            Button("Open That Chat") { model.selectedID = owner.id }
            Button("Cancel", role: .cancel) {}
        } message: { owner in
            Text("\u{201C}\(owner.title)\u{201D} is bound to \(owner.record.projectFolder ?? "it"). Each project folder has one chat, and you can switch models inside it.")
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.highlight, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.highlight.opacity(0.06))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.title3).foregroundStyle(Color.highlight))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Attachments

    /// ⌘V with an image or copied files on the pasteboard attaches them instead of pasting text.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  event.window?.isKeyWindow == true, event.window?.windowNumber == windowNumber, composerFocused, tileActive,
                  let pasted = Attachments.fromPasteboard() else { return event }
            add(pasted)
            return nil
        }
    }

    /// Apple's own dictation, into the message box: focuses it, then runs Edit → Start
    /// Dictation (the same thing pressing Fn twice does).
    private func startDictation() {
        composerFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let start = Selector(("startDictation:"))
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.action == start { return item }
                    if let found = find(item.submenu) { return found }
                }
                return nil
            }
            if let item = find(NSApp.mainMenu), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                NSApp.sendAction(start, to: nil, from: nil)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap(importOrReport))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([importOrReport(url)].compactMap { $0 }) }
                }
            } else if let type = Self.fileType(of: provider) {
                // A file dragged from an app without a Finder path (an .ai from a design app):
                // keep the file itself, under its own name, not a picture of it.
                let name = (provider.suggestedName ?? "Dropped file") + (type.preferredFilenameExtension.map { ".\($0)" } ?? "")
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url else { return }
                    // The file is only there until this returns, so copy it now.
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                    let file = copy.appendingPathComponent(name)
                    guard (try? FileManager.default.copyItem(at: url, to: file)) != nil else { return }
                    Task { @MainActor in
                        add([importOrReport(file)].compactMap { $0 })
                        try? FileManager.default.removeItem(at: copy)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        do { add([try Attachments.importImageData(data, name: provider.suggestedName ?? "Dropped image")]) } catch { attachError = error.localizedDescription }
                    }
                }
            }
        }
        return true
    }

    /// The most specific file type a drag offers, unless it's only a plain picture.
    private static func fileType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.lazy.compactMap(UTType.init).first { type in
            type.conforms(to: .data) && !Attachments.rasterTypes.contains(where: type.conforms(to:))
                && type != .data && type != .image
        }
    }

    private func importOrReport(_ url: URL) -> Attachment? {
        do { return try Attachments.importFile(url) } catch {
            attachError = error.localizedDescription
            return nil
        }
    }

    private func add(_ new: [Attachment]) {
        attachError = nil
        attachments += new
        composerFocused = true
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                        Attachments.remove([attachment])
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.items.isEmpty {
                    EmptyChatView(session: session) { draft = $0; submit() }
                        .padding(.top, 60)
                } else {
                    // Only the drawn tail is grouped and badged; long histories aren't walked per render.
                    // The rows take the chat's width; the widest one can't widen the column.
                    FlexibleWidth {
                    Group {
                    if session.isDot {
                        VStack(spacing: 0) {
                            #if GOLEM_APP
                            DotConversation(session: session, initialRows: sidebar == nil ? 80 : Self.firstRows, showsInlineAvatar: sidebar == nil && !standaloneWindow)
                            #else
                            Text("Open this conversation in Golem.")
                            #endif
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    } else {
                    let page = findWindow.map(windowPage) ?? transcriptPage(rows: shownRowCount)
                    let agents = page.agents
                    // A bounded eager stack keeps WebKit views and hit regions in the same
                    // layout pass. LazyVStack + bottom anchoring can blank the transcript
                    // on macOS 26 when offscreen web previews change size.
                    VStack(alignment: .leading, spacing: 0) {
                        if findWindow != nil {
                            Button { findWindow = nil; keepBottom(proxy) } label: {
                                Label("Showing messages around a match \u{00B7} Back to latest", systemImage: "arrow.down.to.line")
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 10)
                        }
                        // Long chats draw only their newest rows; the rest wait behind a button.
                        if page.hasEarlier {
                            let earlier = earlierRowCount(before: page.start)
                            Button {
                                shownRowCount += Self.rowPage
                            } label: {
                                Label("Show \(min(Self.rowPage, earlier)) earlier", systemImage: "arrow.up.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 10)
                            .help("\(earlier) earlier rows in this chat")
                        }
                        ForEach(page.rows) { row in
                            switch row {
                            case .item(let item):
                                Group {
                                    if isWaitingOnYou(item) {
                                        waitingMarker(item)
                                    } else {
                                        ItemView(item: item, isActive: session.isRunning && item.id == session.items.last?.id,
                                                 agent: agents[item.id] ?? session.record.backend,
                                                 onApproval: session.resolveApproval, onAnswer: session.answerQuestions,
                                                 onSendNow: session.sendQueuedNow)
                                    }
                                }
                                .padding(.vertical, rowPadding(item))
                                .background(findHighlight([item.id]))
                                .id(item.id)
                            case .steps(let steps, let seconds, let active):
                                StepGroup(steps: steps, seconds: seconds, isActive: active,
                                          expanded: Binding(get: { openStepGroups.contains(row.id) },
                                                            set: { if $0 { openStepGroups.insert(row.id) } else { openStepGroups.remove(row.id) } })) { item in
                                    ItemView(item: item, isActive: active && item.id == session.items.last?.id,
                                             agent: agents[item.id] ?? session.record.backend)
                                        .padding(.vertical, rowPadding(item))
                                }
                                .padding(.vertical, appearance.style.paragraphSpacing / 2)
                                .background(findHighlight(steps.map(\.id)))
                                .id(row.id)
                            }
                        }
                        if session.isRunning && !isVisiblyWorking {
                            TypingIndicator()
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    }
                    }
                    .padding(.horizontal, compact ? 14 : 24)
                    .padding(.vertical, compact ? 12 : 20)
                    .frame(maxWidth: appearance.style.contentWidth)
                    .environment(\.readerStyle, appearance.style)
                    .environment(\.reviewImage, ImageReviewAction { reviewing = $0 })
                    .environment(\.pinMessage, PinMessageAction(chat: showsPins ? session.record.id : nil))
                    .frame(maxWidth: .infinity)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .task(id: session.id) {
                // The eager stack needs its first layout before ScrollViewReader can
                // find the bottom. Do this only on entry, not when loading older rows.
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                Diagnostics.signposts.emitEvent("Chat shown")
                // Each row costs layout up front (the stack is eager), so the rest of the first
                // page arrives just after the chat is on screen. One step: growing in several
                // re-lays out the rows already there each time.
                guard !session.isDot, shownRowCount < Self.rowPage else { return }
                if sidebar != nil {
                    // Expanding the eager stack during the fade stalls its frames. Let the
                    // first page become interactive, finish the 100ms incoming fade, then
                    // prepare extra history only if this chat is still mounted.
                    while switchingChats {
                        try? await Task.sleep(for: .milliseconds(10))
                        guard !Task.isCancelled else { return }
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                } else {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard !Task.isCancelled else { return }
                shownRowCount = Self.rowPage
                // The new rows can take more than one pass to lay out; keep the newest in view until they settle.
                keepBottom(proxy)
            }
            .onChange(of: session.isRunning) { _, running in if !running { stopStatus = nil; requestingStop = false } }
            .onChange(of: session.items.count) { if !find.isOpen { scrollToBottom(proxy) } else { find.recompute() } }
            .onChange(of: find.jumpRequest) { jumpToMatch(proxy) }
            .onChange(of: pinJump) { _, id in
                guard let id else { return }
                pinJump = nil
                jump(to: id, proxy)
                flashedID = id
                Task { try? await Task.sleep(for: .seconds(1.6)); if flashedID == id { withAnimation { flashedID = nil } } }
            }
            // Closing find goes back to the latest messages if a match was far back.
            .onChange(of: find.isOpen) { _, open in
                if !open, findWindow != nil { findWindow = nil; keepBottom(proxy) }
            }
            // The terminal takes room from the bottom: keep the newest messages in view above it.
            .onChange(of: showingTerminal) { keepBottom(proxy) }
            .onChange(of: terminalHeight) { keepBottom(proxy) }
            .onChange(of: session.items.last?.text) { scrollToBottom(proxy) }
        }
    }

    /// Matching messages get a soft highlight; the current one, a stronger one.
    private func findHighlight(_ ids: [UUID]) -> some View {
        let current = (find.currentID.map(ids.contains) ?? false) || (flashedID.map(ids.contains) ?? false)
        let matched = current || (find.isOpen && ids.contains { find.matches.contains($0) })
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.yellow.opacity(current ? 0.22 : matched ? 0.08 : 0))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(current ? 0.7 : 0)))
            .padding(.horizontal, -8)
    }

    /// Brings the current match into view: older rows are drawn first if it's among them, and
    /// a folded group of steps holding it opens.
    private func jumpToMatch(_ proxy: ScrollViewProxy) {
        if let id = find.currentID { jump(to: id, proxy) }
    }

    /// Brings message `id` into view, drawing older rows or opening its step group as needed.
    private func jump(to id: UUID, _ proxy: ScrollViewProxy) {
        guard let index = session.items.firstIndex(where: { $0.id == id }) else { return }
        var page = paging.page(session.items, limit: shownRowCount)
        if page.start > index {
            // Within a few pages: draw them. Further back: show the messages around it instead.
            let grown = paging.page(session.items, limit: shownRowCount + 3 * Self.rowPage)
            if grown.start <= index {
                shownRowCount += 3 * Self.rowPage
                page = grown
                findWindow = nil
            } else {
                let window = max(0, index - 30)..<min(session.items.count, index + 30)
                findWindow = window
                page = (paging.page(Array(session.items[window]), limit: .max).rows, window.lowerBound, false)
            }
        } else if let window = findWindow, !window.contains(index) {
            findWindow = nil
        }
        let row = page.rows.first { row in
            switch row {
            case .item(let item): item.id == id
            case .steps(let steps, _, _): steps.contains { $0.id == id }
            }
        }
        if case .steps = row, let rowID = row?.id { openStepGroups.insert(rowID) }
        let target = row?.id ?? id
        // After the newly drawn rows lay out.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
        }
    }

    /// The rows for messages `window` (a find match far back), in the transcript's shape.
    private func windowPage(_ window: Range<Int>) -> (rows: [TranscriptRow], agents: [UUID: Backend], start: Int, hasEarlier: Bool) {
        let window = window.clamped(to: 0..<session.items.count)
        let rows = paging.page(Array(session.items[window]), limit: .max).rows
        return (rows, session.agents(forItemsFrom: window.lowerBound), window.lowerBound, false)
    }

    private var paging: TranscriptPaging {
        TranscriptPaging(showThinking: appearance.showThinking, groupSteps: groupSteps, isRunning: session.isRunning,
                         liveNotes: groupSteps ? session.liveCommentaryIDs : [])
    }

    /// The newest `rows` rows to draw, and the agent each user message in them went to (worked
    /// out walking back from the agent answering now, so the drawn tail alone is enough).
    private func transcriptPage(rows limit: Int) -> (rows: [TranscriptRow], agents: [UUID: Backend], start: Int, hasEarlier: Bool) {
        let page = paging.page(session.items, limit: limit)
        return (page.rows, session.agents(forItemsFrom: page.start), page.start, page.hasEarlier)
    }

    /// Rows before `start`, for the "Show earlier" button; counted once per history length.
    private func earlierRowCount(before start: Int) -> Int {
        let key = "\(session.items.count)|\(start)|\(appearance.showThinking)|\(groupSteps)"
        if let cached = earlierCountCache.value, earlierCountCache.key == key { return cached }
        let count = paging.rows(Array(session.items[..<start])).count
        earlierCountCache.key = key
        earlierCountCache.value = count
        return count
    }

    /// Half the paragraph spacing above and below each row; step rows get less in compact mode.
    private func rowPadding(_ item: DisplayItem) -> CGFloat {
        let spacing = appearance.style.paragraphSpacing / 2
        let isStep = item.kind == .tool || item.kind == .thought || item.kind == .notice
            || (item.kind == .assistant && item.phase == .commentary)
        return isStep && appearance.compactSteps ? 1 : spacing
    }

    /// True when the last row already shows activity, so the typing dots would be redundant.
    private var isVisiblyWorking: Bool {
        guard let last = session.items.last(where: { appearance.showThinking || $0.kind != .thought }) else { return false }
        switch last.kind {
        case .assistant: return last.phase == .streaming
        case .tool: return last.toolState == .running
        case .thought: return true
        case .questions, .approval: return last.approvalState == .pending
        default: return false
        }
    }

    /// Scrolls to the end while the layout settles (the terminal slides in over a moment).
    private func keepBottom(_ proxy: ScrollViewProxy) {
        for delay in [0, 0.12, 0.28] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Confirm UI-to-service delivery; never claim a turn stopped before its state changes.
    private func requestStop() {
        guard !requestingStop else { return }
        requestingStop = true
        stopStatus = "Requesting stop…"
        Task { @MainActor in
            defer { requestingStop = false }
            do {
                if session.remoteCommand != nil {
                    _ = try await RuntimeClient.shared.request("stop", body: ["chatID": .string(session.id.uuidString)], timeout: .seconds(10))
                } else { session.interrupt() }
                guard session.canStop else { stopStatus = nil; return }
                stopStatus = "Stop requested. Waiting for the agent…"
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(500))
                    if !session.canStop { stopStatus = nil; return }
                }
                stopStatus = "The agent hasn’t confirmed stopping. You can try Stop again."
            } catch {
                stopStatus = "Couldn’t request stop: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Composer

    // MARK: - Waiting on you

    /// Approvals and questions waiting for an answer. They're shown above the message box, not
    /// in the transcript: the transcript is a lazy list, and when rows near the bottom change
    /// height it keeps stale click positions until you scroll, so card buttons missed.
    private func isWaitingOnYou(_ item: DisplayItem) -> Bool {
        (item.kind == .approval || item.kind == .questions) && item.approvalState == .pending
    }

    /// The earliest waiting card; the rest follow once it's answered.
    private var waitingCard: DisplayItem? { session.items.first(where: isWaitingOnYou) }

    private func waitingMarker(_ item: DisplayItem) -> some View {
        Label(item.kind == .questions ? "Waiting for your answer below" : "Waiting for your approval below",
              systemImage: "arrow.down.circle")
            .font(.callout)
            .foregroundStyle(Color.highlight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waitingTray: some View {
        // Hidden copies of the paperclip and send/stop buttons, so the card lines up exactly
        // with the text field below it.
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "paperclip").font(.system(size: 17)).hidden()
            ScrollView {
                if let item = waitingCard {
                    ItemView(item: item, agent: session.record.backend,
                             onApproval: session.resolveApproval, onAnswer: session.answerQuestions)
                        .environment(\.cardFillsWidth, true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(item.id)
                }
            }
            // Tall cards (a long plan) scroll inside the tray instead of pushing the chat away.
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "mic").font(.system(size: 16)).hidden()
            if session.canStop {
                Image(systemName: "stop.circle.fill").font(.system(size: 26)).hidden()
            }
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).hidden()
        }
    }

    private var composer: some View {
        // Takes the width it's given: the model line is the one row that can't wrap, and
        // without this it would set the chat column's minimum (over 500 points with a few
        // presets), pushing the sidebar and inspector out of a narrow window.
        FlexibleWidth {
            composerContent
        }
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.hasBackgroundWork {
                BackgroundWorkBar(session: session, color: appearance.style.color(for: session.record.backend))
                    .padding(.leading, 34)
            }
            if waitingCard != nil { waitingTray }
            if !commandMatches.isEmpty { commandMenu }
            if draft.hasPrefix("!") {
                Label("Runs in your shell in \((session.workingFolder as NSString).abbreviatingWithTildeInPath). The output goes to \(session.record.backend.label) with your next message.",
                      systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
            if !attachments.isEmpty { attachmentTray }
            if !nextSteps.isEmpty && !session.isRunning { nextStepsRow }
            if let attachError {
                Label(attachError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            composerRow
            modelStatus
        }
        .padding(.horizontal, compact ? 12 : 20)
        .padding(.vertical, compact ? 10 : 12)
        .frame(maxWidth: appearance.style.contentWidth + 40)
        .frame(maxWidth: .infinity)
        .background(Theme.currentBackground.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.bar))
    }

    // MARK: - Slash commands

    /// Claude Code's commands and skills (including the project's), or Codex's skills.
    private var availableCommands: [SlashCommand] { session.availableSlashCommands }

    /// Shown while the draft is "/" plus a partial command name.
    private var commandMatches: [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace), draft != dismissedCommandDraft else { return [] }
        return Array(SlashCommand.matches(String(draft.dropFirst()), in: availableCommands).prefix(8))
    }

    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commandMatches.enumerated()), id: \.element.id) { index, command in
                Button { complete(command) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/" + command.name).font(.callout.weight(.semibold)).lineLimit(1)
                        if let hint = command.argumentHint {
                            Text(hint).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(index == commandIndex ? Color.highlight.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .padding(.leading, 34)
    }

    private func moveCommandSelection(_ offset: Int) -> KeyPress.Result {
        let count = commandMatches.count
        guard count > 0 else { return .ignored }
        commandIndex = (commandIndex + offset + count) % count
        return .handled
    }

    private func completeCommand() -> KeyPress.Result {
        let matches = commandMatches
        guard !matches.isEmpty else { return .ignored }
        complete(matches[min(commandIndex, matches.count - 1)])
        return .handled
    }

    private func complete(_ command: SlashCommand) {
        draft = "/\(command.name) "
        composerFocused = true
    }

    private var canSend: Bool {
        !session.isRestartingThread && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if session.isDot {
                // Golem's chat reads like a conversation: a round +, like iMessage.
                Menu {
                    Button("Attach Files\u{2026}", action: chooseFiles)
                    Button("Paste Image") {
                        if let files = Attachments.fromPasteboard() { attachments += files }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                .help("Attach files or images. You can also paste or drag them in.")
                .accessibilityLabel("Attach")
            } else {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip").font(.system(size: 17))
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach files or images. You can also paste or drag them in.")
                .accessibilityLabel("Attach Files")
            }

            // Grows with the message to just under half the chat, then scrolls. Return sends;
            // Shift-Return starts a new line. ⌘↩ while the agent works stops it and sends now.
            ComposerBox(text: $draft,
                        placeholder: session.isRunning ? "Add something while it works\u{2026}"
                            : nextSteps.first.map { "\($0)  \u{21E5}" } ?? "Message \(session.isDot ? session.title : session.record.backend.label)",
                        isFocused: $composerFocused,
                        maxHeight: max(8 * 20, chatHeight * 0.45),
                        onKey: { key, modifiers in
                            switch key {
                            case .return:
                                if modifiers.contains(.command), session.isRunning { submit(now: true); return true }
                                return completeCommand() == .handled
                            case .up: return moveCommandSelection(-1) == .handled
                            case .down: return moveCommandSelection(1) == .handled
                            case .tab:
                                if completeCommand() == .handled { return true }
                                return pickNextStep(1)
                            case .digit(let number):
                                if number == 0, !nextSteps.isEmpty { NextSteps.shared.dismiss(session); return true }
                                return pickNextStep(number)
                            case .escape:
                                guard !commandMatches.isEmpty else { return false }
                                dismissedCommandDraft = draft
                                return true
                            }
                        },
                        onSubmit: submit)
                .onChange(of: draft) { commandIndex = 0 }
                .padding(.vertical, 9)
                .padding(.horizontal, session.isDot ? 14 : 12)
                .background(RoundedRectangle(cornerRadius: session.isDot ? 17 : 12, style: session.isDot ? .circular : .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: session.isDot ? 17 : 12, style: session.isDot ? .circular : .continuous)
                    .strokeBorder(session.isDot ? Color.primary.opacity(composerFocused ? 0.3 : 0.18)
                                  : appearance.style.color(for: session.record.backend).opacity(composerFocused ? 0.8 : 0.45),
                                  lineWidth: session.isDot ? 1 : (composerFocused ? 1.5 : 1)))
                .animation(.easeOut(duration: 0.15), value: session.record.backend)

            Button(action: startDictation) {
                Image(systemName: "mic").font(.system(size: 16))
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dictate with Apple Dictation (or press Fn twice)")
            .accessibilityLabel("Dictate")

            if session.isDot {
                // Only what a conversation needs: how full the context is, and the cog.
                UsageMeter(compact: true, session: session, color: appearance.style.color(for: session.record.backend))
                    .fixedSize()
                    .frame(height: 36)
                ChatSettingsCog(session: session, modelRequest: commands.modelPopoverRequests,
                                modeRequest: commands.modePopoverRequests,
                                handlesKeyboardRequest: { handlesKeyboard })
                    .padding(.bottom, 3)
            }

            if session.isRunning, let started = session.record.turnStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ChatSession.durationText(max(0, Int(context.date.timeIntervalSince(started)))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(height: 36)
                .help("Working since \(started.formatted(date: .omitted, time: .shortened))")
            }
            if session.canStop {
                Button(action: requestStop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(tileActive ? KeyboardShortcut(".", modifiers: .command) : nil)
                .help("Stop (Esc or \u{2318}.)")
                .accessibilityLabel("Stop")
                // Esc stops the reply from anywhere in the chat. While the "/" menu is open,
                // Esc closes the menu instead. Kept in the background so it takes no room in the row.
                .background {
                    if commandMatches.isEmpty {
                        Button("Stop", action: requestStop)
                            .keyboardShortcut(tileActive ? KeyboardShortcut(.escape, modifiers: []) : nil)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
            }

            Button {
                tileContext?.activate()
                submit(now: false, requiresActiveTile: false)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.primary : Color.secondary)
            .disabled(!canSend)
            // Named for VoiceOver and for assistants that work the Mac through Accessibility,
            // which otherwise only see an unnamed arrow icon.
            .accessibilityLabel("Send")
            .help(session.isRunning ? "Add to the current reply (\u{21A9}), or \u{2318}\u{21A9} to stop and send now" : "Send")
        }
    }

    // MARK: - Next Steps (Settings → Plugins)

    private var nextSteps: [String] { session.isRunning ? [] : NextSteps.shared.suggestions(for: session) }

    /// Puts suggestion `number` (1-based) in the box as a draft to edit; never sends it.
    private func pickNextStep(_ number: Int) -> Bool {
        let steps = nextSteps
        guard draft.isEmpty, steps.indices.contains(number - 1) else { return false }
        draft = steps[number - 1]
        composerFocused = true
        return true
    }

    /// One suggestion per line, in full (long ones wrap), so each can be read before picking.
    private var nextStepsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { NextSteps.shared.dismiss(session) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss (0 from an empty box)")
                .accessibilityLabel("Dismiss suggestions")
            }
            ForEach(Array(nextSteps.enumerated()), id: \.offset) { index, step in
                Button {
                    draft = step
                    composerFocused = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(step).font(.callout)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Puts it in the box to edit (\(index + 1) from an empty box\(index == 0 ? ", or Tab" : "")). Nothing is sent until you send it.")
            }
        }
        .padding(.leading, 34)
        .transition(.opacity)
    }

    private func submit() { submit(now: false) }

    /// `now`: ⌘↩ while the agent works stops it and sends this message right away.
    private func submit(now: Bool, requiresActiveTile: Bool = true) {
        guard canSend, (!requiresActiveTile || tileActive), sidebar == nil || (!switchingChats && model.selectedID == session.id) else { return }
        let text = draft
        let files = attachments
        draft = ""
        attachments = []
        attachError = nil
        if now { session.sendNow(text, attachments: files) } else { session.send(text, attachments: files) }
    }

    private var archivedBanner: some View {
        HStack {
            Image(systemName: "archivebox")
            Text("This chat is archived. Sending a message brings it back.")
            Spacer()
            Button("Unarchive") { model.unarchive(session) }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12))
    }

    private func claudeBanner(_ status: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(status).lineLimit(2)
            Spacer()
            Button("Retry") { Task { await ClaudeModels.shared.refresh(force: true) } }
            Button("Open Settings") { model.showingSettings = true }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }

    private func openSelectedPreview() {
        guard let (url, destination) = selectedPreview else { return }
        selectedPreview = nil
        switch destination {
        case .sidebar:
            if let preview, preview.url == url { preview.reload() }
            else { withAnimation(.easeOut(duration: 0.2)) { preview = WebPage(url: url) } }
        case .fullScreen, .window:
            BrowserPreviewWindows.shared.open(url, fullScreen: destination == .fullScreen)
        case .chrome, .chromium, .safari:
            guard let application = destination.application else {
                previewOpenError = "That browser isn't installed on this Mac."
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { _, error in
                if let error { Task { @MainActor in previewOpenError = error.localizedDescription } }
            }
        }
    }

    private func attachToolbar() {
        guard tileContext == nil else { return }
        (windowToolbar ?? ownToolbar).attach(session, owner: toolbarOwner, issuesPanel: issuesPanel,
            showImages: { showingImages = true },
            toggleTerminal: { withAnimation(.smooth(duration: 0.25)) { showingTerminal.toggle() } },
            chooseProject: { chooseProject() })
    }

    private func chooseProject() {
        let start = session.record.projectFolder ?? session.record.codex?.folder
        guard let path = FolderPicker.choose(startingAt: start, message: "Choose the project folder for this chat") else { return }
        if let owner = model.bind(session, to: path) {
            projectConflict = owner
        }
    }

    // MARK: - Model

    /// The current model or preset this chat uses, under the message box.
    @ViewBuilder
    private var modelStatus: some View {
        // Golem's chat keeps these behind its cog.
        if session.isDot { EmptyView() } else if compact { compactModelStatus } else { fullModelStatus }
    }

    private var selectedPreset: ModelPreset? {
        ModelPresets.shared.presets.first { ModelPresets.shared.matches($0, session: session) }
    }

    private var currentModelPicker: some View {
        ModelPicker(session: session, selectionPill: true,
                    summary: selectedPreset?.displayName ?? modelSummary.full,
                    color: appearance.style.color(for: session.record.provider),
                    details: modelSummary.full + (session.record.provider != session.record.backend ? " · Claude model via Codex" : ""),
                    openRequest: commands.modelPopoverRequests,
                    handlesKeyboardRequest: { handlesKeyboard })
    }

    private var compactModelStatus: some View { modelStatusRow(compact: true) }
    private var fullModelStatus: some View { modelStatusRow(compact: false) }

    private func modelStatusRow(compact: Bool) -> some View {
        ComposerStatusLayout {
            HStack(spacing: 14) {
                modeMenu.fixedSize()
                UsageMeter(compact: compact, session: session,
                           color: appearance.style.color(for: session.record.backend)).fixedSize()
            }
            currentModelPicker
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// How much the active agent may do without asking. Changes apply right away.
    private var modeMenu: some View {
        ModePicker(
            modes: PermissionModes.modes(for: session.record.backend),
            current: session.mode,
            header: session.record.backend == .claude ? "Mode" : "How should Codex actions be approved?",
            showsIcons: session.record.backend == .codex,
            openRequest: commands.modePopoverRequests,
            handlesKeyboardRequest: { handlesKeyboard },
            onSelect: session.setMode
        )
    }
    /// The current agent, model, and effort: a full form, and a short one for narrow windows.
    private var modelSummary: (full: String, short: String) {
        if session.record.backend == .codex, let codex = session.record.codex {
            let models = CodexAppServer.shared.models
            let current = models.first { $0.model == codex.model }
            // With no pick, show what Codex will actually use.
            let resolved = current ?? models.first(where: \.isDefault)
            let name = resolved.map { CodexModelCatalog.name($0.model, models: models) } ?? codex.model.map { CodexModelCatalog.name($0, models: models) } ?? "Codex default"
            let modelName = current == nil && resolved != nil ? "\(name) (default)" : name
            let effort = codex.effort ?? resolved?.defaultEffort
            let effortFull = codex.effort.map { Self.effortLabel($0) } ?? effort.map { "\(Self.effortLabel($0)) (default)" }
            return ("Codex \u{00B7} \(modelName)" + (effortFull.map { " \u{00B7} \($0) effort" } ?? ""),
                    name + (effort.map { " \u{00B7} \(Self.effortLabel($0))" } ?? ""))
        }
        let catalog = ClaudeModels.shared
        let current = catalog.info(session.record.model)
        // "Default" points at a real model; name that one rather than the alias.
        let target = current.value == "default"
            ? catalog.models.first { $0.value != "default" && $0.resolvedModel == current.resolvedModel }?.displayName
            : nil
        let name = target ?? current.displayName
        let modelName = target != nil ? "\(name) (default)" : name
        let effort = session.record.effort.isEmpty ? nil : Self.effortLabel(session.record.effort)
        guard !current.efforts.isEmpty else { return ("Claude \u{00B7} \(modelName)", name) }
        return ("Claude \u{00B7} \(modelName) \u{00B7} \(effort ?? "Default") effort",
                name + " \u{00B7} " + (effort ?? "Default"))
    }

    static func effortLabel(_ effort: String) -> String {
        effort == "xhigh" ? "Extra High" : effort.capitalized
    }

    private func codexBanner(_ status: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(status).lineLimit(2)
            Spacer()
            Button("Open Settings") { model.showingSettings = true }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }
}

private struct EmptyChatView: View {
    let session: ChatSession
    let onPick: (String) -> Void

    private var suggestions: [String] {
        let isProject = session.record.projectFolder != nil || session.record.worktreeOf != nil || session.record.sidechatProjectFolder != nil || session.record.convertedProjectFolder != nil
        let project = isProject ? (session.projectName.isEmpty ? URL(fileURLWithPath: session.workingFolder).lastPathComponent : session.projectName) : nil
        return StarterPrompts.suggestions(project: project, studio: session.studio?.name, backend: session.record.backend)
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(session.record.backend.iconName).resizable().scaledToFit().frame(width: 14, height: 14)
                .font(.system(size: 40))
                .foregroundStyle(.primary)
            Text("What's on your mind?")
                .font(.title2.weight(.semibold))

            if !session.isDot {
                AgentSwitch(selection: session.record.backend, onSelect: session.setBackend)
            }

            if session.record.boundFolder == nil, session.record.backend == .codex, let codex = session.record.codex {
                Button {
                    if let path = FolderPicker.choose(startingAt: codex.folder) { session.setCodexFolder(path) }
                } label: {
                    Label(codex.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("The folder Codex can see. Click to change.")
            }

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { onPick(suggestion) } label: {
                        Text(suggestion)
                            .frame(maxWidth: 420, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Turns a link with no scheme into the file it names: absolute, "~/…", or relative to the
/// chat's folder, dropping a trailing ":line" or ":line:column" when that's what was added.
enum FileLink {
    static func resolve(_ url: URL, in folder: String) -> URL? {
        guard url.scheme == nil || url.scheme == "file" else { return nil }
        var path = url.scheme == "file" ? url.path : (url.path.removingPercentEncoding ?? url.path)
        guard !path.isEmpty else { return nil }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (folder as NSString).appendingPathComponent(path) }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path), let range = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression),
           fm.fileExists(atPath: String(path[..<range.lowerBound])) {
            path = String(path[..<range.lowerBound])
        }
        return URL(fileURLWithPath: path)
    }
}

enum FolderPicker {
    @MainActor
    static func choose(startingAt path: String?, message: String = "Choose the folder Codex can work in") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        // "New Folder" in the panel, for making a folder on the spot.
        panel.canCreateDirectories = true
        if let path { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TypingDots(animated: !reduceMotion)
            .frame(width: 26, height: 12)
            .padding(.vertical, 4)
    }
}

/// Three dots in a gentle wave, drawn and animated by Core Animation so SwiftUI does
/// no work per frame.
private struct TypingDots: NSViewRepresentable {
    var animated: Bool

    func makeNSView(context: Context) -> NSView { DotsNSView(animated: animated) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DotsNSView: NSView {
        private var dots: [CALayer] = []

        init(animated: Bool) {
            super.init(frame: .zero)
            wantsLayer = true
            for i in 0..<3 {
                let dot = CALayer()
                dot.backgroundColor = NSColor.secondaryLabelColor.cgColor
                dot.cornerRadius = 3
                dot.opacity = 0.3
                layer?.addSublayer(dot)
                dots.append(dot)
                guard animated else { continue }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.3
                fade.toValue = 1
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = 0
                rise.toValue = 2.5
                let group = CAAnimationGroup()
                group.animations = [fade, rise]
                group.duration = 0.5
                group.autoreverses = true
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.beginTime = CACurrentMediaTime() + Double(i) * 0.16
                dot.add(group, forKey: "wave")
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            for (i, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(i) * 10, y: bounds.midY - 3, width: 6, height: 6)
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                for dot in dots { dot.backgroundColor = NSColor.secondaryLabelColor.cgColor }
            }
        }
    }
}

/// A removable attachment in the composer.
private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            AttachmentThumbnail(attachment: attachment, size: 28)
            Text(attachment.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
        .font(.callout)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.7)))
    }
}

/// The mode button under the message box and its popover: each mode with its description,
/// a Recommended badge, and number keys to pick one.
private struct ModePicker: View {
    let modes: [PermissionMode]
    let current: PermissionMode
    let header: String
    let showsIcons: Bool
    /// Bumped by Chat → Choose Mode (⌘⇧P) to toggle the popover.
    var openRequest = 0
    var handlesKeyboardRequest: () -> Bool = { true }
    let onSelect: (String) -> Void
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 3) {
                Label(current.title, systemImage: current.systemImage).labelStyle(SpacedLabelStyle())
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(current.isUnrestricted ? Color.orange : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(current.title): \(current.detail). Click to change (\u{2318}\u{21E7}P).")
        .onChange(of: openRequest) {
            if isOpen || handlesKeyboardRequest() { isOpen.toggle() }
        }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    ModeRow(mode: mode, number: index + 1, isCurrent: mode.id == current.id, showsIcon: showsIcons) {
                        onSelect(mode.id)
                        isOpen = false
                    }
                }
            }
            .padding(10)
            .frame(width: 380)
        }
    }
}

private struct ModeRow: View {
    let mode: PermissionMode
    let number: Int
    let isCurrent: Bool
    let showsIcon: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 10) {
                if showsIcon {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 15))
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title).font(.body)
                        if mode.isRecommended {
                            Text("Recommended")
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(mode.isUnrestricted ? AnyShapeStyle(Color.orange.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Color.highlight)
                }
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(mode.isUnrestricted ? Color.orange : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
    }
}

/// The project's GitHub repo in the toolbar: branch and sync state, with links out.
struct RepoChip: View {
    let repo: String
    let remote: GitRemote
    let status: GitStatus
    let folder: String
    let onSelectRemote: (String) -> Void
    let onShowIssues: () -> Void

    private var web: URL { URL(string: "https://github.com/\(repo)")! }

    private var syncText: String {
        var parts: [String] = []
        if let ahead = status.ahead, ahead > 0 { parts.append("\u{2191}\(ahead)") }
        if let behind = status.behind, behind > 0 { parts.append("\u{2193}\(behind)") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        Menu {
            Button("Open on GitHub") { NSWorkspace.shared.open(web) }
            if let branch = status.branch {
                Button("Open Branch \u{201C}\(branch)\u{201D}") {
                    NSWorkspace.shared.open(web.appendingPathComponent("tree").appendingPathComponent(branch))
                }
            }
            Button("Issues\u{2026}") { onShowIssues() }
            Button("Issues on GitHub") { NSWorkspace.shared.open(web.appendingPathComponent("issues")) }
            Button("Pull Requests") { NSWorkspace.shared.open(web.appendingPathComponent("pulls")) }
            Divider()
            Button("Copy Clone URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(remote.url, forType: .string)
            }
            Button(GitStatusStore.shared.fetching.contains(folder) ? "Checking GitHub\u{2026}" : "Check for Updates") {
                Task { await GitStatusStore.shared.refresh(folder, fetch: true) }
            }
            let github = status.remotes.filter { $0.repo != nil }
            if github.count > 1 {
                Divider()
                Picker("Remote", selection: Binding(get: { remote.name }, set: onSelectRemote)) {
                    ForEach(github, id: \.name) { Text("\($0.name) (\($0.repo ?? ""))").tag($0.name) }
                }
            }
        } label: {
            ToolbarLabel([repo, status.branch, syncText.isEmpty ? nil : syncText, status.mainDriftText].compactMap { $0 }.joined(separator: " \u{00B7} "),
                         systemImage: "arrow.triangle.branch")
        }
        .help(helpText)
    }

    private var helpText: String {
        var text = "\(repo) on GitHub (remote \u{201C}\(remote.name)\u{201D})"
        if let branch = status.branch { text += ", branch \(branch)" }
        if let ahead = status.ahead, let behind = status.behind {
            text += ". \(ahead) to push, \(behind) to pull"
        } else {
            text += ". No upstream branch"
        }
        if let main = status.mainRef, let ahead = status.aheadOfMain, let behind = status.behindMain {
            text += ". Against \(main): \(ahead) commit\(ahead == 1 ? "" : "s") not on it, \(behind) on it not here"
            if let since = status.divergedAt { text += ", split off \(since.formatted(.relative(presentation: .named)))" }
        }
        return text + "."
    }
}

/// A toolbar menu's icon and title with a gap between them. The toolbar restyles a `Label`
/// (ignoring any label style), so this is a plain row it leaves alone.
struct ToolbarLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title).lineLimit(1)
        }
    }
}

/// Icon then title with a little breathing room, for status controls.
struct SpacedLabelStyle: LabelStyle {
    var spacing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// Lays its content out at exactly the width it's offered, so the content's own minimum
/// never travels up to the column (the navigation split takes a column's minimum as a hard
/// floor and lays out past the window's edges when the window is narrower). Its height is
/// the content's, measured no narrower than the chat's minimum so a tiny probe doesn't wrap
/// text into a tall answer.
struct FlexibleWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let measured = content.sizeThatFits(ProposedViewSize(width: proposal.width.map { max($0, ChatView.minWidth) },
                                                             height: nil))
        return CGSize(width: proposal.width ?? measured.width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Match measurement: a finite height redistributes image rows and can draw the
        // final messages past the scroll document's measured bottom.
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                              proposal: ProposedViewSize(width: max(bounds.width, ChatView.minWidth), height: nil))
    }
}

/// Claude | Codex on an empty chat. A system segmented control always takes the macOS accent
/// color (blue); this one marks the choice in the text color instead: white in dark mode.
private struct AgentSwitch: View {
    let selection: Backend
    let onSelect: (Backend) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Backend.allCases) { backend in
                let selected = backend == selection
                Button { onSelect(backend) } label: {
                    Text(backend.label)
                        .font(.callout.weight(.medium))
                        .frame(width: 96, height: 24)
                        .foregroundStyle(selected ? Color.onHighlight : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat with")
    }
}

/// A run of steps (tools, notes, thinking) folded into one row, like a thought: "18 steps ·
/// 4m 12s". While the agent works it shows the step it's on.
private struct StepGroup<Row: View>: View {
    let steps: [DisplayItem]
    let seconds: Int?
    let isActive: Bool
    @Binding var expanded: Bool
    @ViewBuilder let row: (DisplayItem) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: isActive ? "ellipsis" : "checklist")
                    Text(title)
                    if isActive, !expanded, let current = steps.last(where: { $0.kind == .tool || $0.kind == .assistant }) {
                        Text(ContentView.plainPreview(current.text))
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .shimmering(isActive)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { row($0) }
                }
                .padding(.leading, 18)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        let count = steps.count == 1 ? "1 step" : "\(steps.count) steps"
        if isActive { return "Working \u{00B7} " + count }
        return seconds.map { count + " \u{00B7} " + ChatSession.durationText($0) } ?? count
    }
}

/// A remembered row count; a class so filling it in during a render doesn't re-render.
private final class EarlierCount {
    var key = ""
    var value: Int?
}

#if GOLEM_APP
/// Keep local typing responsive while accepting external voice edits and send clearing.
private struct GolemVoiceDraftSync: ViewModifier {
    let session: ChatSession
    @Binding var draft: String
    @Binding var attachments: [Attachment]
    func body(content: Content) -> some View {
        content
            .onChange(of: session.draft) { old, text in
                if session.isDot, draft == old, draft != text { draft = text }
            }
            .onChange(of: session.draftAttachments) { old, files in
                if session.isDot, attachments == old, attachments != files { attachments = files }
            }
    }
}
#endif

/// Permissions and context share the left edge; the model control stays right.
/// Wrap the model onto a second row if the two sides cannot fit together.
private struct ComposerStatusLayout: Layout {
    private let gap: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let left = subviews[0].sizeThatFits(.unspecified)
        let naturalRight = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (left.width + gap + naturalRight.width)
        let right = subviews[1].sizeThatFits(.init(width: min(width, naturalRight.width), height: nil))
        let wrapped = left.width + gap + right.width > width
        return CGSize(width: width, height: wrapped ? left.height + gap + right.height : max(left.height, right.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let left = subviews[0].sizeThatFits(.unspecified)
        let naturalRight = subviews[1].sizeThatFits(.unspecified)
        let right = subviews[1].sizeThatFits(.init(width: min(bounds.width, naturalRight.width), height: nil))
        let wrapped = left.width + gap + right.width > bounds.width
        let rowHeight = wrapped ? left.height : max(left.height, right.height)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + rowHeight / 2), anchor: .leading, proposal: .init(left))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + (wrapped ? rowHeight + gap : rowHeight / 2)),
                          anchor: wrapped ? .topTrailing : .trailing, proposal: .init(right))
    }
}
