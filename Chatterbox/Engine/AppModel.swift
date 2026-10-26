import AppKit
import Foundation
import Observation

/// Owns the list of conversations and saves each one as JSON in Application Support.
@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [ChatSession] = []
    /// Startup progress remains visible until the first complete list is available.
    private(set) var sessionLoadStatus: String?
    private var loadedSessionList = false
    /// Groups of chats sharing a folder (see Studios.swift).
    var studios: [Studio] = []
    /// The Studio whose instructions are open for editing.
    var editingStudioInstructions: UUID?
    var selectedID: UUID? {
        didSet {
            if selectedID != nil { selectionClearedByArchive = false }
            showingHome = false
            showingAutomations = false
            showingCommandCenter = false
            if let session = sessions.first(where: { $0.id == selectedID }) {
                // Each view keeps the session it was last in (see showView).
                rememberSession(session)
                // A chat whose Studio is gone is listed under Chats (see sidebarChats).
                studioSidebarID = session.record.studioID.flatMap { id in activeStudios.contains { $0.id == id } ? id : nil }
                showingChatsSidebar = studioSidebarID == nil && Self.view(of: session) != .projects
                if studioSidebarID != nil { AppPreferences.defaults.set(false, forKey: "sidebarStudiosCollapsed") }
            }
            if RuntimeClient.usesDaemon, selectedID != oldValue, let oldValue { releaseUnseenTranscript(oldValue) }
            guard selectedID != oldValue, let session = sessions.first(where: { $0.id == selectedID }) else { return }
            Diagnostics.note("Opened \u{201C}\(session.title)\u{201D} (\(session.items.count) rows\(session.isRunning ? ", working" : ""))")
            if RuntimeClient.usesDaemon {
                if !restoringNavigation { AppPreferences.defaults.set(session.id.uuidString, forKey: "macLastOpenSession") }
                if RuntimeClient.shared.connected { refreshSession(session.id, immediately: true) }
            }
        }
    }
    /// List refreshes must not reopen a chat after the user archived the selected one.
    @ObservationIgnored private var selectionClearedByArchive = false
    /// The main views, each returning to where it was left.
    enum MainView: String { case projects, studios, chats }

    /// The view a session belongs to: its Studio's, its project's (worktrees and Sidechats
    /// too), or Chats.
    static func view(of session: ChatSession) -> MainView {
        if session.record.studioID != nil { return .studios }
        if session.record.projectFolder != nil || session.record.worktreeOf != nil || session.record.sidechatProjectFolder != nil { return .projects }
        return .chats
    }

    /// Each view's last session (or "overview" for the Studios page), by view.
    @ObservationIgnored private var lastInView: [String: String] = AppPreferences.defaults.dictionary(forKey: "lastSessionInView") as? [String: String] ?? [:]

    private func rememberSession(_ session: ChatSession) {
        guard !session.isDot else { return }
        lastInView[Self.view(of: session).rawValue] = session.id.uuidString
        AppPreferences.defaults.set(lastInView, forKey: "lastSessionInView")
    }

    /// The Studios overview page, rather than a Studio session, was the last place in Studios.
    func rememberStudiosOverview() {
        lastInView[MainView.studios.rawValue] = "overview"
        AppPreferences.defaults.set(lastInView, forKey: "lastSessionInView")
    }

    /// Section buttons always open the session columns, including when a remembered
    /// session was archived or moved. They never leave another section's chat selected.
    func showView(_ view: MainView) {
        showingSettings = false; showingCommandCenter = false; showingAutomations = false
        let candidates = activeSessions.filter { session in
            !session.isDot && Self.view(of: session) == view &&
            (view != .studios || activeStudios.contains(where: { $0.id == session.record.studioID }))
        }
        let last = lastInView[view.rawValue].flatMap(UUID.init(uuidString:))
            .flatMap { id in candidates.first { $0.id == id } }
        let recent = candidates.sorted { $0.lastActivity > $1.lastActivity }
        let destination = last ?? recent.first(where: { Attention.shared.needsAttention($0) }) ?? recent.first
        emptySidebarView = view
        selectedID = destination?.id
        showingHome = false
        studioSidebarID = view == .studios ? destination?.record.studioID : nil
        showingChatsSidebar = view == .chats
        sidebarRevealRequest += 1
    }

    var showingCloneFromGitHub = false
    var showingNewProject = false
    /// Projects and standalone chats have separate sidebar pages in the Mac UI.
    var showingChatsSidebar = false
    private var emptySidebarView: MainView = .projects
    var showingStudiosSidebar: Bool { studioSidebarID != nil || (selectedID == nil && emptySidebarView == .studios) }
    var studioSidebarID: UUID?
    var sidebarStudio: Studio? { studio(studioSidebarID) }
    /// Settings, shown in the main window in place of the chat.
    var showingHome = false { didSet { if showingHome { showingCommandCenter = false; showingAutomations = false } } }
    var showingCommandCenter = false { didSet { if showingCommandCenter { showingHome = false; showingSettings = false; showingAutomations = false } } }
    var showingAutomations = false { didSet { if showingAutomations { showingHome = false; showingCommandCenter = false; showingSettings = false } } }
    /// Feedback (toolbar): the window's screenshot being annotated, then what goes into the
    /// Chatterbox session's message box.
    var feedbackShot: Attachment?
    var composerInsertion: ComposerInsertion?
    var showingSettings = false { didSet { if showingSettings { showingHome = false; showingCommandCenter = false; showingAutomations = false } } }
    /// The independent, always-on-top Golem mini window (⌘J).
    var showingDot = false {
        didSet {
            guard showingDot != oldValue else { return }
            #if GOLEM_APP
            AppPreferences.defaults.set(showingDot, forKey: GolemMiniWindow.visibleKey)
            if showingDot {
                mainChatWindow?.orderOut(nil)
                if dotMiniWindow == nil { dotMiniWindow = GolemMiniWindow(model: self) }
                dotMiniWindow?.show()
            } else {
                dotMiniWindow?.hide()
            }
            #else
            if showingDot {GolemIntegration.shared.open();showingDot=false}
            #endif
        }
    }
    #if GOLEM_APP
    @ObservationIgnored private(set) var dotMiniWindow: GolemMiniWindow?
    #endif
    @ObservationIgnored weak var mainChatWindow: NSWindow?
    @ObservationIgnored var revealMainChatWindow: (() -> Void)?
    /// Sidebar toolbar/keyboard requests, consumed by the single column container.
    var sidebarToggleRequest = 0
    /// Section navigation reveals the sidebar in narrow windows, without toggling it shut.
    var sidebarRevealRequest = 0
    /// Dot's memory, open for editing.
    var editingDotMemory = false
    /// The Add Pin sheet, when open.
    var pinSheet: PinSheetRequest?
    /// Websites open inside Chatterbox, each in its own project's (or Studio's, or chat's)
    /// place: switching to another project shows its page, or its chat, instead.
    var webPages: [String: WebPage] = [:]

    /// Whose page the open chat shows: its project or Studio, or else the chat itself.
    private var pageKey: String? {
        guard let session = selected else { return nil }
        return pinPlace(for: session)?.key ?? "chat:" + session.id.uuidString
    }

    /// The page open for the selected chat's project, if any.
    var webPage: WebPage? {
        get { pageKey.flatMap { webPages[$0] } }
        set { if let key = pageKey { webPages[key] = newValue } }
    }

    /// Shows a page in place of the chat; another page replaces the one that's open.
    func openPage(_ url: URL) {
        webPage = WebPage(url: url)
    }

    var activeSessions: [ChatSession] { sessions.filter { $0.record.archivedAt == nil } }

    /// Threads pinned to the top of the sidebar, in pin order; kept in this Mac's preferences.
    var pinnedThreadIDs: [UUID] = (AppPreferences.defaults.stringArray(forKey: "macPinnedThreads") ?? []).compactMap(UUID.init) {
        didSet { AppPreferences.defaults.set(pinnedThreadIDs.map(\.uuidString), forKey: "macPinnedThreads") }
    }
    /// The pinned threads still open (archived ones drop out until they're unarchived).
    var pinnedThreads: [ChatSession] {
        pinnedThreadIDs.compactMap { id in activeSessions.first { $0.id == id } }
    }
    func isPinnedThread(_ session: ChatSession) -> Bool { pinnedThreadIDs.contains(session.id) }
    /// Top-level threads only: a worktree or Sidechat stays under its parent.
    func canPinThread(_ session: ChatSession) -> Bool {
        session.record.worktreeOf == nil && session.record.sidechatOf == nil && !session.isDot
    }
    /// The pins the service has (the phone may have changed them while the app was closed).
    func reloadPinnedThreads() {
        let saved = (AppPreferences.defaults.stringArray(forKey: "macPinnedThreads") ?? []).compactMap(UUID.init)
        if saved != pinnedThreadIDs { pinnedThreadIDs = saved }
    }

    /// Pin or unpin from the phone (CompanionServer), where the app runs it itself.
    func setPinned(_ session: ChatSession, _ pinned: Bool) {
        if pinned != isPinnedThread(session) { togglePinnedThread(session) }
    }

    func togglePinnedThread(_ session: ChatSession) {
        if isPinnedThread(session) { pinnedThreadIDs.removeAll { $0 == session.id } }
        else if canPinThread(session) { pinnedThreadIDs.append(session.id) }
    }

    /// Projects (by recent activity, staleness, or name), then each open Studio's chats, then other chats by most recent: the
    /// sidebar's order, which Next and Previous Chat follow.
    var sidebarProjects: [ChatSession] {
        let projects = activeSessions.filter { $0.record.projectFolder != nil && $0.record.worktreeOf == nil && !$0.isDot }
        return ordered(projects, by: ProjectSort.current, name: \.projectName)
    }
    /// Threads in a sort's order; ties go by name.
    private func ordered(_ threads: [ChatSession], by sort: ProjectSort, name: @escaping (ChatSession) -> String) -> [ChatSession] {
        let byName: (ChatSession, ChatSession) -> Bool = { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        switch sort {
        case .name: return threads.sorted(by: byName)
        case .recent: return threads.sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : byName($0, $1) }
        case .stalest: return threads.sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity < $1.lastActivity : byName($0, $1) }
        case .active: return mostActive(threads)
        }
    }
    /// Projects by how busy they are, counting their worktrees' and Sidechats' turns.
    private func mostActive(_ projects: [ChatSession]) -> [ChatSession] {
        var ranks: [UUID: (day: Int, week: Int, perDay: Double)] = [:]
        for project in projects {
            var total: (day: Int, week: Int, perDay: Double) = (0, 0, 0)
            for chat in [project] + worktrees(of: project) + sidechats(of: project) {
                let rank = chat.activityRank
                total.day += rank.day; total.week += rank.week; total.perDay += rank.perDay
            }
            ranks[project.id] = total
        }
        return projects.sorted { a, b in
            let x = ranks[a.id] ?? (0, 0, 0), y = ranks[b.id] ?? (0, 0, 0)
            if x.day != y.day { return x.day > y.day }
            if x.week != y.week { return x.week > y.week }
            if x.perDay != y.perDay { return x.perDay > y.perDay }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Chats in neither a project nor a Studio. A chat whose Studio is gone shows here too.
    var sidebarChats: [ChatSession] {
        let studioIDs = Set(activeStudios.map(\.id))
        let chats = activeSessions.filter { session in
            session.record.projectFolder == nil && !session.isDot && !hasVisibleSidechatParent(session) && !(session.record.studioID.map(studioIDs.contains) ?? false)
        }
        return ordered(chats, by: ProjectSort.currentForChats, name: \.title)
    }
    /// A Studio's chats in the order its sessions list shows them.
    func sortedChats(in studio: Studio) -> [ChatSession] {
        ordered(chats(in: studio), by: ProjectSort.currentForStudios, name: \.title)
    }
    var sidebarOrder: [ChatSession] {
        var ordered: [ChatSession] = []
        // Pinned threads lead, as they do in the sidebar.
        let pinned = pinnedThreads
        for thread in pinned {
            ordered += [thread] + sidechats(of: thread)
            for worktree in worktrees(of: thread) { ordered += [worktree] + sidechats(of: worktree) }
        }
        for project in sidebarProjects where !pinned.contains(where: { $0 === project }) {
            ordered += [project] + sidechats(of: project)
            for worktree in worktrees(of: project) { ordered += [worktree] + sidechats(of: worktree) }
        }
        for studio in activeStudios where studio.collapsed != true {
            for chat in sortedChats(in: studio) where !pinned.contains(where: { $0 === chat }) { ordered += studioFamily(of: chat) }
        }
        for chat in sidebarChats where !pinned.contains(where: { $0 === chat }) { ordered += [chat] + sidechats(of: chat) }
        return ordered
    }

    func hasVisibleSidechatParent(_ chat: ChatSession) -> Bool {
        guard let parent = chat.record.sidechatOf else { return false }
        return activeSessions.contains { $0.id == parent && !$0.isDot }
    }

    func sidechats(of parent: ChatSession) -> [ChatSession] {
        activeSessions.filter { $0.record.sidechatOf == parent.id }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Sidechats and sidequests live inside the original parent's card. Once that parent
    /// is archived they get cards of their own again.
    func showsInsideParentCard(_ session: ChatSession) -> Bool {
        guard let parent = session.record.sidechatOf ?? session.record.sidequestOf else { return false }
        return activeSessions.contains { $0.id == parent }
    }

    /// Every child shown inside this card, including sidequests, in creation order.
    func childChats(of parent: ChatSession) -> [ChatSession] {
        activeSessions.filter { ($0.record.sidechatOf ?? $0.record.sidequestOf) == parent.id }
            .sorted { $0.record.createdAt < $1.record.createdAt }
    }

    /// The sidequests a chat started, oldest first.
    func sidequests(of parent: ChatSession) -> [ChatSession] {
        activeSessions.filter { $0.record.sidequestOf == parent.id }.sorted { $0.record.createdAt < $1.record.createdAt }
    }

    @discardableResult
    func newSidechat(of parent: ChatSession) -> ChatSession {
        // Always anchor at the original parent; don't make a recursive tree of
        // temporary chats or resume either of its provider sessions.
        let anchor = parent.record.sidechatOf.flatMap { id in sessions.first { $0.id == id } } ?? parent
        let number = sessions.filter { $0.record.sidechatOf == anchor.id }.count + 1
        let record = ChatSession.sidechatRecord(of: parent, anchor: anchor, number: number)
        let chat = insertSession(record)
        selectedID = chat.id
        return chat
    }

    /// Sends `task` from `parent` to the other agent as a sidequest. You stay in `parent`; the
    /// sidequest floats in its corner (SidequestWindows). Its answer
    /// comes back to `parent` by itself (see ChatSession+Sidequest).
    func newSidequest(of parent: ChatSession, task: String) {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        if RuntimeClient.usesDaemon {
            Task {
                do {
                    _ = try await RuntimeClient.shared.request("sidequest", body: ["chatID": .string(parent.id.uuidString), "task": .string(task)])
                } catch { Diagnostics.note("Sidequest didn't start: \(error.localizedDescription)") }
            }
            return
        }
        let anchor = parent.record.sidechatOf.flatMap { id in sessions.first { $0.id == id } } ?? parent
        let number = sessions.filter { $0.record.sidechatOf == anchor.id }.count + 1
        let quest = insertSession(ChatSession.sidequestRecord(of: parent, anchor: anchor, number: number,
                                                              backend: parent.record.backend == .claude ? .codex : .claude, task: task))
        quest.beginSidequest(from: parent)
    }

    /// "Do that on the PC" from the session menu: the service sends `files` to Shelby-PC and
    /// starts the errand there (see DaemonContext.newPCErrand). Needs the background service.
    func newPCErrand(of parent: ChatSession, task: String, files: [String], backend: Backend?) {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        guard RuntimeClient.usesDaemon else { parent.notice("Sending work to \(RemoteMachine.pc.name) needs Chatterbox's background service."); return }
        Task {
            var body: [String: JSON] = ["chatID": .string(parent.id.uuidString), "task": .string(task), "files": .array(files.map(JSON.string))]
            if let backend { body["agent"] = .string(backend.rawValue) }
            do { _ = try await RuntimeClient.shared.request("pcErrand", body: .object(body), timeout: .seconds(600)) }
            catch { parent.notice("Couldn't send it to \(RemoteMachine.pc.name): \(error.localizedDescription)") }
        }
    }

    /// Send Back: the sidequest's newest reply goes to the chat it came from.
    func returnSidequest(_ quest: ChatSession) {
        if RuntimeClient.usesDaemon {
            RuntimeClient.shared.command("returnSidequest", body: ["chatID": .string(quest.id.uuidString)])
        } else if let parent = quest.record.sidequestOf.flatMap({ id in sessions.first { $0.id == id } }) {
            quest.returnSidequest(to: parent)
        }
    }

    /// Every tag in use, for the Tags menu.
    var allTags: [String] {
        var seen: [String: String] = [:]
        for tag in sessions.flatMap(\.tags) where seen[tag.lowercased()] == nil { seen[tag.lowercased()] = tag }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Moves the selection up or down the sidebar, wrapping around.
    func selectAdjacentChat(_ offset: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let current = order.firstIndex { $0.id == selectedID } ?? 0
        selectedID = order[(current + offset + order.count) % order.count].id
    }
    var archivedSessions: [ChatSession] {
        sessions.filter { $0.record.archivedAt != nil }
            .sorted { ($0.record.archivedAt ?? .distantPast) > ($1.record.archivedAt ?? .distantPast) }
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var legacyOwnership: RuntimeOwnership?
    @ObservationIgnored private var projecting = false
    @ObservationIgnored private var refreshTasks: [UUID:Task<Void,Never>] = [:]
    @ObservationIgnored private var refreshAgain: Set<UUID> = []

    var selected: ChatSession? { sessions.first { $0.id == selectedID } }

    /// Chats with changes not yet written, saved together shortly after (see `scheduleSave`).
    @ObservationIgnored private var unsaved: Set<UUID> = []
    /// Each chat's latest message from you when it last moved to the top. A chat moves up
    /// when you send it something, not on every save, so two chats replying at once don't
    /// keep swapping places.
    @ObservationIgnored private var orderedAtMessage: [UUID: UUID] = [:]
    /// Change counters for the iPhone app, so it only fetches what changed.
    @ObservationIgnored private(set) var companionListRevision = 0
    @ObservationIgnored private var companionRevisions: [UUID: Int] = [:]

    func companionRevision(of id: UUID) -> Int { companionRevisions[id] ?? 0 }
    @ObservationIgnored private var saveSoonScheduled = false
    @ObservationIgnored private var saveLaterScheduled = false

    /// Settings > General: when off, quitting stops any reply still running.
    static let keepRepliesRunningKey = "keepRepliesRunning"
    static var keepRepliesRunning: Bool { AppPreferences.defaults.object(forKey: keepRepliesRunningKey) as? Bool ?? true }

    init() {
        // CHATTERBOX_DATA_DIR keeps tests away from the user's real chats.
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"], !dir.isEmpty {
            directory = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("Conversations", isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("Chatterbox/Conversations", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The UI can crash or hang even when the daemon owns its conversations.
        Diagnostics.shared.start()
        if RuntimeClient.usesDaemon {
            restoreNavigationCache()
            sessionLoadStatus = sessions.isEmpty ? "Connecting to background service…" : "Updating sessions…"
            RuntimeClient.shared.onEvent = { [weak self] event in self?.runtimeEvent(event) }
            #if GOLEM_APP
            RuntimeClient.shared.start(role:"golem-ui")
            #else
            RuntimeClient.shared.start()
            #endif
            NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.applicationWillTerminate()}}
            return
        }
        // Updated legacy fixtures must never write a store already owned by a daemon.
        do {
            guard !FileManager.default.fileExists(atPath:directory.deletingLastPathComponent().appendingPathComponent("runtime-owner.json").path) else{throw RuntimeFailure("This conversation store belongs to the background service")}
            legacyOwnership = try RuntimeOwnership(root: directory.deletingLastPathComponent())
        }
        catch { Diagnostics.note(error.localizedDescription);return }
        #if DEBUG
        // Tests: open a chat some seconds after launch, like clicking it ("8:<chat id>").
        if let spec = ProcessInfo.processInfo.environment["CHATTERBOX_TEST_OPEN_AFTER"], let colon = spec.firstIndex(of: ":"),
           let seconds = Double(spec[..<colon]), let id = UUID(uuidString: String(spec[spec.index(after: colon)...])) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.selectedID = id }
        }
        #endif
        loadStudios()
        // Studios made before design.md existed get one (never overwriting).
        for studio in studios where studio.archivedAt == nil { studio.ensureDesignFile() }
        defer {
            // The order chats load in stands until you next write to one.
            for session in sessions { orderedAtMessage[session.id] = session.items.last { $0.kind == .user }?.id }
        }
        PinStore.shared.showPage = { [weak self] url in self?.openPage(url) }
        CompanionServer.shared.model = self
        CompanionServer.shared.startAgentListener()
        // Dot needs to know at once whether its computer is up, so its next session has the
        // browser tools without anyone opening the Computer panel first.
        if CompanionServer.shared.isEnabled { CompanionServer.shared.start() }
        // Chats look their Studio up when they talk to their agent.
        ChatSession.studioLookup = { [weak self] id in self?.studio(id) }
        RuntimeHooks.note = { Diagnostics.note($0) }
        RuntimeHooks.clearSuggestions = { NextSteps.shared.clear($0) }
        RuntimeHooks.turnEnded = { session in
            #if GOLEM_APP
            if !session.isDot, DotActivity.shared.chatFinished(session, watching: Attention.shared.isWatching(session)) { session.skipFinishedAlert = true }
            if session.isDot { DotActivity.shared.dotTurnEnded(session) }
            #endif
            NextSteps.shared.turnEnded(session, commands: session.availableSlashCommands)
            if let parent = session.record.sidequestOf {
                DispatchQueue.main.async { [weak self] in session.sidequestTurnEnded(parent: self?.sessions.first { $0.id == parent }) }
            }
            if session.automaticTurn {
                session.automaticTurn = false
                #if GOLEM_APP
                if session.isDot, DotActivity.shared.finishedAutomaticTurn(session) { session.skipFinishedAlert = true }
                #endif
            }
        }
        #if GOLEM_APP
        RuntimeHooks.answered = { GolemJournal.shared.answered($1, suggested: $2, with: $3, in: $0) }
        RuntimeHooks.suggested = { GolemJournal.shared.suggested($1, in: $0) }
        GolemAvatar.shared.refreshIfStale()
        #endif
        load()
        KeepAwake.shared.apply()
        if dot?.record.claudeHost?.running != true, dot?.record.codexHost?.running != true {
            applyRequestedDotDefault()
        }
        if activeSessions.isEmpty { newChat() } else { selectedID = activeSessions.first?.id }
        Task { await resumeBackgroundReplies() }
        #if GOLEM_APP
        if AppPreferences.defaults.bool(forKey: GolemMiniWindow.visibleKey) {
            Task { @MainActor [weak self] in self?.showingDot = true }
        }
        #endif
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationWillTerminate() }
        }
    }

    /// Replies keep running in the background host after the app quits, unless turned off.
    private func applicationWillTerminate() {
        Diagnostics.shared.stop()
        if RuntimeClient.usesDaemon {
            if !Self.keepRepliesRunning {for session in sessions where !session.isDot && session.isRunning {session.interrupt()}}
            return
        }
        for session in sessions { session.killShellJobs() }
        saveUnsaved()
        guard !Self.keepRepliesRunning else { return }
        for session in sessions { session.claudeProcess?.terminate() }
        for codex in CodexAppServer.all { codex.terminate() }
    }

    /// A new session waiting for its name (ContentView asks): in a Studio or on its own.
    struct NewSessionRequest: Identifiable {
        let id = UUID()
        var studio: UUID?
        var backend: Backend?
    }
    var namingNewSession: NewSessionRequest?

    /// What New Chat and the + buttons do: ask for a name first (it can be left empty).
    func askNewChat(in studio: Studio? = nil, backend: Backend? = nil) {
        namingNewSession = NewSessionRequest(studio: studio?.id, backend: backend)
    }

    /// Starts the session asked for, named if a name was given.
    @discardableResult func startNewSession(_ request: NewSessionRequest, name: String) -> ChatSession {
        let session = request.studio.flatMap(studio).map { newChat(in: $0, backend: request.backend) } ?? newChat(backend: request.backend)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { session.setTitle(trimmed) }
        return session
    }

    /// A new session starts on the model and effort `kind` last used (see ModelSelection).
    @discardableResult
    func newChat(backend: Backend? = nil, kind: SessionKind = .chats) -> ChatSession {
        let session = makeNewChat(backend: backend)
        ModelSelection.startLikeLast(session, kind: kind, requested: backend)
        return session
    }

    private func makeNewChat(backend: Backend?) -> ChatSession {
        let defaults = AppPreferences.defaults
        let backend = backend ?? Backend(rawValue: defaults.string(forKey: "defaultBackend") ?? "") ?? .claude
        if let empty = sessions.first(where: { !$0.hasMessages && !$0.isRunning && $0.record.projectFolder == nil && $0.record.studioID == nil && $0.record.archivedAt == nil && !$0.isDot && !carriesUserIntent($0.record) }) {
            empty.setBackend(backend)
            selectedID = empty.id
            return empty
        }
        var record = ConversationRecord(
            model: defaults.string(forKey: "defaultModel") ?? "default",
            effort: defaults.string(forKey: "defaultEffort") ?? "",
            personality: Personality(rawValue: defaults.string(forKey: "defaultPersonality") ?? "") ?? .friendly
        )
        record.claudeMode = PermissionModes.defaultClaude
        if backend == .codex {
            record.codex = CodexSettings(
                folder: defaults.string(forKey: "codexFolder") ?? NSHomeDirectory(),
                canEdit: false,
                mode: PermissionModes.defaultCodex
            )
            record.codex?.model = defaults.string(forKey: "codexDefaultModel").flatMap { $0.isEmpty ? nil : $0 }
            record.codex?.effort = defaults.string(forKey: "codexDefaultEffort").flatMap { $0.isEmpty ? nil : $0 }
        }
        let session = makeSession(record)
        sessions.insert(session, at: 0)
        selectedID = session.id
        return session
    }

    /// Hides a chat from the main lists and stops its agent. Nothing is removed; a project
    /// chat keeps its folder, and opening that folder again brings the chat back.
    func archive(_ session: ChatSession) {
        let discardEmpty = !session.hasMessages && session.record.projectFolder == nil && session.record.sidechatOf == nil
        if selectedID == session.id {
            let home = showingHome, automations = showingAutomations, commandCenter = showingCommandCenter
            selectedID = nil
            selectionClearedByArchive = true
            showingHome = home; showingAutomations = automations; showingCommandCenter = commandCenter
        }
        if discardEmpty { return delete(session, selectingReplacement: false) }
        session.shutdown()
        session.setArchived(true)
    }

    func unarchive(_ session: ChatSession) {
        if let studio = studio(for: session), studio.archivedAt != nil { unarchiveStudio(studio.id) }
        session.setArchived(false)
        selectedID = session.id
    }

    func delete(_ session: ChatSession, selectingReplacement: Bool = true) {
        if RuntimeClient.usesDaemon {
            RuntimeClient.shared.command("delete",body:["chatID":.string(session.id.uuidString)])
            // Gone from the lists now, not after the service's next full chat list (seconds
            // when it's busy). If the delete fails, that list brings the chat back.
            sessions.removeAll { $0.id == session.id }
            if selectingReplacement, selectedID == session.id { selectedID = activeSessions.first?.id }
            return
        }
        session.shutdown()
        unsaved.remove(session.id)
        // A fork shares its original's attachment files; keep any another chat still shows.
        let inUse = Set(sessions.filter { $0.id != session.id }.flatMap(\.allAttachments).map(\.path))
        Attachments.remove(session.allAttachments.filter { !inUse.contains($0.path) })
        sessions.removeAll { $0.id == session.id }
        try? FileManager.default.removeItem(at: fileURL(session.id))
        if selectingReplacement, selectedID == session.id { selectedID = activeSessions.first?.id }
        if selectingReplacement, activeSessions.isEmpty { newChat() }
    }

    // MARK: - Projects

    static func normalize(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The chat bound to `folder`, if any. Each folder has at most one.
    func session(boundTo folder: String) -> ChatSession? {
        let target = Self.normalize(folder)
        return sessions.first { ($0.record.projectFolder ?? $0.record.convertedProjectFolder).map(Self.normalize) == target }
    }

    /// Binds `session` to `folder`, unless another chat already owns it; that chat is returned instead.
    @discardableResult
    func bind(_ session: ChatSession, to folder: String) -> ChatSession? {
        if let owner = self.session(boundTo: folder), owner.id != session.id { return owner }
        session.bindProject(Self.normalize(folder))
        return nil
    }

    // MARK: - Worktrees

    /// A project's worktree chats, newest first.
    func worktrees(of project: ChatSession) -> [ChatSession] {
        guard let folder = (project.record.projectFolder ?? project.record.convertedProjectFolder).map(Self.normalize) else { return [] }
        return activeSessions.filter { $0.record.worktreeOf.map(Self.normalize) == folder && $0.record.studioID == project.record.studioID }
            .sorted { $0.record.createdAt > $1.record.createdAt }
    }

    struct WorktreeError: LocalizedError {
        var message: String
        var errorDescription: String? { message }

        /// Git's reason, not its progress chatter ("Preparing worktree…").
        static func git(_ output: Git.Output) -> WorktreeError {
            let text = output.err.isEmpty ? output.out : output.err
            let reasons = text.split(separator: "\n").filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
            let message = reasons.isEmpty ? text : reasons.joined(separator: "\n")
            return WorktreeError(message: message.replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: ""))
        }
    }

    /// Makes a git worktree of `project` on a new branch, beside the repo
    /// (Chatterbox → Chatterbox-<branch>), and a chat that works in it, with the same agent.
    @discardableResult
    func newWorktree(of project: ChatSession, name: String) async throws -> ChatSession {
        guard let main = project.record.projectFolder else { throw WorktreeError(message: "That session isn't a project.") }
        let branch = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9._/-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        guard !branch.isEmpty else { throw WorktreeError(message: "Give the worktree a name, like \u{201C}new-sidebar\u{201D}.") }
        let root = await Git.git(["rev-parse", "--show-toplevel"], in: main)
        guard root.status == 0, !root.out.isEmpty else { throw WorktreeError(message: "\(project.projectName) isn't a git repository.") }
        let repo = URL(fileURLWithPath: root.out)
        let base = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-" + branch.replacingOccurrences(of: "/", with: "-"))
        var path = base.path
        var n = 2
        while FileManager.default.fileExists(atPath: path) { path = base.path + "-\(n)"; n += 1 }
        // A new branch from where main is now; an existing branch is checked out as it is.
        let exists = await Git.git(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: main).status == 0
        let add = await Git.git(["worktree", "add", path] + (exists ? [branch] : ["-b", branch]), in: main)
        guard add.status == 0 else { throw WorktreeError.git(add) }
        let chat = newChat(backend: project.record.backend)
        chat.bindProject(Self.normalize(path))
        chat.record.worktreeOf = Self.normalize(main)
        chat.record.worktreeBranch = branch
        chat.setProjectNickname(branch)
        chat.setTitle(branch)
        selectedID = chat.id
        return chat
    }

    /// Removes the worktree folder (git refuses if it has uncommitted changes) and archives
    /// its chat. The branch is kept, so nothing committed is lost.
    func removeWorktree(_ chat: ChatSession) async throws {
        guard let path = chat.record.projectFolder, let main = chat.record.worktreeOf else { return }
        if FileManager.default.fileExists(atPath: path) {
            let remove = await Git.git(["worktree", "remove", path], in: main)
            guard remove.status == 0 else {
                throw WorktreeError(message: WorktreeError.git(remove).message
                                    + "\n\nCommit or discard its changes first, then try again.")
            }
        }
        if selectedID == chat.id, let project = session(boundTo: main) { selectedID = project.id }
        archive(chat)
    }

    /// Opens the folder's chat, creating one if the folder doesn't have one yet.
    func openProject(_ folder: String, backend: Backend? = nil) {
        if let existing = session(boundTo: folder) {
            if existing.record.archivedAt != nil { existing.setArchived(false) }
            selectedID = existing.id
            return
        }
        let session = newChat(backend: backend, kind: .projects)
        session.bindProject(Self.normalize(folder))
    }

    /// The chat whose project folder is a clone of `repo` ("owner/name").
    func session(forRepo repo: String) -> ChatSession? {
        sessions.first { $0.record.githubRepo?.lowercased() == repo.lowercased() }
    }

    /// Reads each project's git remote at launch, so repos show without opening every chat.
    func refreshProjectRepos() async {
        for session in sessions {
            guard let folder = session.record.projectFolder else { continue }
            await GitStatusStore.shared.refresh(folder)
            session.updateGitHubRepo(from: GitStatusStore.shared.status(for: folder))
        }
    }

    /// The folder the selected chat works in: its project, or else the working folder.
    var selectedFolder: String? {
        guard let session = selected else { return nil }
        return session.record.boundFolder ?? session.record.codex?.folder
            ?? AppPreferences.defaults.string(forKey: "codexFolder") ?? NSHomeDirectory()
    }

    /// Opens a Terminal window in the selected chat's folder.
    func openTerminal() {
        guard let folder = selectedFolder else { return }
        openTerminal(at: folder)
    }

    /// Where New Project puts folders: the last place used, or wherever most projects are.
    var newProjectLocation: String {
        if let saved = AppPreferences.defaults.string(forKey: "newProjectLocation"), FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        let parents = sessions.compactMap(\.record.projectFolder).map { ($0 as NSString).deletingLastPathComponent }
        let counts = Dictionary(parents.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? NSHomeDirectory()
    }

    /// A folder name from a project name; slashes and colons can't be in one.
    static func folderName(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Makes a new project folder (and a git repository in it, if asked) and opens its chat.
    func createProject(named name: String, in parent: String, gitInit: Bool) async throws {
        let folder = (parent as NSString).appendingPathComponent(Self.folderName(for: name))
        guard !FileManager.default.fileExists(atPath: folder) else {
            throw ClaudeCodeError(message: "\((folder as NSString).abbreviatingWithTildeInPath) already exists.")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if gitInit {
            let result = await Git.run("/usr/bin/git", ["init", "--quiet"], in: folder)
            if result.status != 0 { NSLog("Chatterbox: git init failed in \(folder): \(result.err)") }
        }
        AppPreferences.defaults.set(parent, forKey: "newProjectLocation")
        openProject(folder)
    }

    func chooseAndOpenProject() {
        if let folder = FolderPicker.choose(startingAt: nil, message: "Choose a project folder. Its session opens, or a new one starts.") {
            openProject(folder)
        }
    }

    // MARK: - Persistence

    /// Adds a chat made from a finished record (a fork) and saves it.
    func insertSession(_ record: ConversationRecord) -> ChatSession {
        let session = makeSession(record)
        sessions.insert(session, at: 0)
        scheduleSave(session, soon: true)
        return session
    }

    private func makeSession(_ record: ConversationRecord) -> ChatSession {
        let session = ChatSession(record: record)
        if RuntimeClient.usesDaemon {
            bindProjection(session)
            if !projecting { RuntimeClient.shared.command("create",body:["record":(try? .value(record)) ?? .null]) }
            return session
        }
        session.onChange = { [weak self] session in
            self?.scheduleSave(session, soon: true)
            if session.isDot, !session.isRunning, AppPreferences.defaults.bool(forKey: "dotApplyDefault") {
                DispatchQueue.main.async { [weak self] in self?.applyRequestedDotDefault() }
            }
        }
        session.onStreamed = { [weak self] session in self?.scheduleSave(session, soon: false) }
        return session
    }

    /// Saves are batched and always run between two agent output lines, so each saved record
    /// matches how far its agent's output was read. Changes save on the next turn of the run
    /// loop; streamed text at most once a second.
    private func scheduleSave(_ session: ChatSession, soon: Bool) {
        if RuntimeClient.usesDaemon {return}
        companionListRevision += 1
        companionRevisions[session.id, default: 0] += 1
        unsaved.insert(session.id)
        if soon {
            guard !saveSoonScheduled else { return }
            saveSoonScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.saveSoonScheduled = false
                self?.saveUnsaved()
            }
        } else {
            guard !saveLaterScheduled else { return }
            saveLaterScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.saveLaterScheduled = false
                self?.saveUnsaved()
            }
        }
    }

    private func saveUnsaved() {
        guard !unsaved.isEmpty else { return }
        let ids = unsaved
        unsaved = []
        for session in sessions where ids.contains(session.id) { save(session) }
        // After the chats, so each chat's saved state is at least as far along as this.
        for codex in CodexAppServer.all where codex.isRunning { codex.saveResumeState() }
    }

    /// Reattaches chats to replies that kept running (or finished) while the app was closed.
    /// Runs once at launch; without a host running there's nothing to find.
    private func resumeBackgroundReplies() async {
        let linked = sessions.filter(\.awaitingHostResume)
        let processes = (try? await HostClient.shared.list()) ?? []
        for session in linked {
            session.resumeFromHost(processes)
            scheduleSave(session, soon: true)
        }
        for codex in CodexAppServer.all { codex.resume(processes) }
        applyRequestedDotDefault()
        // Logs of ended processes no chat points at anymore. Running ones are left alone: the
        // host lets an agent go once it's idle with no app attached.
        var known = Set(sessions.compactMap { $0.claudeProcess?.hostID })
        for codex in CodexAppServer.all { if let id = codex.hostID { known.insert(id) } }
        for process in processes where !process.running && !known.contains(process.id) {
            HostClient.shared.forget(id: process.id)
        }
    }

    private var studiosFile: URL { directory.deletingLastPathComponent().appendingPathComponent("Studios.json") }

    func saveStudios() {
        if RuntimeClient.usesDaemon {RuntimeClient.shared.command("studios",body:["studios":(try? .value(studios)) ?? []]);return}
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(studios).write(to: studiosFile, options: .atomic)
        } catch {
            NSLog("Chatterbox: failed to save Studios: \(error)")
        }
    }

    private func loadStudios() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        studios = (try? Data(contentsOf: studiosFile)).flatMap { try? decoder.decode([Studio].self, from: $0) } ?? []
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Whether an empty chat holds something the user chose, so it's kept across a relaunch:
    /// a project or Studio, a name, tags, an archive, or an agent, model, effort or mode that
    /// differs from what a new chat starts with. An untouched "New chat" isn't kept.
    private func carriesUserIntent(_ record: ConversationRecord) -> Bool {
        if record.projectFolder != nil || record.studioID != nil || record.worktreeOf != nil || record.sidechatOf != nil || record.archivedAt != nil { return true }
        if record.title != "New chat" || !(record.tags ?? []).isEmpty { return true }
        let defaults = AppPreferences.defaults
        let backend = Backend(rawValue: defaults.string(forKey: "defaultBackend") ?? "") ?? .claude
        if record.backend != backend { return true }
        if record.model != (defaults.string(forKey: "defaultModel") ?? "default") { return true }
        if record.effort != (defaults.string(forKey: "defaultEffort") ?? "") { return true }
        if record.personality != (Personality(rawValue: defaults.string(forKey: "defaultPersonality") ?? "") ?? .friendly) { return true }
        if record.claudeModeID != PermissionModes.defaultClaude || record.claudeFastMode == true { return true }
        if record.remoteControl != nil || record.currentIssue != nil { return true }
        if let codex = record.codex {
            let model = defaults.string(forKey: "codexDefaultModel").flatMap { $0.isEmpty ? nil : $0 }
            let effort = defaults.string(forKey: "codexDefaultEffort").flatMap { $0.isEmpty ? nil : $0 }
            if codex.modeID != PermissionModes.defaultCodex || codex.model != model || codex.effort != effort
                || codex.fastMode == true || codex.route != nil { return true }
        }
        return false
    }

    private func save(_ session: ChatSession) {
        Attention.shared.update(session, model: self)
        guard !session.items.isEmpty || session.isDot || carriesUserIntent(session.record) else { return }
        session.prepareForSave()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(session.record).write(to: fileURL(session.id), options: .atomic)
        } catch {
            NSLog("Chatterbox: failed to save conversation: \(error)")
        }
        // Saved, so the host may trim that much of a long log.
        if let link = session.record.claudeHost, HostClient.shared.isConnected {
            HostClient.shared.ack(id: link.processID, offset: link.offset)
        }
        // The chat you last wrote to goes to the top.
        let lastMessage = session.items.last { $0.kind == .user }?.id
        if let lastMessage, orderedAtMessage[session.id] != lastMessage {
            orderedAtMessage[session.id] = lastMessage
            if let index = sessions.firstIndex(where: { $0.id == session.id }), index != 0, !sessions[0].items.isEmpty {
                sessions.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
            }
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ConversationRecord.self, from: Data(contentsOf: $0)) }
            .map { record in
                var record = record
                for index in record.items.indices { record.items[index].queued = nil }
                _ = record.adoptAsSidequestIfAutomationRun()
                return record
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                let session = makeSession(record)
                // A chat whose agent may still be running in the background host keeps its
                // pending requests and running rows until `resumeBackgroundReplies` checks.
                // Otherwise requests from a previous run can't be answered anymore.
                if session.hasHostLinks { session.awaitingHostResume = true } else { session.settleInterruptedWork() }
                return session
            }
    }
    private func bindProjection(_ session: ChatSession) {
        let chatID=session.id
        session.remoteCommand = { [weak session] operation, payload in
            var body=payload.object ?? [:];body["chatID"] = .string(chatID.uuidString)
            guard operation=="setDraft" else { RuntimeClient.shared.command(operation,body:.object(body)); return }
            // A draft counts as saved only once the service confirms this exact text.
            let text=payload["text"]?.string
            Task {
                do {
                    _ = try await RuntimeClient.shared.request(operation,body:.object(body))
                    if let session, session.draft==text { session.draftUnsynced=false }
                } catch {
                    NSLog("Chatterbox: draft not saved yet; will resend: \(error.localizedDescription)")
                }
            }
        }
        session.onChange = { [weak self] changed in
            guard self?.projecting == false else{return}
            var metadata=changed.record;metadata.items=[]
            RuntimeClient.shared.command("metadata",body:["record":(try? .value(metadata)) ?? .null])
        }
    }
    @ObservationIgnored private var projectionRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var navigationStates: [UUID: RuntimeChatState] = [:]
    @ObservationIgnored private var restoringNavigation = false
    @ObservationIgnored private var transcriptReaders: [UUID: Int] = [:]
    @ObservationIgnored private var historyTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var navigationSave: Task<Void, Never>?

    private var navigationFile: URL {
        #if GOLEM_APP
        directory.deletingLastPathComponent().appendingPathComponent("golem-navigation.json")
        #else
        directory.deletingLastPathComponent().appendingPathComponent("mac-navigation.json")
        #endif
    }
    private struct NavigationCache: Codable { var schema = 1; var states: [RuntimeChatState]; var studios: [Studio] }

    private func restoreNavigationCache() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: navigationFile),
              let cache = try? decoder.decode(NavigationCache.self, from: data), cache.schema == 1 else { return }
        restoringNavigation = true
        studios = cache.studios
        for state in cache.states where state.summaryOnly == true { applyProjection(state, updateAttention: false) }
        // Cached revisions belong to the last connection, not the new service handshake.
        projectionRevisions.removeAll()
        restoreSelectedSession()
        restoringNavigation = false
    }

    private func saveNavigationSoon() {
        guard RuntimeClient.shared.supportsNavigationSummaries, navigationSave == nil else { return }
        navigationSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.navigationSave = nil
            let cache = NavigationCache(states: self.sessions.compactMap { self.navigationStates[$0.id] }, studios: self.studios)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(cache) else { return }
            let file = self.navigationFile
            _ = await Task.detached(priority: .utility) {
                do {
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } catch { NSLog("Chatterbox: navigation cache: \(error.localizedDescription)") }
            }.value
        }
    }

    private func restoreSelectedSession() {
        guard !selectionClearedByArchive else { return }
        guard selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) else { return }
        let saved = AppPreferences.defaults.string(forKey: "macLastOpenSession").flatMap(UUID.init(uuidString:))
        let session = saved.flatMap { id in sessions.first { $0.id == id && $0.record.archivedAt == nil } }
            ?? activeSessions.first { !$0.isDot }
        let home = showingHome; selectedID = session?.id; showingHome = home
    }

    private func wantsTranscript(_ id: UUID) -> Bool { selectedID == id || (transcriptReaders[id] ?? 0) > 0 }

    /// Standalone windows and tiles retain their own transcripts, as well as the selected chat.
    func retainTranscript(_ session: ChatSession) {
        guard RuntimeClient.usesDaemon else { return }
        transcriptReaders[session.id, default: 0] += 1
        if RuntimeClient.shared.connected, !session.transcriptLoaded { refreshSession(session.id, immediately: true) }
    }
    func releaseTranscript(_ id: UUID) {
        guard RuntimeClient.usesDaemon else { return }
        let count = (transcriptReaders[id] ?? 0) - 1
        transcriptReaders[id] = count > 0 ? count : nil
        releaseUnseenTranscript(id)
    }
    private func releaseUnseenTranscript(_ id: UUID) {
        guard RuntimeClient.shared.supportsNavigationSummaries, !wantsTranscript(id),
              let session = sessions.first(where: { $0.id == id }), session.sentEchoes.isEmpty,
              navigationStates[id] != nil else { return }
        session.record = session.record.navigationMetadata()
        session.transcriptLoaded = false; session.transcriptStart = 0
        session.transcriptLoading = false; session.transcriptProblem = nil
        // Drafts typed on this Mac stay in the session until confirmed; they are never cached.
    }

    func loadTranscript(_ session: ChatSession) { refreshSession(session.id, immediately: true) }

    /// Opening All Images or Files explicitly asks for this session's complete library.
    func prepareLibraryTranscript(_ session: ChatSession) async {
        guard RuntimeClient.usesDaemon else { return }
        if !session.transcriptLoaded {
            do {
                let state = try await RuntimeClient.shared.request("get", body: ["chatID": .string(session.id.uuidString), "limit": 40]).decode(RuntimeChatState.self)
                applyProjection(state)
            } catch { session.transcriptProblem = error.localizedDescription; return }
        }
        if session.hasEarlierTranscript {
            loadEarlierTranscript(session, complete: true)
            await historyTasks[session.id]?.value
        }
    }

    /// Earlier pages use stable message ids, even when the selected chat is streaming.
    /// Find and Library request all pages explicitly, without a single oversized wire reply.
    func loadEarlierTranscript(_ session: ChatSession, complete: Bool = false) {
        guard RuntimeClient.usesDaemon, historyTasks[session.id] == nil,
              session.hasEarlierTranscript, session.items.first != nil else { return }
        let id = session.id
        session.transcriptLoading = true; session.transcriptProblem = nil
        historyTasks[id] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { historyTasks[id] = nil; session.transcriptLoading = false }
            do {
                repeat {
                    guard let first = session.items.first?.id, wantsTranscript(id) else { return }
                    let body: JSON = ["chatID": .string(id.uuidString), "before": .string(first.uuidString), "limit": .number(complete ? 200 : 40)]
                    let state = try await RuntimeClient.shared.request("get", body: body, timeout: .seconds(60)).decode(RuntimeChatState.self)
                    guard wantsTranscript(id), session.items.first?.id == first else { return }
                    let existing = Set(session.items.map(\.id))
                    let earlier = state.record.items.filter { !existing.contains($0.id) }
                    guard !earlier.isEmpty || state.historyStart == 0 else { throw RuntimeFailure("Earlier history did not advance; try again.") }
                    session.record.items.insert(contentsOf: earlier, at: 0)
                    session.transcriptStart = state.historyStart ?? 0
                } while complete && session.hasEarlierTranscript && !Task.isCancelled
                session.historyPage += 1
            } catch { session.transcriptProblem = error.localizedDescription }
        }
    }

    private func applyProjection(_ state: RuntimeChatState, updateAttention: Bool = true) {
        #if !GOLEM_APP
        guard state.record.isDot != true else { return }
        #endif
        let id = state.record.id
        if let revision = projectionRevisions[id], state.revision < revision { return }
        if state.summaryOnly == true, projectionRevisions[id] == state.revision,
           sessions.contains(where: { $0.id == id }) {
            releaseUnseenTranscript(id)
            return
        }
        projectionRevisions[id] = state.revision
        if let summary = state.summary {
            navigationStates[id] = RuntimeChatState(record: state.record.navigationMetadata(), running: state.running,
                revision: state.revision, totalCount: state.totalCount, pendingItems: state.pendingItems,
                summary: summary, summaryOnly: true)
        }
        projecting = true; defer { projecting = false }
        let session: ChatSession
        if let existing = sessions.first(where: { $0.id == id }) { session = existing }
        else {
            session = ChatSession(record: state.record.navigationMetadata())
            session.transcriptLoaded = false
            bindProjection(session); sessions.append(session)
        }
        session.applyingRemoteState = true
        var record = state.record
        if state.summaryOnly == true {
            if wantsTranscript(id) || !session.sentEchoes.isEmpty {
                record.items = session.items
                record.brief = session.record.brief
                record.parentContext = session.record.parentContext
            } else {
                record.items = []
                session.transcriptLoaded = false; session.transcriptStart = 0
            }
        } else if !RuntimeClient.shared.supportsNavigationSummaries || wantsTranscript(id) {
            if let first = record.items.first?.id, let index = session.items.firstIndex(where: { $0.id == first }) {
                record.items = Array(session.items.prefix(index)) + record.items
                session.transcriptStart = min(session.transcriptStart, state.historyStart ?? 0)
            } else { session.transcriptStart = state.historyStart ?? 0 }
            session.transcriptLoaded = true
        } else { record.items = []; session.transcriptLoaded = false }
        session.record = record; session.isRunning = state.running
        session.listSummary = state.summary
        session.projectedPendingItems = state.pendingItems
        session.transcriptTotalCount = state.totalCount
        // Summary replies have no message acknowledgements. Never match a local sent echo
        // against itself in the transcript preserved above.
        if state.summaryOnly != true { session.keepSentEchoes() }
        if let draft = state.draft, !session.draftUnsynced { session.draft = draft.text; session.draftAttachments = draft.attachments }
        session.applyingRemoteState = false
        if updateAttention { Attention.shared.update(session, model: self, updatesBadge: !restoringNavigation) }
        if !restoringNavigation { saveNavigationSoon() }
    }

    private func refreshSession(_ id: UUID, immediately: Bool = false) {
        guard RuntimeClient.usesDaemon, RuntimeClient.shared.connected else { return }
        guard refreshTasks[id] == nil else { refreshAgain.insert(id); return }
        refreshTasks[id] = Task { [weak self] in
            guard let self else { return }
            if !immediately { try? await Task.sleep(for: .milliseconds(100)) }
            repeat {
                refreshAgain.remove(id)
                let visible = wantsTranscript(id)
                let session = sessions.first { $0.id == id }
                if visible { session?.transcriptLoading = true; session?.transcriptProblem = nil }
                do {
                    var body: [String: JSON] = ["chatID": .string(id.uuidString)]
                    if RuntimeClient.shared.supportsNavigationSummaries { body["limit"] = 40 }
                    if RuntimeClient.shared.supportsNavigationSummaries && !visible { body["summaryOnly"] = true }
                    let state = try await RuntimeClient.shared.request("get", body: .object(body)).decode(RuntimeChatState.self)
                    applyProjection(state)
                } catch {
                    if visible { session?.transcriptProblem = error.localizedDescription }
                    Diagnostics.note(error.localizedDescription)
                }
                session?.transcriptLoading = false
            } while refreshAgain.contains(id) && RuntimeClient.shared.connected
            refreshTasks[id] = nil
        }
    }
    /// Reloads the chat list from the background service. One at a time: a request during a
    /// reload runs once after it. A failed reload retries (1, 2, 4 s, then every 10 s) while
    /// connected; it used to give up, leaving the sidebar empty until something else changed.
    @ObservationIgnored private var resyncing=false
    @ObservationIgnored private var resyncAgain=false
    private func requestResync() {
        guard !resyncing else { resyncAgain=true; return }
        resyncing=true
        Task {
            var attempt=0
            repeat {
                resyncAgain=false
                while !(await resyncOnce()) {
                    guard RuntimeClient.shared.connected else { break }
                    try? await Task.sleep(for:.seconds(attempt < 3 ? Double(1 << attempt) : 10))
                    attempt += 1
                }
            } while resyncAgain && RuntimeClient.shared.connected
            resyncing=false
        }
    }
    private func resyncOnce() async -> Bool {
        let started=Date()
        do {
            // Studio names and membership are small and needed when choosing the first chat.
            studios=try await RuntimeClient.shared.request("getStudios").decode([Studio].self)
            let summaries = RuntimeClient.shared.supportsNavigationSummaries
            if !loadedSessionList {
                sessionLoadStatus = "Loading working sessions…"
                if RuntimeClient.shared.supportsPriorityList {
                    let working = try await RuntimeClient.shared.request("list", body: ["workingOnly": true, "summaryOnly": .bool(summaries)], timeout: .seconds(60)).decode([RuntimeChatState].self)
                    for state in working { applyProjection(state) }
                    Diagnostics.note("Working sessions ready in \(String(format:"%.1f",Date().timeIntervalSince(started))) s (\(working.count) sessions)")
                }
                if let selectedID { refreshSession(selectedID, immediately: true) }
                sessionLoadStatus = "Loading session summaries…"
                await Task.yield()
            }
            let states = try await RuntimeClient.shared.request("list", body: ["summaryOnly": .bool(summaries)], timeout: .seconds(60)).decode([RuntimeChatState].self)
            let ids = Set(states.map { $0.record.id }); sessions.removeAll { !ids.contains($0.id) }
            navigationStates = navigationStates.filter { ids.contains($0.key) }
            projectionRevisions = projectionRevisions.filter { ids.contains($0.key) }
            restoringNavigation = true
            for state in states { applyProjection(state) }
            restoreSelectedSession()
            restoringNavigation = false
            Attention.shared.refreshBadge()
            if let selectedID, let selected, !selected.transcriptLoaded { refreshSession(selectedID, immediately: true) }
            loadedSessionList = true
            sessionLoadStatus = nil
            saveNavigationSoon()
            for session in sessions { session.resendDraftIfUnsynced() }
            await RuntimePreferenceProjection.shared.start()
            reloadPinnedThreads()
            PinStore.shared.applyRuntimePins(try await RuntimeClient.shared.request("getPins").decode([Pin].self))
            let elapsed=Date().timeIntervalSince(started)
            if elapsed > 2 { Diagnostics.note("Session list took \(String(format:"%.1f",elapsed)) s to load from the background service (\(states.count) sessions)") }
            return true
        } catch {
            if !loadedSessionList { sessionLoadStatus = "Loading sessions failed. Retrying…" }
            Diagnostics.note("Couldn't load the session list from the background service; retrying: \(error.localizedDescription)")
            return false
        }
    }
    private func runtimeEvent(_ event:RuntimeEvent) {
        #if GOLEM_APP
        if event.kind=="integration.changed" {
            Task {
                if let health=try? await RuntimeClient.shared.request("health"),health["integrationEnabled"]?.bool==false {
                    sessions.removeAll();showingDot=false
                } else {runtimeEvent(RuntimeEvent(sequence:event.sequence,revision:0,kind:"runtime.resync"))}
            }
            return
        }
        #endif
        #if !GOLEM_APP
        if event.kind=="pin.open",let raw=event.payload,let pin=try? raw.decode(Pin.self){PinStore.shared.open(pin);return}
        // Pinned or unpinned on the phone: the service sends the new list.
        if event.kind=="pins.changed",let ids=event.payload?.array {pinnedThreadIDs=ids.compactMap{$0.string.flatMap(UUID.init(uuidString:))};return}
        #endif
        if event.kind == "runtime.resync" { projectionRevisions.removeAll() }
        if event.kind=="runtime.resync" || event.kind=="runtime.configuration" || event.kind=="chat.created" || event.kind=="chat.deleted" {
            requestResync()
        } else if let id = event.chatID {
            refreshSession(id)
        }
    }

}

