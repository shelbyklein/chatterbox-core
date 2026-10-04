import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chatSwitch: ChatSwitchTransition
    @State private var commandCenter: CommandCenterLayout
    @AppStorage("macSidebarCards") private var sidebarCards = false
    @AppStorage("showArchived") private var showArchived = false
    @AppStorage("sidebarSectionWeights") private var sectionWeights = "1,1,1"
    @AppStorage("sidebarProjectsCollapsed") private var projectsCollapsed = false
    @AppStorage("sidebarStudiosCollapsed") private var studiosCollapsed = false
    @AppStorage("sidebarChatsCollapsed") private var chatsCollapsed = false
    /// While a divider is dragged: the weights it started from.
    @State private var dragStartWeights: [Double]?
    @State private var pendingDelete: ChatSession?
    @State private var renamingProject: ChatSession?
    @State private var worktreeParent: ChatSession?
    @State private var worktreeName = ""
    @State private var removingWorktree: ChatSession?
    @State private var worktreeError: String?
    @State private var projectNickname = ""
    @State private var renamingChat: ChatSession?
    @State private var chatTitle = ""
    /// True while ⌘ is held on its own: the sidebar shows each chat's ⌘-number.
    @State private var showShortcuts = false
    @State private var flagsMonitor: Any?
    @State private var taggingSession: ChatSession?
    @State private var newTag = ""
    @State private var searchText = ""
    @State private var namingStudio = false
    @State private var studioName = ""
    @State private var studioDestinationID: UUID?
    /// The chat that goes into the Studio being named, when making one from a chat.
    @State private var studioFromChat: ChatSession?
    @State private var renamingStudio: Studio?
    @State private var renamingDot = false
    @State private var dotName = ""
    /// The Studio a dragged chat is over, which lights up.
    @State private var dropStudio: UUID?
    /// Show only projects with this tag; empty shows everything.
    @AppStorage("sidebarTagFilter") private var tagFilter = ""
    @AppStorage(Theme.schemeKey) private var themeScheme = "system"
    @AppStorage(Theme.backgroundKey) private var themeBackground = "standard"
    @AppStorage(Theme.highlightKey) private var themeHighlight = "default"
    @AppStorage(ProjectSort.key) private var projectSort = ProjectSort.recent
    @AppStorage("sidebarProjectActivity") private var projectActivity = ProjectActivity.all

    @MainActor init(chatSwitch: ChatSwitchTransition? = nil, commandCenter: CommandCenterLayout? = nil) {
        _chatSwitch = State(initialValue: chatSwitch ?? ChatSwitchTransition())
        _commandCenter = State(initialValue: commandCenter ?? CommandCenterLayout())
    }

    var body: some View {
        Group {
        #if DEBUG
        // Render tests: just the sidebar, since the system's glass sidebar can't be captured offscreen.
        if ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SIDEBAR_ONLY"] != nil {
            sidebarColumn
                .frame(width: Double(ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SIDEBAR_ONLY"] ?? "") ?? 280)
                .background(Theme.sidebar(themeBackground) ?? Color(nsColor: .windowBackgroundColor))
        } else {
            splitView
        }
        #else
        splitView
        #endif
        }
        .alert("Background service",isPresented:Binding(get:{RuntimeClient.usesDaemon && RuntimeClient.shared.connected && RuntimeClient.shared.problem != nil},set:{if !$0{RuntimeClient.shared.clearProblem()}})){
            Button("OK"){RuntimeClient.shared.clearProblem()}
        } message:{Text(RuntimeClient.shared.problem ?? "")}
    }

    private var sidebarPane: AnyView {
        AnyView(VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText).textFieldStyle(.plain)
            }
            .padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)).padding(12)
            sidebarColumn
        }.modifier(ThemedSidebar(background: themeBackground)))
    }

    private var alternateDetail: some View {
            Group {
            if RuntimeClient.usesDaemon, !RuntimeClient.shared.connected {
                ContentUnavailableView {
                    Label("Background service unavailable",systemImage:"network.slash")
                } description: {
                    Text(RuntimeClient.shared.problem ?? "Connecting to Chatterbox’s background service…")
                }
            } else if model.showingSettings {
                SettingsPage()
            } else if let page = model.webPage {
                // A website pin: the page takes the chat's place, and the chat floats over it.
                ZStack(alignment: .bottomTrailing) {
                    WebPaneView(page: page) { model.webPage = nil }
                    if let session = model.selected, !(session.isDot && model.showingDot) {
                        FloatingChat(session: session) { model.webPage = nil }
                            .padding(16)
                    }
                }
            } else if let session = model.selected {
                if session.isDot, model.showingDot {
                    // Only one editable Golem composer at a time, so drafts never diverge.
                    VStack(spacing: 12) {
                        Image(systemName:"arrow.up.forward.app")
                        Text("\(model.dotName) is in the mini window").font(.title3.weight(.medium))
                        HStack {
                            #if GOLEM_APP
                            Button("Show Mini") { model.dotMiniWindow?.show() }
                            #else
                            Button("Open Golem") {GolemIntegration.shared.open()}
                            #endif
                            Button("Bring Chat Here") { model.openDot() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChatView(session: session)
                        .id(session.id)
                }
            } else {
                Text("No chat selected").foregroundStyle(.secondary)
            }
            }
            .modifier(ThemedDetail(background: themeBackground))

    }

    private var mainChatID: UUID? {
        guard !model.showingCommandCenter, !model.showingHome, !model.showingSettings, model.webPage == nil, let session = model.selected,
              !(session.isDot && model.showingDot) else { return nil }
        return session.id
    }

    private var columnRoot: some View {
        Group {
            if model.showingCommandCenter {
                CommandCenterView(layout: commandCenter)
            } else if model.showingHome {
                ChatHomeView { session in AnyView(row(session, number: nil, card: true, expanded: true)) }
            } else if mainChatID != nil, let session = model.sessions.first(where: {
                $0.id == (chatSwitch.initialized ? chatSwitch.displayedID : model.selectedID)
            }) {
                ChatView(session: session, sidebar: sidebarPane)
                    .onAppear { chatSwitch.didMount(session.id) }.id(session.id)
            } else {
                ChatColumns(sidebar: sidebarPane, chat: AnyView(alternateDetail))
            }
        }
        .environment(\.chatSwitchCoordinator, chatSwitch)
        .task(id: mainChatID) { await chatSwitch.show(mainChatID, reduceMotion: reduceMotion, waitForMount: true) }
        .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.showingHome.toggle(); model.showingSettings = false } label: {
                        Label(model.showingHome ? "Back to Chat" : "Home", systemImage: model.showingHome ? "arrow.left" : "house")
                    }
                    .help(model.showingHome ? "Return to the open thread" : "Home: full-window thread cards")
                    .accessibilityLabel(model.showingHome ? "Back to Chat" : "Home")
                }
                ToolbarItem {
                    Button { model.showingCommandCenter.toggle() } label: {
                        Label("Command Center", systemImage: "rectangle.split.2x2")
                    }.help("Several live chats in one window").accessibilityLabel("Command Center")
                }
                ToolbarItem {
                    Button { model.showingSettings.toggle() } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Settings (\u{2318},)")
                }
                ToolbarItem {
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
                        Button("New Studio\u{2026}") { beginNewStudio() }
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    } primaryAction: {
                        model.newChat()
                    }
                    .help("New chat (\u{2318}N). Hold to pick Claude, Codex, or a project folder.")
                }
            }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebarToggleRequest += 1 } label: { Image(systemName: "sidebar.left") }
                    .help("Show or hide sidebar").accessibilityLabel("Toggle sidebar")
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }

    private var splitView: some View {
        @Bindable var model = model
        return AnyView(columnRoot)
        .modifier(ThemedWindow(scheme: themeScheme, background: themeBackground, highlight: themeHighlight))
        .frame(minWidth: 640, minHeight: 520)
        .background(ChatWindowReader { model.mainChatWindow = $0 })
        .onAppear { model.revealMainChatWindow = { openWindow(id: "main") } }
        .sheet(isPresented: $model.showingCloneFromGitHub) { CloneFromGitHubView() }
        .sheet(isPresented: $model.showingNewProject) { NewProjectSheet().environment(model) }
        .sheet(isPresented: $model.editingDotMemory) { DotMemorySheet() }
        // Dot asked to show you its computer.
        .onReceive(NotificationCenter.default.publisher(for: .showDotComputer)) { _ in openWindow(id: DotComputerPanel.windowID) }
        .sheet(item: $model.pinSheet) { AddPinSheet(request: $0) }
        .sheet(isPresented: Binding(get: { model.editingStudioInstructions != nil },
                                    set: { if !$0 { model.editingStudioInstructions = nil } })) {
            if let studio = model.studio(model.editingStudioInstructions) {
                StudioInstructionsSheet(studio: studio).environment(model)
            }
        }
        .modifier(WorktreeAlerts(parent: $worktreeParent, name: $worktreeName, removing: $removingWorktree, error: $worktreeError))
        .alert("Rename Chat", isPresented: Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })) {
            TextField("Title", text: $chatTitle)
            Button("Rename") {
                guard let chat = renamingChat else { return }
                chat.setTitle(chatTitle)
                // A project's row shows the project's name, not the chat title, so renaming
                // only the title looked like it did nothing. One chat per folder: rename both.
                if chat.record.projectFolder != nil { chat.setProjectNickname(chatTitle) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if renamingChat?.record.projectFolder != nil {
                Text("Also renames the project in the sidebar and toolbar. The folder itself isn't renamed.")
            }
        }
        .modifier(StudioCreationAlerts(naming: $namingStudio, name: $studioName, source: $studioFromChat, destination: studioDestinationID))
        .alert("Rename Studio", isPresented: Binding(get: { renamingStudio != nil }, set: { if !$0 { renamingStudio = nil } })) {
            TextField("Name", text: $studioName)
            Button("Rename") { if let studio = renamingStudio { model.renameStudio(studio.id, to: studioName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder itself isn't renamed.")
        }
        .alert("Rename Project", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("Name", text: $projectNickname)
            Button("Rename") { renamingProject?.setProjectNickname(projectNickname) }
            if renamingProject?.record.projectNickname != nil {
                Button("Use Folder Name") { renamingProject?.setProjectNickname("") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown in the sidebar and toolbar. The folder itself isn't renamed.")
        }
        .background {
            Color.clear.sheet(isPresented: Binding(get: { ChatCommands.shared.showingQuickSwitcher },
                                                   set: { ChatCommands.shared.showingQuickSwitcher = $0 })) {
                QuickSwitcher().environment(model)
            }
        }
        .alert("New Tag", isPresented: Binding(get: { taggingSession != nil }, set: { if !$0 { taggingSession = nil } })) {
            TextField("Tag name", text: $newTag)
            Button("Add") {
                let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tag.isEmpty, let session = taggingSession, !session.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    session.toggleTag(tag)
                }
                newTag = ""
            }
            Button("Cancel", role: .cancel) { newTag = "" }
        } message: {
            Text("Tags show as pills under the project name.")
        }
        .confirmationDialog("Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D}?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { session in
            Button("Delete Chat", role: .destructive) { model.delete(session) }
            Button("Archive Instead") { model.archive(session) }
        } message: { _ in
            Text("The conversation and its attachments are removed permanently. Archiving keeps them out of the way instead.")
        }
        .task { await model.refreshProjectRepos() }
        .task { Attention.shared.start(model: model) }
        .onChange(of: model.selectedID) { _, id in
            Diagnostics.signposts.emitEvent("Chat picked")
            // Picking a chat leaves Settings.
            model.showingSettings = false
            if let session = model.selected, Attention.shared.isWatching(session) { Attention.shared.markSeen(id) }
            // A chat you open (like a new one) never hides behind the search or tag filter.
            if let session = model.sessions.first(where: { $0.id == id }), !isShown(session) {
                searchText = ""
                tagFilter = ""
            }
        }
        .onAppear(perform: watchCommandKey)
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }
}

extension ContentView {
    /// The tag filter, ignored once no chat has that tag anymore.
    private var activeTag: String? {
        tagFilter.isEmpty ? nil : model.allTags.first { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
    }

    private var isFiltering: Bool {
        activeTag != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search matches every word against the chat title, project name, and tags.
    private func isShown(_ session: ChatSession) -> Bool {
        if session.record.sidechatOf == nil, model.sidechats(of: session).contains(where: isShown) { return true }
        if session.record.convertedProjectFolder != nil, model.worktrees(of: session).contains(where: isShown) { return true }
        if let tag = activeTag, !session.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            return false
        }
        let text = ([session.title, session.projectName, model.studio(for: session)?.name ?? ""] + session.tags).joined(separator: " ")
        return matchesSearch(text)
    }

    private func matchesSearch(_ text: String) -> Bool {
        searchText.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains($0) }
    }

    /// A Studio shows while any of its chats do, or, with no tag filter, when it has none yet.
    private func isShown(_ studio: Studio) -> Bool {
        let chats = model.chats(in: studio)
        if chats.contains(where: isShown) { return true }
        return activeTag == nil && chats.isEmpty && matchesSearch(studio.name)
    }

    private func beginNewStudio(from session: ChatSession? = nil, destination: UUID? = nil) {
        studioDestinationID = destination
        studioFromChat = session
        studioName = session?.record.projectFolder != nil ? (session?.projectName ?? "") : ""
        namingStudio = true
    }

    /// A Studio as a group that opens to show its chats.
    private func studioGroup(_ studio: Studio, numbers: [UUID: Int]) -> some View {
        let chats = model.chats(in: studio)
        let expanded = Binding(get: { isFiltering || studio.collapsed != true },
                               set: { model.setStudio(studio.id, collapsed: !$0) })
        return DisclosureGroup(isExpanded: expanded) {
            if sidebarCards {
                cardGrid(chats.flatMap(cardFamily))
                    .dropDestination(for: String.self) { ids, _ in drop(ids, into: studio) }
            } else {
                ForEach(chats.filter(isShown)) { session in
                    // Dropping onto a chat in the Studio moves the dragged one in too.
                    rowWithSidechats(session, numbers: numbers)
                        .dropDestination(for: String.self) { ids, _ in drop(ids, into: studio) }
                }
            }
            if chats.isEmpty {
                Button { model.newChat(in: studio) } label: {
                    Label("New Chat", systemImage: "square.and.pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } label: {
            let place = PinPlace(key: "studio:" + studio.id.uuidString, name: studio.name)
            StudioRow(studio: studio, chats: chats, collapsed: !expanded.wrappedValue,
                      isDropTarget: dropStudio == studio.id, pins: PinStore.shared.pins(in: place),
                      onOpenPin: {
                          // Beside a page, the Studio's own chat (the one open, or its latest).
                          if model.selected?.record.studioID != studio.id, let latest = chats.first { model.selectedID = latest.id }
                      },
                      onNewChat: { model.newChat(in: studio) })
                .contentShape(Rectangle())
                .onTapGesture { expanded.wrappedValue.toggle() }
                // Drop a chat here to move it in.
                .dropDestination(for: String.self) { ids, _ in
                    drop(ids, into: studio)
                } isTargeted: { over in
                    if over { dropStudio = studio.id } else if dropStudio == studio.id { dropStudio = nil }
                }
                .contextMenu {
                    Button("New Claude Chat") { model.newChat(in: studio, backend: .claude) }
                    Button("New Codex Chat") { model.newChat(in: studio, backend: .codex) }
                    Divider()
                    Button("Studio Instructions\u{2026}") { model.editingStudioInstructions = studio.id }
                    Button("Edit design.md") { studio.ensureDesignFile(); openForEditing(studio.designFile) }
                    Button("Add Pin\u{2026}") { model.pinSheet = PinSheetRequest(place: place, current: place) }
                    Button("Rename Studio\u{2026}") {
                        studioName = studio.name
                        renamingStudio = studio
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: studio.folder)]) }
                    Button("Open Terminal Here") { model.openTerminal(at: studio.folder) }
                    Divider()
                    Button("Archive Studio") { model.archiveStudio(studio.id) }
                }
                .help(studio.folder)
        }
    }

    /// Dot at the top of the sidebar: click to open it full size.
    /// A message's first lines without Markdown marks, for a one-glance preview.
    static func plainPreview(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*(#+|[-*])\s+"#, with: "", options: .regularExpression)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
    }

    #if GOLEM_APP
    private var dotRow: some View {
        let dot = model.dot
        let selected = dot != nil && model.selectedID == dot?.id
        let unread = dot.map(Attention.shared.dotUnreadCount) ?? 0
        let latest = unread > 0 ? dot.flatMap(Attention.shared.dotLatestUnread) : nil
        return HStack(spacing: 12) {
            GolemHead(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.dotName).font(.system(size: 15, weight: unread > 0 ? .bold : .semibold))
                if let latest {
                    // The newest unread message, in full color, so it reads as news.
                    Text(Self.plainPreview(latest)).font(.caption).foregroundStyle(.primary).lineLimit(2)
                } else {
                    Text(dot?.lastActionSummary ?? "Runs your chats for you. \u{2318}J from anywhere.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if unread > 0 {
                Text(unread == 1 ? "1 new" : "\(unread) new")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.onHighlight)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.highlight))
                    .help("\(unread) unread \(unread == 1 ? "message" : "messages") from \(model.dotName)")
            }
            if dot?.isWaitingOnYou == true {
                Circle().fill(Color.yellow).frame(width: 7, height: 7)
            } else if dot?.isRunning == true {
                ActivitySpinner(color: .secondary).frame(width: 10, height: 10)
            }
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .environment(\.colorScheme, selected ? .light : colorScheme)
        .onTapGesture { model.openDot() }
        .listRowBackground(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.white : Color.highlight.opacity(unread > 0 ? 0.14 : 0))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.highlight.opacity(unread > 0 && !selected ? 0.5 : 0), lineWidth: 1))
            .padding(.horizontal, 10))
        .contextMenu {
            Button("Open \(model.dotName)") { model.openDot() }
            if let dot {
                RestartThreadControl(session: dot)
                NewSidechatControl(parent: dot)
            }
            Button("Rename\u{2026}") { dotName = model.dotName; renamingDot = true }
            Button(model.showingDot ? "Hide Mini Window" : "Show Mini Window  \u{2318}J") { model.showingDot.toggle() }
        }
        .help("\(model.dotName) runs your other chats: ask it to check on a project, hand work to a chat, or start one.")
        .alert("Rename \(model.dotName)", isPresented: $renamingDot) {
            TextField("Name", text: $dotName)
            Button("Rename") { model.renameDot(dotName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its name everywhere in Chatterbox, and what it's told it's called.")
        }
    }

    /// Moves dragged chats into a Studio. Project chats stay with their projects.
    #endif

    private func drop(_ ids: [String], into studio: Studio) -> Bool {
        dropStudio = nil
        let moved = ids.compactMap(UUID.init(uuidString:))
            .compactMap { id in model.sessions.first { $0.id == id } }
            .filter { $0.record.projectFolder == nil && $0.record.studioID != studio.id }
        for session in moved { model.move(session, to: studio) }
        return !moved.isEmpty
    }

    private var tagFilterMenu: some View {
        Menu {
            Picker("Sort By", selection: $projectSort) {
                ForEach(ProjectSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Activity", selection: $projectActivity) {
                ForEach(ProjectActivity.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Tags", selection: Binding(get: { activeTag ?? "" }, set: { tagFilter = $0 })) {
                Text("All Tags").tag("")
                ForEach(model.allTags, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: activeTag == nil && projectActivity == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort and filter projects")
    }

    /// Holding ⌘ alone shows the ⌘1–⌘9 badges right away; any other key or release hides them.
    private func watchCommandKey() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let onlyCommand = event.type == .flagsChanged
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if showShortcuts != onlyCommand { showShortcuts = onlyCommand }
            return event
        }
    }

    private func rowWithSidechats(_ session: ChatSession, numbers: [UUID: Int]) -> some View {
        Group {
            row(session, number: numbers[session.id])
            ForEach(model.sidechats(of: session).filter(isShown)) { sidechat in
                row(sidechat, number: numbers[sidechat.id])
                    .padding(.leading, 18)
                    .overlay(alignment: .leading) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
            }
            if session.record.convertedProjectFolder != nil {
                ForEach(model.worktrees(of: session)) { worktree in
                    row(worktree, number: numbers[worktree.id])
                        .padding(.leading, 18)
                        .overlay(alignment: .leading) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    ForEach(model.sidechats(of: worktree).filter(isShown)) { sidechat in
                        row(sidechat, number: numbers[sidechat.id]).padding(.leading, 36)
                    }
                }
            }
        }
    }

    private func row(_ session: ChatSession, number: Int?, card: Bool = false, expanded: Bool = false) -> some View {
        let place = session.record.projectFolder != nil ? model.pinPlace(for: session) : nil
        return Group {
            if card || sidebarCards {
                ThreadCard(session: session, expanded: expanded, selected: model.selectedID == session.id) {
                    model.selectedID = session.id
                }
            } else {
                SidebarRow(session: session, shortcut: showShortcuts ? number : nil, pins: PinStore.shared.pins(in: place),
                           onOpenPin: { model.selectedID = session.id })
            }
        }
            // Drop a link or file on a project to pin it there.
            .onDrop(of: [.url, .fileURL], isTargeted: nil) { providers in
                guard let place else { return false }
                return PinPills.drop(providers, into: place)
            }
            .contentShape(Rectangle())
            // The open chat is white with dark text, so it's obvious at a glance; drawn in the
            // light appearance so its secondary text and pills stay readable on white.
            .environment(\.colorScheme, model.selectedID == session.id && !session.isWaitingOnYou ? .light : colorScheme)
            .onTapGesture { model.selectedID = session.id }
            // Drag onto a Studio to move the chat in. Project chats stay put.
            .modifier(ChatDrag(id: session.record.projectFolder == nil ? session.id : nil))
            .listRowBackground(
                // Waiting on you wins over selection: the whole row turns yellow.
                RoundedRectangle(cornerRadius: 8)
                    .fill(session.isWaitingOnYou ? Color.yellow.opacity(0.22)
                          : model.selectedID == session.id ? Color.white : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.yellow.opacity(session.isWaitingOnYou ? 0.7 : 0), lineWidth: 1))
                    .padding(.horizontal, 10)
            )
            .contextMenu {
                Button("Rename Chat\u{2026}") {
                    // Start from the name the row shows.
                    chatTitle = session.record.projectFolder != nil ? session.projectName : session.title
                    renamingChat = session
                }
                RestartThreadControl(session: session)
                if session.record.projectFolder == nil, !session.items.isEmpty {
                    Button("Fork Chat") { model.fork(session) }
                        .disabled(!model.canFork(session))
                }
                if let folder = session.record.projectFolder {
                    if let place {
                        Button("Add Pin\u{2026}") { model.pinSheet = PinSheetRequest(place: place, current: place) }
                    }
                    if session.record.worktreeOf == nil {
                        Button("New Worktree\u{2026}") { worktreeName = ""; worktreeParent = session }
                    } else {
                        Button("Remove Worktree\u{2026}") { removingWorktree = session }
                    }
                    Button("Rename Project\u{2026}") {
                        projectNickname = session.projectName
                        renamingProject = session
                    }
                    if session.record.worktreeOf == nil, session.record.archivedAt == nil {
                        Button("Convert to Studio\u{2026}") { beginNewStudio(from: session) }
                            .disabled(session.isRunning || session.isRestartingThread)
                    }
                    Menu("Tags") {
                        ForEach(model.allTags, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(get: { session.tags.contains(tag) }, set: { _ in session.toggleTag(tag) }))
                        }
                        if !model.allTags.isEmpty { Divider() }
                        Button("New Tag\u{2026}") { taggingSession = session }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                    Button("Unbind from Folder") { session.unbindProject() }
                    Divider()
                }
                if session.record.archivedAt == nil, session.record.projectFolder == nil, session.record.sidechatOf == nil {
                    Menu("Move to Studio") {
                        ForEach(model.activeStudios) { studio in
                            Button(studio.name) { beginNewStudio(from: session, destination: studio.id) }
                                .disabled(studio.id == session.record.studioID)
                        }
                        if !model.activeStudios.isEmpty { Divider() }
                        Button("New Studio\u{2026}") { beginNewStudio(from: session) }
                        if model.studio(for: session) != nil {
                            Divider()
                            Button("Remove from Studio") { model.move(session, to: nil) }
                        }
                    }
                    .disabled(session.isRunning)
                }
                if session.record.archivedAt == nil {
                    NewSidechatControl(parent: session)
                    Button(session.record.sidechatOf != nil ? "End Sidechat" : "Archive Chat") { model.archive(session) }
                } else {
                    Button("Unarchive Chat") { model.unarchive(session) }
                }
                Divider()
                Button("Delete Chat\u{2026}", role: .destructive) { pendingDelete = session }
            }
    }
}

private struct StudioCreationAlerts: ViewModifier {
    @Binding var naming: Bool
    @Binding var name: String
    @Binding var source: ChatSession?
    var destination: UUID?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $naming, onDismiss: { source = nil }) {
            StudioDestinationSheet(source: source, initialName: name, destination: destination)
        }
    }
}

#if DEBUG
@MainActor enum StudioDestinationDebug {
    static var rootOrigin = CGPoint.zero
    static var folderFrame = CGRect.zero
    static var moveFrame = CGRect.zero
}
#endif

struct StudioDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: ChatSession?
    @State private var name: String
    @State private var destination: UUID?
    @State private var keepFolder = true
    @State private var error: String?

    init(source: ChatSession?, initialName: String, destination: UUID? = nil) {
        self.source = source
        _name = State(initialValue: initialName)
        _destination = State(initialValue: destination)
    }

    private var studio: Studio? { destination.flatMap { model.studio($0) } }
    private var isProject: Bool { source?.record.projectFolder != nil || source?.record.convertedProjectFolder != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(source == nil ? "New Studio" : "Move to Studio").font(.title2.bold())
            if source != nil {
                Picker("Destination", selection: $destination) {
                    Text("New Studio").tag(nil as UUID?)
                    ForEach(model.activeStudios) { studio in
                        Text(studio.name).tag(Optional(studio.id))
                    }
                }
                .accessibilityIdentifier("studioDestination")
            }
            if destination == nil {
                TextField("Studio name", text: $name).textFieldStyle(.roundedBorder)
            }
            if let source, let studio {
                Picker("Working folder", selection: $keepFolder) {
                    Text("Keep current folder").tag(true)
                    Text("Use Studio folder").tag(false)
                }.pickerStyle(.segmented)
                .accessibilityIdentifier("studioFolderChoice")
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { StudioDestinationDebug.folderFrame = $0 }
                #endif
                Text(keepFolder ? source.workingFolder : studio.folder)
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(keepFolder ? "The thread joins this Studio and continues working in its current folder." : "The thread will work in the Studio’s shared folder. Changing folders resets Claude’s session; your visible history stays.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let source, isProject {
                let folder = source.workingFolder
                Text("The new Studio uses your existing folder: \(folder)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if source != nil {
                Text("History and drafts stay. No files move. Worktrees and Sidechats keep their own working folders.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(destination == nil ? (isProject ? "Convert" : "Create") : "Move") { submit() }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("studioMove")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { StudioDestinationDebug.moveFrame = $0 }
                    #endif
            }
        }
        .padding(24).frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        #if DEBUG
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { StudioDestinationDebug.rootOrigin = $0 }
        #endif
    }

    private func submit() {
        guard destination == nil || studio != nil else { error = "This Studio is no longer available. Choose another destination."; return }
        let result: Studio?
        if let studio, let source {
            if isProject {
                result = model.convertProjectToStudio(source, into: studio, keepFolder: keepFolder)
            } else {
                result = model.joinStudio(source, studio: studio, keepFolder: keepFolder) ? studio : nil
            }
        } else if let source, isProject {
            result = model.convertProjectToStudio(source, named: name)
        } else {
            result = model.newStudio(named: name, moving: source)
        }
        if result != nil { dismiss() }
        else { error = "Couldn’t move this thread. Finish its reply or restart and check that both folders still exist." }
    }
}

struct NewSidechatControl: View {
    @Environment(AppModel.self) private var model
    let parent: ChatSession

    var body: some View {
        Button("New Sidechat", systemImage: "bubble.left.and.bubble.right") { model.newSidechat(of: parent) }
            .help("A temporary separate thread in the same folder; no Git branch is created")
    }
}

/// Lets a chat row be dragged onto a Studio; `nil` (a project chat) isn't draggable.
private struct ChatDrag: ViewModifier {
    let id: UUID?

    func body(content: Content) -> some View {
        if let id { content.draggable(id.uuidString) } else { content }
    }
}

/// A Studio's heading in the sidebar. While it's collapsed it shows whether a chat inside
/// is working or waiting on you.
private struct StudioRow: View {
    let studio: Studio
    let chats: [ChatSession]
    let collapsed: Bool
    var isDropTarget = false
    var pins: [Pin] = []
    var onOpenPin: () -> Void = {}
    var onNewChat: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            heading
            if !pins.isEmpty { PinPills(pins: pins, onOpen: onOpenPin).padding(.leading, 20) }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.highlight.opacity(isDropTarget ? 0.12 : 0))
            .padding(.horizontal, -6))
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Image(systemName: "paintpalette")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(studio.name).lineLimit(1)
            Spacer(minLength: 0)
            if collapsed {
                if chats.contains(where: \.isWaitingOnYou) {
                    Circle().fill(Color.yellow).frame(width: 7, height: 7).help("A chat here is waiting on you")
                } else if chats.contains(where: { $0.isRunning || $0.hasBackgroundWork }) {
                    ActivitySpinner(color: .secondary).frame(width: 10, height: 10).help("A chat here is working")
                } else if !chats.isEmpty {
                    Text("\(chats.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Button(action: onNewChat) { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("New chat in \(studio.name)")
                .accessibilityLabel("New Chat in \(studio.name)")
        }
    }
}

private struct SidebarRow: View {
    /// Centers a shape (spinner, dot) on the first line of text, which it's baseline-aligned
    /// with; shapes have no baseline, so they'd otherwise sit on it and look low.
    static func centerOnTextLine(_ d: ViewDimensions) -> CGFloat { d.height / 2 + 4 }

    let session: ChatSession
    /// Shown while ⌘ is held.
    var shortcut: Int?
    /// A project's own pins, shown as pills under its name.
    var pins: [Pin] = []
    /// Called before a pill opens, so the page opens with this chat beside it.
    var onOpenPin: () -> Void = {}
    private let appearance = ReaderStyleSettings()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(session.record.backend.iconName)
                .resizable().scaledToFit().frame(width: 11, height: 11)
                .accessibilityLabel(session.record.backend.label)
                .foregroundStyle(.secondary)
                .help(session.record.backend.label)
            if session.record.projectFolder != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName).lineLimit(1)
                    if !session.tags.isEmpty {
                        TagPills(tags: session.tags)
                    }
                    if !pins.isEmpty {
                        PinPills(pins: pins, onOpen: onOpenPin)
                    }
                    // What happened last, rather than the chat's title.
                    if let summary = session.lastActionSummary ?? (session.title != "New chat" ? session.title : nil) {
                        Text(summary).font(.caption.weight(session.isWaitingOnYou ? .semibold : .regular))
                            .foregroundStyle(session.isWaitingOnYou ? Color.yellow : Color.secondary).lineLimit(1)
                            .help(session.title)
                    }
                }
                .help(session.record.projectFolder ?? "")
            } else {
                Text(session.title)
                    .lineLimit(1)
            }
            if session.record.sidechatOf != nil {
                Text("Temporary").font(.caption2).foregroundStyle(.secondary)
                    .help("A sidechat sharing its parent's folder. End Sidechat archives its history.")
            }
            Spacer(minLength: 0)
            // Waiting on you, or a finished reply you haven't seen.
            if Attention.shared.unread.contains(session.id)
                || session.items.contains(where: { ($0.kind == .approval || $0.kind == .questions) && $0.approvalState == .pending }) {
                Circle().fill(Color.highlight).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline, computeValue: Self.centerOnTextLine)
                    .help("Needs your attention")
            }
            if let shortcut {
                Text("\u{2318}\(shortcut)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    .foregroundStyle(.secondary)
            } else if session.isRunning {
                if let started = session.record.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let minutes = Int(context.date.timeIntervalSince(started)) / 60
                        if minutes >= 1 {
                            Text("\(minutes)m").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                ActivitySpinner(color: appearance.style.color(for: session.record.backend))
                    .frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline, computeValue: Self.centerOnTextLine)
                    .help("\(session.record.backend.label) is working")
            } else if session.hasBackgroundWork {
                // The reply is done, but a subagent or command is still going.
                ActivitySpinner(color: .secondary)
                    .frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline, computeValue: Self.centerOnTextLine)
                    .help("Running in the background: \(session.backgroundTasks.map(\.title).joined(separator: ", "))")
            } else if session.record.projectFolder != nil {
                // How long the project has been quiet; faded once it's gone stale.
                let stale = session.isStale
                Text(ShortAge.string(since: session.lastActivity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(stale ? .tertiary : .secondary)
                    .help("Last active \(session.lastActivity.formatted(.relative(presentation: .named)))" + (stale ? " (stale)" : ""))
            }
        }
    }
}

