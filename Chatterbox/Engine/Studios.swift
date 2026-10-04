import AppKit
import Foundation

extension AppModel {
    /// Studios by name, leaving out archived ones.
    var activeStudios: [Studio] {
        studios.filter { $0.archivedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func studio(_ id: UUID?) -> Studio? {
        guard let id else { return nil }
        return studios.first { $0.id == id }
    }

    func studio(for session: ChatSession) -> Studio? { studio(session.record.studioID) }

    /// A Studio's open chats, most recent first.
    func chats(in studio: Studio) -> [ChatSession] {
        activeSessions.filter { $0.record.studioID == studio.id && !hasVisibleSidechatParent($0) && !hasVisibleConvertedParent($0) }
    }

    func hasVisibleConvertedParent(_ chat: ChatSession) -> Bool {
        guard let folder = chat.record.worktreeOf else { return false }
        return activeSessions.contains {
            $0.record.studioID == chat.record.studioID && $0.record.convertedProjectFolder.map(Self.normalize) == Self.normalize(folder)
        }
    }

    func studioFamily(of parent: ChatSession) -> [ChatSession] {
        var family = [parent] + sidechats(of: parent)
        if parent.record.convertedProjectFolder != nil {
            for child in worktrees(of: parent) { family += [child] + sidechats(of: child) }
        }
        return family
    }

    /// Where new Studio folders go: ~/Chatterbox/Studios (inside the data folder under tests).
    static var studiosBase: URL {
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("Studios", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Chatterbox/Studios", isDirectory: true)
    }

    /// Makes a Studio with its own new folder (or `folder`, if given) and opens its first chat.
    /// `moving` goes in as that first chat instead, when making a Studio from a chat.
    @discardableResult
    func newStudio(named name: String, folder: String? = nil, moving session: ChatSession? = nil) -> Studio? {
        if let session {
            guard session.record.projectFolder == nil, !session.isRunning, !session.isRestartingThread, !session.isDot, session.record.archivedAt == nil else { return nil }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Studio" : trimmed
        guard let path = folder ?? Self.makeStudioFolder(named: name) else { return nil }
        let studio = Studio(name: name, folder: Self.normalize(path))
        studio.ensureDesignFile()
        studios.append(studio)
        saveStudios()
        if let session { move(session, to: studio) } else { newChat(in: studio) }
        return studio
    }

    /// Converts a project in place; no files, branches or worktree folders move.
    @discardableResult
    func convertProjectToStudio(_ session: ChatSession, named name: String) -> Studio? {
        guard let folder = session.record.projectFolder ?? session.record.convertedProjectFolder, session.record.worktreeOf == nil,
              session.record.archivedAt == nil, !session.isDot, !session.isRunning, !session.isRestartingThread else { return nil }
        for path in [folder, session.workingFolder] {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let studio = Studio(name: trimmed.isEmpty ? session.projectName : trimmed, folder: Self.normalize(session.workingFolder))
        studio.ensureDesignFile()
        studios.append(studio)
        saveStudios()
        return convertProjectToStudio(session, into: studio, keepFolder: true)
    }

    /// Joins an existing Studio without moving files. Worktrees and Sidechats retain their cwd.
    @discardableResult
    func convertProjectToStudio(_ session: ChatSession, into studio: Studio, keepFolder: Bool = true) -> Studio? {
        guard let folder = session.record.projectFolder ?? session.record.convertedProjectFolder, session.record.worktreeOf == nil,
              session.record.archivedAt == nil, !session.isDot, !session.isRunning, !session.isRestartingThread,
              studio.archivedAt == nil, activeStudios.contains(where: { $0.id == studio.id && $0.folder == studio.folder }) else { return nil }
        for path in [folder, session.workingFolder, studio.folder] {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
        }
        let children = worktrees(of: session)
        let sidechats = sidechats(of: session) + children.flatMap { self.sidechats(of: $0) }
        session.setStudio(studio, keepingFolder: keepFolder ? session.workingFolder : nil, convertedProject: folder)
        let oldPlace = PinPlace(key: "project:" + folder, name: session.projectName)
        for pin in PinStore.shared.pins(in: oldPlace) { PinStore.shared.setPlace(pin, to: PinPlace(key: "studio:" + studio.id.uuidString, name: studio.name)) }
        // Worktrees keep their own folders and Git metadata. Only their group
        // changes; an active child process is never restarted by conversion.
        for child in children + sidechats {
            child.record.studioID = studio.id
            child.record.studioFolder = studio.folder
            child.onChange?(child)
        }
        setStudio(studio.id, collapsed: false)
        selectedID = session.id
        return studio
    }

    /// A new folder named after the Studio, numbered if the name is taken.
    private static func makeStudioFolder(named name: String) -> String? {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        var url = studiosBase.appendingPathComponent(safe, isDirectory: true)
        var number = 2
        while fm.fileExists(atPath: url.path) {
            url = studiosBase.appendingPathComponent("\(safe) \(number)", isDirectory: true)
            number += 1
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        } catch {
            NSLog("Chatterbox: couldn't make a Studio folder: \(error)")
            return nil
        }
    }

    /// Opens a new chat in the Studio, reusing an empty one that's already there.
    @discardableResult
    func newChat(in studio: Studio, backend: Backend? = nil) -> ChatSession {
        if let empty = chats(in: studio).first(where: { $0.items.isEmpty && !$0.isRunning }) {
            if let backend { empty.setBackend(backend) }
            selectedID = empty.id
            return empty
        }
        let session = newChat(backend: backend)
        session.setStudio(studio)
        setStudio(studio.id, collapsed: false)
        return session
    }

    /// Move a regular thread with an explicit working-folder choice.
    @discardableResult
    func joinStudio(_ session: ChatSession, studio: Studio, keepFolder: Bool) -> Bool {
        guard session.record.projectFolder == nil, session.record.archivedAt == nil,
              !session.isDot, !session.isRunning, !session.isRestartingThread,
              studio.archivedAt == nil, activeStudios.contains(where: { $0.id == studio.id && $0.folder == studio.folder }) else { return false }
        for path in [session.workingFolder, studio.folder] {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return false }
        }
        session.setStudio(studio, keepingFolder: keepFolder ? session.workingFolder : nil)
        setStudio(studio.id, collapsed: false)
        return true
    }

    /// Existing move behavior: regular chats use the Studio folder.
    func move(_ session: ChatSession, to studio: Studio?) {
        // Project chats belong to their project folder.
        guard !session.isRunning, studio == nil || session.record.projectFolder == nil else { return }
        session.setStudio(studio)
        if let studio { setStudio(studio.id, collapsed: false) }
    }

    /// The project or Studio whose pins show with this chat open.
    func pinPlace(for session: ChatSession?) -> PinPlace? {
        guard let session else { return nil }
        if let folder = session.record.projectFolder { return PinPlace(key: "project:" + folder, name: session.projectName) }
        if let studio = studio(for: session) { return PinPlace(key: "studio:" + studio.id.uuidString, name: studio.name) }
        return nil
    }

    var selectedPinPlace: PinPlace? { pinPlace(for: selected) }

    /// Whether a chat can be forked: not mid-reply, and not a project's chat (a project
    /// folder has one chat).
    func canFork(_ session: ChatSession) -> Bool {
        // Dot is one of a kind: a copy would take over as Dot (the first one found wins).
        !session.isRunning && !session.isDot && session.record.projectFolder == nil && !session.items.isEmpty
    }

    /// Copies a chat into a new one beside it (in the same Studio, if it's in one) that
    /// carries on from the same point. Each agent branches its own memory of the
    /// conversation on the fork's next message; the original is left as it was.
    @discardableResult
    func fork(_ session: ChatSession) -> ChatSession? {
        guard canFork(session) else { return nil }
        if RuntimeClient.usesDaemon {
            Task {do {let id=try await RuntimeClient.shared.request("fork",body:["chatID":.string(session.id.uuidString)]).string.flatMap(UUID.init(uuidString:));selectedID=id}
                catch{Diagnostics.note(error.localizedDescription)}}
            return nil
        }
        var record = session.record
        record.id = UUID()
        record.title = session.title.hasSuffix("(fork)") ? session.title : session.title + " (fork)"
        record.createdAt = Date()
        record.updatedAt = Date()
        record.archivedAt = nil
        record.forkedFrom = session.id
        if record.convertedProjectFolder != nil {
            record.sidechatProjectFolder = session.convertedProjectScope
            record.convertedProjectFolder = nil
        }
        // Never carry Dot's identity into a copy, even if a caller skips canFork.
        record.isDot = nil
        record.sentDotName = nil
        record.dotFollowing = nil
        record.currentIssue = nil
        record.turnStartedAt = nil
        record.backgroundTasks = nil
        record.claudeHost = nil
        record.codexHost = nil
        record.claudeForkPending = record.claudeSessionID != nil ? true : nil
        if let thread = record.codex?.threadId {
            record.codex?.forkFrom = thread
            record.codex?.threadId = nil
        }
        for index in record.items.indices {
            record.items[index].queued = nil
            if record.items[index].approvalState == .pending { record.items[index].approvalState = .expired }
        }
        record.items.append(DisplayItem(kind: .notice, text: "Forked from \u{201C}\(session.title)\u{201D}. Nothing here changes the original."))
        let fork = insertSession(record)
        selectedID = fork.id
        return fork
    }

    func renameStudio(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateStudio(id) { $0.name = trimmed }
    }

    func setInstructions(_ text: String, forStudio id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateStudio(id) { $0.instructions = trimmed.isEmpty ? nil : trimmed }
    }

    func setStudio(_ id: UUID, collapsed: Bool) {
        guard studio(id)?.collapsed ?? false != collapsed else { return }
        updateStudio(id) { $0.collapsed = collapsed }
    }

    /// Archives the Studio and its chats. Its folder and files stay where they are, and
    /// unarchiving any of its chats brings the Studio back.
    func archiveStudio(_ id: UUID) {
        guard let studio = studio(id) else { return }
        updateStudio(id) { $0.archivedAt = Date() }
        for session in chats(in: studio) { archive(session) }
    }

    func unarchiveStudio(_ id: UUID) {
        updateStudio(id) { $0.archivedAt = nil }
    }

    func openTerminal(at folder: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func updateStudio(_ id: UUID, _ change: (inout Studio) -> Void) {
        guard let index = studios.firstIndex(where: { $0.id == id }) else { return }
        change(&studios[index])
        saveStudios()
    }
}