/// Text and attachments to add to a session's message box, for the open chat view to take in
/// (or the next one to open for that session).
struct ComposerInsertion: Equatable {
    var id = UUID()
    var session: UUID
    var text: String
    var attachments: [Attachment]
}

extension AppModel {
    /// The project session feedback goes to: Settings' choice, else the project in a folder
    /// named Chatterbox (one session per project, so it's that one).
    var feedbackProject: ChatSession? {
        let chosen = AppPreferences.defaults.string(forKey: "feedbackProjectFolder").map(RuntimePaths.normalize)
        let projects = sidebarProjects.filter { $0.record.projectFolder != nil && $0.record.worktreeOf == nil }
        if let chosen, let match = projects.first(where: { $0.record.projectFolder.map(RuntimePaths.normalize) == chosen }) { return match }
        return projects.first { URL(fileURLWithPath: $0.record.projectFolder ?? "").lastPathComponent == "Chatterbox" }
    }

    /// Feedback, step 1: a picture of `window` (toolbar and all), opened for annotating.
    func startFeedback(from window: NSWindow?) {
        guard let window, let frame = window.contentView?.superview ?? window.contentView,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        feedbackShot = try? Attachments.importImageData(png, name: "Chatterbox feedback " + stamp.string(from: Date()))
    }

    /// Feedback, step 2: the annotated screenshot and notes wait in the Chatterbox session's
    /// message box, which opens, for you to finish typing and send.
    func placeFeedback(text: String, attachments: [Attachment]) {
        guard let project = feedbackProject else {
            let alert = NSAlert()
            alert.messageText = "No Chatterbox project"
            alert.informativeText = "Feedback goes to the project session for Chatterbox's folder. Open that folder as a project, or choose one in Settings."
            alert.runModal()
            return
        }
        showingHome = false; showingSettings = false; showingCommandCenter = false; showingAutomations = false
        selectedID = project.id
        composerInsertion = ComposerInsertion(session: project.id, text: text, attachments: attachments)
    }
}