/// A project's tags as small colored pills, wrapping onto more lines if needed.
struct TagPills: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Self.color(for: tag).opacity(0.22)))
                    .foregroundStyle(Self.color(for: tag))
            }
        }
    }

    /// The same tag always gets the same color.
    static func color(for tag: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .brown]
        let hash = tag.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

/// Lays children out left to right, wrapping to a new line when a row fills up.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The sidebar on a chosen background.
private struct ThemedSidebar: ViewModifier {
    let background: String
    func body(content: Content) -> some View {
        let color = Theme.sidebar(background)
        content
            .scrollContentBackground(color == nil ? .automatic : .hidden)
            .background(color ?? .clear)
    }
}

/// The chat side, and the toolbar over it, on a chosen background.
private struct ThemedDetail: ViewModifier {
    let background: String
    func body(content: Content) -> some View {
        let color = Theme.background(background)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color ?? .clear)
            .toolbarBackground(color ?? .clear, for: .windowToolbar)
            .toolbarBackground(color == nil ? .automatic : .visible, for: .windowToolbar)
    }
}

/// Light or dark, and the highlight. Colors are read as views draw, so a change redraws all.
private struct ThemedWindow: ViewModifier {
    let scheme: String
    let background: String
    let highlight: String
    func body(content: Content) -> some View {
        content
            .id(background + "|" + highlight)
            .preferredColorScheme(Theme.colorScheme(background: background, scheme: scheme))
            .tint(highlight == "default" ? nil : Color.highlight)
    }
}


