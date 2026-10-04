import AppKit
import Foundation
import Observation

/// Owns the list of conversations and saves each one as JSON in Application Support.
@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [ChatSession] = []
    /// Groups of chats sharing a folder (see Studios.swift).
    var studios: [Studio] = []
    /// The Studio whose instructions are open for editing.
    var editingStudioInstructions: UUID?
    var selectedID: UUID? {
        didSet {
            showingHome = false
            showingCommandCenter = false
            guard selectedID != oldValue, let session = sessions.first(where: { $0.id == selectedID }) else { return }
            Diagnostics.note("Opened \u{201C}\(session.title)\u{201D} (\(session.items.count) rows\(session.isRunning ? ", working" : ""))")
            if RuntimeClient.usesDaemon {Task { [weak self] in
                do {let state=try await RuntimeClient.shared.request("get",body:["chatID":.string(session.id.uuidString)]).decode(RuntimeChatState.self);self?.applyProjection(state)}
                catch {Diagnostics.note(error.localizedDescription)}
            }}
        }
    }
    var showingCloneFromGitHub = false
    var showingNewProject = false
    /// Settings, shown in the main window in place of the chat.
    var showingHome = false { didSet { if showingHome { showingCommandCenter = false } } }
    var showingCommandCenter = false { didSet { if showingCommandCenter { showingHome = false; showingSettings = false } } }
    var showingSettings = false { didSet { if showingSettings { showingHome = false; showingCommandCenter = false } } }
    /// The independent, always-on-top Golem mini window (⌘J).
    var showingDot = false {
        didSet {
            guard showingDot != oldValue else { return }
            #if GOLEM_APP
            AppPreferences.defaults.set(showingDot, forKey: GolemMiniWindow.visibleKey)
            if showingDot {
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

    /// Projects (by recent activity, staleness, or name), then each open Studio's chats, then other chats by most recent: the
    /// sidebar's order, which the ⌘1–⌘9 shortcuts follow.
    var sidebarProjects: [ChatSession] {
        let projects = activeSessions.filter { $0.record.projectFolder != nil && $0.record.worktreeOf == nil && !$0.isDot }
        let byName: (ChatSession, ChatSession) -> Bool = { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
        switch ProjectSort.current {
        case .name: return projects.sorted(by: byName)
        case .recent: return projects.sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : byName($0, $1) }
        case .stalest: return projects.sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity < $1.lastActivity : byName($0, $1) }
        }
    }
    /// Chats in neither a project nor a Studio. A chat whose Studio is gone shows here too.
    var sidebarChats: [ChatSession] {
        let studioIDs = Set(activeStudios.map(\.id))
        return activeSessions.filter { session in
            session.record.projectFolder == nil && !session.isDot && !hasVisibleSidechatParent(session) && !(session.record.studioID.map(studioIDs.contains) ?? false)
        }
    }
    var sidebarOrder: [ChatSession] {
        var ordered: [ChatSession] = []
        for project in sidebarProjects {
            ordered += [project] + sidechats(of: project)
            for worktree in worktrees(of: project) { ordered += [worktree] + sidechats(of: worktree) }
        }
        for studio in activeStudios where studio.collapsed != true {
            for chat in chats(in: studio) { ordered += studioFamily(of: chat) }
        }
        for chat in sidebarChats { ordered += [chat] + sidechats(of: chat) }
        return ordered
    }

    func hasVisibleSidechatParent(_ chat: ChatSession) -> Bool {
        guard let parent = chat.record.sidechatOf else { return false }
        return activeSessions.contains { $0.id == parent && !$0.isDot }
    }

    func sidechats(of parent: ChatSession) -> [ChatSession] {
        activeSessions.filter { $0.record.sidechatOf == parent.id }.sorted { $0.lastActivity > $1.lastActivity }
    }

    @discardableResult
    func newSidechat(of parent: ChatSession) -> ChatSession {
        // Always anchor at the original parent; don't make a recursive tree of
        // temporary chats or resume either of its provider sessions.
        let anchor = parent.record.sidechatOf.flatMap { id in sessions.first { $0.id == id } } ?? parent
        var record = ConversationRecord(model: parent.record.model, effort: parent.record.effort, personality: parent.record.personality)
        let number = sessions.filter { $0.record.sidechatOf == anchor.id }.count + 1
        record.title = (number == 1 ? "Sidechat" : "Sidechat \(number)") + " · "
            + (anchor.record.projectFolder != nil ? anchor.projectName : anchor.title)
        record.sidechatOf = anchor.id
        record.sidechatFolder = parent.workingFolder
        record.sidechatProjectFolder = parent.record.sidechatProjectFolder ?? parent.convertedProjectScope ?? parent.record.worktreeOf ?? parent.record.projectFolder
        record.activeBackend = parent.record.backend
        record.claudeFastMode = parent.record.claudeFastMode
        record.claudeMode = parent.record.claudeMode
        record.claudeCanEdit = parent.record.claudeCanEdit
        record.useComputer = parent.record.useComputer
        record.tags = parent.record.tags
        record.studioID = parent.record.studioID
        record.studioFolder = parent.record.studioFolder
        record.codex = parent.record.codex
        record.codex?.threadId = nil
        record.codex?.forkFrom = nil
        record.codex?.sentRoute = nil
        record.codex?.folder = parent.workingFolder
        let chat = insertSession(record)
        selectedID = chat.id
        return chat
    }

    /// Every tag in use, for the Tags menu.
    var allTags: [String] {
        var seen: [String: String] = [:]
        for tag in sessions.flatMap(\.tags) where seen[tag.lowercased()] == nil { seen[tag.lowercased()] = tag }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Selects the chat at a 1-based position in the sidebar.
    func selectChat(number: Int) {
        let order = sidebarOrder
        guard order.indices.contains(number - 1) else { return }
        selectedID = order[number - 1].id
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
        if RuntimeClient.usesDaemon {
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
        // First, so a hang during launch is caught too.
        Diagnostics.shared.start()
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
        Task { await DotComputer.shared.refresh() }
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
        PreviewRelays.shared.start()
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
        if RuntimeClient.usesDaemon {
            if !Self.keepRepliesRunning {for session in sessions where !session.isDot && session.isRunning {session.interrupt()}}
            return
        }
        Diagnostics.shared.stop()
        for session in sessions { session.killShellJobs() }
        saveUnsaved()
        guard !Self.keepRepliesRunning else { return }
        for session in sessions { session.claudeProcess?.terminate() }
        CodexAppServer.shared.terminate()
    }

    @discardableResult
    func newChat(backend: Backend? = nil) -> ChatSession {
        let defaults = AppPreferences.defaults
        let backend = backend ?? Backend(rawValue: defaults.string(forKey: "defaultBackend") ?? "") ?? .claude
        if let empty = sessions.first(where: { $0.items.isEmpty && !$0.isRunning && $0.record.projectFolder == nil && $0.record.studioID == nil && $0.record.archivedAt == nil && !$0.isDot && !carriesUserIntent($0.record) }) {
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
        guard !session.items.isEmpty || session.record.projectFolder != nil || session.record.sidechatOf != nil else { return delete(session) }
        session.shutdown()
        session.setArchived(true)
        if selectedID == session.id { selectedID = activeSessions.first?.id }
        if activeSessions.isEmpty { newChat() }
    }

    func unarchive(_ session: ChatSession) {
        if let studio = studio(for: session), studio.archivedAt != nil { unarchiveStudio(studio.id) }
        session.setArchived(false)
        selectedID = session.id
    }

    func delete(_ session: ChatSession) {
        if RuntimeClient.usesDaemon {
            RuntimeClient.shared.command("delete",body:["chatID":.string(session.id.uuidString)])
            return
        }
        session.shutdown()
        unsaved.remove(session.id)
        // A fork shares its original's attachment files; keep any another chat still shows.
        let inUse = Set(sessions.filter { $0.id != session.id }.flatMap(\.allAttachments).map(\.path))
        Attachments.remove(session.allAttachments.filter { !inUse.contains($0.path) })
        sessions.removeAll { $0.id == session.id }
        try? FileManager.default.removeItem(at: fileURL(session.id))
        if selectedID == session.id { selectedID = activeSessions.first?.id }
        if activeSessions.isEmpty { newChat() }
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
        guard let main = project.record.projectFolder else { throw WorktreeError(message: "That chat isn't a project.") }
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
        let session = newChat(backend: backend)
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
        if let folder = FolderPicker.choose(startingAt: nil, message: "Choose a project folder. Its chat opens, or a new one starts.") {
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
        if CodexAppServer.shared.isRunning { CodexAppServer.shared.saveResumeState() }
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
        CodexAppServer.shared.resume(processes)
        applyRequestedDotDefault()
        // Logs of ended processes no chat points at anymore. Running ones are left alone: the
        // host lets an agent go once it's idle with no app attached.
        var known = Set(sessions.compactMap { $0.claudeProcess?.hostID })
        if let codex = CodexAppServer.shared.hostID { known.insert(codex) }
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
        if record.remoteControl != nil || record.useComputer == true || record.currentIssue != nil { return true }
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
        session.remoteCommand = { operation, payload in
            var body=payload.object ?? [:];body["chatID"] = .string(chatID.uuidString)
            RuntimeClient.shared.command(operation,body:.object(body))
        }
        session.onChange = { [weak self] changed in
            guard self?.projecting == false else{return}
            var metadata=changed.record;metadata.items=[]
            RuntimeClient.shared.command("metadata",body:["record":(try? .value(metadata)) ?? .null])
        }
    }
    private func applyProjection(_ state:RuntimeChatState) {
        #if !GOLEM_APP
        guard state.record.isDot != true else{return}
        #endif
        projecting=true;defer{projecting=false}
        if let session=sessions.first(where:{$0.id==state.record.id}) {
            session.applyingRemoteState=true
            var record=state.record
            if let total=state.totalCount,total>record.items.count,let first=record.items.first?.id,
               let index=session.items.firstIndex(where:{$0.id==first}) {record.items=Array(session.items.prefix(index))+record.items}
            session.record=record;session.isRunning=state.running
            if let draft=state.draft{session.draft=draft.text;session.draftAttachments=draft.attachments}
            session.applyingRemoteState=false
            Attention.shared.update(session,model:self)
        }else{
            let session=ChatSession(record:state.record);session.isRunning=state.running
            if let draft=state.draft{session.draft=draft.text;session.draftAttachments=draft.attachments}
            bindProjection(session);sessions.append(session)
        }
        if selectedID==nil {selectedID=sessions.first(where:{!$0.isDot})?.id}
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
        #endif
        if event.kind=="runtime.resync" || event.kind=="runtime.configuration" || event.kind=="chat.created" || event.kind=="chat.deleted" {
            Task {
                do {
                    let states=try await RuntimeClient.shared.request("list").decode([RuntimeChatState].self)
                    studios=try await RuntimeClient.shared.request("getStudios").decode([Studio].self)
                    await RuntimePreferenceProjection.shared.start()
                    PinStore.shared.applyRuntimePins(try await RuntimeClient.shared.request("getPins").decode([Pin].self))
                    let ids=Set(states.map{ $0.record.id });sessions.removeAll{!ids.contains($0.id)}
                    for state in states {applyProjection(state)}
                }catch{Diagnostics.note(error.localizedDescription)}
            }
        }else if let id=event.chatID {
            guard refreshTasks[id]==nil else{return}
            refreshTasks[id]=Task {
                try? await Task.sleep(for:.milliseconds(100))
                defer{refreshTasks[id]=nil}
                do{let state=try await RuntimeClient.shared.request("get",body:["chatID":.string(id.uuidString),"limit":40]).decode(RuntimeChatState.self);applyProjection(state)}
                catch{Diagnostics.note(error.localizedDescription)}
            }
        }
    }

}