// MARK: - The sidebar's layout

/// The three resizable parts of the sidebar under Golem and the pins.
enum SidebarSection: Int, CaseIterable {
    case projects, studios, chats

    var title: String { ["Projects", "Studios", "Chats"][rawValue] }
    var icon: String { ["folder", "paintpalette", "bubble.left.and.bubble.right"][rawValue] }
}

extension ContentView {
    /// Golem fixed at the top, the pins, then Projects, Studios, and Chats sharing the rest:
    /// a third each to start, each scrolling on its own, resized by dragging the dividers
    /// between them. A collapsed Studios or Chats moves to the dock at the bottom, beside
    /// Archived; a collapsed Projects keeps its heading in place.
    var sidebarColumn: some View {
        VStack(spacing: 0) {
            DesktopOverviewControls().padding(.horizontal, 12).padding(.vertical, 8)
            if !isFiltering {
                #if GOLEM_APP
                List { Section { dotRow } }
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                #endif
                PinsSection(place: model.selectedPinPlace) { model.pinSheet = $0 }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            GeometryReader { geometry in
                sectionStack(height: geometry.size.height)
            }
            sidebarDock
        }
    }

    private var weights: [Double] {
        let parsed = sectionWeights.split(separator: ",").compactMap { Double($0) }
        return parsed.count == 3 && parsed.allSatisfy({ $0 > 0 }) ? parsed : [1, 1, 1]
    }

    private func isCollapsed(_ section: SidebarSection) -> Bool {
        switch section {
        case .projects: projectsCollapsed
        case .studios: studiosCollapsed
        case .chats: chatsCollapsed
        }
    }

    private func setCollapsed(_ section: SidebarSection, _ value: Bool) {
        withAnimation(.smooth(duration: 0.25)) {
            switch section {
            case .projects: projectsCollapsed = value
            case .studios: studiosCollapsed = value
            case .chats: chatsCollapsed = value
            }
        }
    }

    /// Searching shows every section, so nothing that matches is hidden in the dock.
    private var shownSections: [SidebarSection] {
        SidebarSection.allCases.filter { isFiltering || $0 == .projects || !isCollapsed($0) }
    }

    private static let headerHeight: CGFloat = 26
    private static let dividerHeight: CGFloat = 7
    private static let minimumList: CGFloat = 44

    @ViewBuilder
    private func sectionStack(height: CGFloat) -> some View {
        let shown = shownSections
        let open = shown.filter { isFiltering || !isCollapsed($0) }
        let chrome = CGFloat(shown.count) * Self.headerHeight + CGFloat(max(0, shown.count - 1)) * Self.dividerHeight
        let space = max(0, height - chrome)
        let total = open.map { weights[$0.rawValue] }.reduce(0, +)
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, section in
                if index > 0 {
                    divider(above: shown[index - 1], below: section, space: space, open: open)
                }
                sectionHeader(section)
                if open.contains(section) {
                    sectionList(section)
                        .frame(height: total > 0 ? space * weights[section.rawValue] / total : 0)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Headers

    private func sectionHeader(_ section: SidebarSection) -> some View {
        let collapsed = !isFiltering && isCollapsed(section)
        return HStack(spacing: 6) {
            Button { setCollapsed(section, !collapsed) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(section.title).font(.subheadline.weight(.semibold))
                    if collapsed { Text("\(count(of: section))").font(.caption).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(collapsed ? "Show \(section.title)" : "Collapse \(section.title)\(section == .projects ? "" : " to the bottom")")
            .accessibilityLabel(section.title)
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(collapsed ? "Shows the section" : "Collapses the section")
            Spacer()
            switch section {
            case .projects: tagFilterMenu
            case .studios:
                Button { beginNewStudio() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New Studio").accessibilityLabel("New Studio")
            case .chats:
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New Chat").accessibilityLabel("New Chat")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
    }

    private func count(of section: SidebarSection) -> Int {
        switch section {
        case .projects: model.sidebarProjects.count
        case .studios: model.activeStudios.count
        case .chats: model.sidebarChats.count
        }
    }

    // MARK: Lists

    @ViewBuilder
    private func sectionList(_ section: SidebarSection) -> some View {
        if sidebarCards { cardSection(section) } else { listSection(section) }
    }

    private func cardFamily(_ root: ChatSession) -> [ChatSession] {
        var threads = [root] + model.sidechats(of: root)
        if root.record.projectFolder != nil || root.record.convertedProjectFolder != nil {
            for branch in model.worktrees(of: root) { threads += [branch] + model.sidechats(of: branch) }
        }
        return threads.filter(isShown)
    }

    private func cardGrid(_ threads: [ChatSession]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 8) {
            ForEach(threads) { row($0, number: nil, card: true) }
        }
    }

    private func cardSection(_ section: SidebarSection) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch section {
                case .projects:
                    let threads = model.sidebarProjects.filter(projectActivity.includes).flatMap(cardFamily)
                    cardGrid(threads)
                    if threads.isEmpty { Text("No matching projects").font(.caption).foregroundStyle(.secondary) }
                case .chats:
                    let threads = model.sidebarChats.flatMap(cardFamily)
                    cardGrid(threads)
                    if threads.isEmpty { Text("No matching chats").font(.caption).foregroundStyle(.secondary) }
                case .studios:
                    ForEach(model.activeStudios.filter(isShown)) { studio in
                        studioGroup(studio, numbers: [:])
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.accessibilityLabel(section.title)
    }

    private func listSection(_ section: SidebarSection) -> some View {
        // ⌘-numbers follow the full sidebar, so they don't shift while filtering.
        let numbers = Dictionary(uniqueKeysWithValues: model.sidebarOrder.prefix(9).enumerated().map { ($1.id, $0 + 1) })
        return List {
            switch section {
            case .projects:
                let projects = model.sidebarProjects.filter(isShown).filter(projectActivity.includes)
                ForEach(projects) { session in
                    rowWithSidechats(session, numbers: numbers)
                    // Its worktrees, indented beneath it.
                    ForEach(model.worktrees(of: session)) { worktree in
                        rowWithSidechats(worktree, numbers: numbers)
                            .padding(.leading, 18)
                            .overlay(alignment: .leading) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                    .padding(.leading, 2)
                            }
                    }
                }
                if projects.isEmpty {
                    Text(isFiltering || activeTag != nil || projectActivity != .all ? "No matching projects" : "Open or create a project from the + menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .studios:
                let studios = model.activeStudios.filter(isShown)
                ForEach(studios) { studio in studioGroup(studio, numbers: numbers) }
                if studios.isEmpty {
                    Text(isFiltering ? "No matching Studios" : "A Studio groups chats that share one folder, for messy work that isn't a project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .chats:
                let chats = model.sidebarChats.filter(isShown)
                ForEach(chats) { session in rowWithSidechats(session, numbers: numbers) }
                if chats.isEmpty {
                    Text(isFiltering ? "No matching chats" : "Chats that aren't in a project or a Studio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityLabel(section.title)
    }

    // MARK: Dividers

    /// Dragging the line between two sections moves space from one to the other. Only open
    /// sections take part; a collapsed Projects heading just sits between them.
    private func divider(above: SidebarSection, below: SidebarSection, space: CGFloat, open: [SidebarSection]) -> some View {
        let upper = open.last { $0.rawValue <= above.rawValue }
        let lower = open.first { $0.rawValue >= below.rawValue }
        let active = upper != nil && lower != nil && upper != lower
        return ZStack {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if active {
                Capsule().fill(Color.primary.opacity(0.18)).frame(width: 28, height: 3).opacity(0.0001)
            }
        }
        .frame(height: Self.dividerHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SidebarDebug.dividers[above.title] = $0 }
        #endif
        // AppKit owns the drag, so the lists around it can't take it, and the cursor is right.
        .overlay {
            if active, let upper, let lower {
                DividerHandle(
                    onDrag: { dy in
                        let start = dragStartWeights ?? weights
                        if dragStartWeights == nil { dragStartWeights = start }
                        let total = open.map { start[$0.rawValue] }.reduce(0, +)
                        guard total > 0, space > 0 else { return }
                        // Points to weight, keeping each side at least a few rows tall.
                        let perPoint = total / Double(space)
                        let pair = start[upper.rawValue] + start[lower.rawValue]
                        let minimum = Double(Self.minimumList) * perPoint
                        let top = min(max(start[upper.rawValue] + Double(dy) * perPoint, minimum), pair - minimum)
                        var next = start
                        next[upper.rawValue] = top
                        next[lower.rawValue] = pair - top
                        sectionWeights = next.map { String(format: "%.4f", $0) }.joined(separator: ",")
                    },
                    onEnd: { dragStartWeights = nil },
                    onDoubleClick: {
                        // Double-click a divider to even the sections out again.
                        withAnimation(.smooth(duration: 0.25)) { sectionWeights = "1,1,1" }
                    })
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Resize \(above.title) and \(below.title)")
        .accessibilityHint("Drag up or down. Double-click to make the sections equal.")
        .accessibilityAdjustableAction { direction in
            guard let upper, let lower else { return }
            var next = weights
            let step = 0.1 * (next[upper.rawValue] + next[lower.rawValue])
            let delta = direction == .increment ? step : -step
            guard next[upper.rawValue] + delta > 0.05, next[lower.rawValue] - delta > 0.05 else { return }
            next[upper.rawValue] += delta
            next[lower.rawValue] -= delta
            sectionWeights = next.map { String(format: "%.4f", $0) }.joined(separator: ",")
        }
    }

    // MARK: The dock

    /// Archived, and any collapsed Studios or Chats, as buttons along the bottom. Full labels
    /// when they fit; icons and counts when the sidebar is narrow.
    private var sidebarDock: some View {
        let archived = model.archivedSessions.filter(isShown)
        let docked = isFiltering ? [] : [SidebarSection.studios, .chats].filter(isCollapsed)
        return ViewThatFits(in: .horizontal) {
            dockRow(docked: docked, archived: archived, labels: true)
            dockRow(docked: docked, archived: archived, labels: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private func dockChip(_ title: String, count: Int, icon: String, label: Bool, selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label ? "\(title) \(count)" : "\(count)")
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(selected ? 0.14 : 0.08)))
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
    }

    private func dockRow(docked: [SidebarSection], archived: [ChatSession], labels: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(docked, id: \.self) { section in
                Button { setCollapsed(section, false) } label: {
                    dockChip(section.title, count: count(of: section), icon: section.icon, label: labels)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show \(section.title)")
                .accessibilityHint("Shows the section")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if !archived.isEmpty {
                Button { showArchived.toggle() } label: {
                    dockChip("Archived", count: archived.count, icon: "archivebox", label: labels, selected: showArchived)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Archived chats")
                .popover(isPresented: $showArchived, arrowEdge: .top) {
                    List {
                        ForEach(archived) { session in row(session, number: nil) }
                    }
                    .frame(width: 300, height: min(420, CGFloat(archived.count) * 52 + 20))
                }
            }
        }
    }
}

#if DEBUG
/// Where each divider is drawn, for interaction tests.
@MainActor enum SidebarDebug { static var dividers: [String: CGRect] = [:] }
#endif

/// The grab area of a divider between sidebar sections: drag to resize (reports how far the
/// pointer has moved down since the press), double-click to reset.
private struct DividerHandle: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag; view.onEnd = onEnd; view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        private var startY: CGFloat?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { startY = nil; onDoubleClick?(); return }
            startY = screenY(event)
        }

        private func screenY(_ event: NSEvent) -> CGFloat {
            window.map { $0.convertPoint(toScreen: event.locationInWindow).y } ?? event.locationInWindow.y
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startY else { return }
            // Screen coordinates rise upward; a drag down makes the upper section taller.
            onDrag?(startY - screenY(event))
        }
        override func mouseUp(with event: NSEvent) {
            guard startY != nil else { return }
            startY = nil
            onEnd?()
        }
    }
}

/// New Worktree (name it), Remove Worktree (confirm), and what git said if either failed.
private struct WorktreeAlerts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var parent: ChatSession?
    @Binding var name: String
    @Binding var removing: ChatSession?
    @Binding var error: String?

    func body(content: Content) -> some View {
        content
            .alert("New Worktree", isPresented: Binding(get: { parent != nil }, set: { if !$0 { parent = nil } })) {
                TextField("Branch name", text: $name)
                Button("Create") {
                    guard let project = parent else { return }
                    let branch = name
                    Task { do { try await model.newWorktree(of: project, name: branch) } catch { self.error = error.localizedDescription } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A separate copy of \(parent?.projectName ?? "the project") on its own branch, next to it, with its own chat. Work there won't touch main until you merge it.")
            }
            .alert("Remove Worktree?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) {
                    guard let chat = removing else { return }
                    Task { do { try await model.removeWorktree(chat) } catch { self.error = error.localizedDescription } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the worktree folder and archives its chat. The branch \u{201C}\(removing?.record.worktreeBranch ?? "")\u{201D} stays, so committed work isn't lost. Git won't remove it if it has uncommitted changes.")
            }
            .alert("Worktree", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }
}
