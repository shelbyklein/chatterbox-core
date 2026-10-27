import Foundation

enum ChatPromotion {
    @MainActor static func eligible(_ chat: ChatSession) -> Bool {
        let r = chat.record
        return r.archivedAt == nil && r.projectFolder == nil && r.studioID == nil
            && r.sidechatOf == nil && r.worktreeOf == nil && r.convertedProjectFolder == nil && r.automationID == nil
    }

    static func directory(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw RuntimeFailure("Choose an absolute folder path on your Mac.") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true else { throw RuntimeFailure("Choose a folder, not a file or app.") }
        return url
    }

    static func folderName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw RuntimeFailure("Enter a folder name without slashes or colons.")
        }
        return name
    }

    /// Directory names only, off the service actor. No file contents or package internals.
    static func folders(at path: String?) throws -> Companion.ProjectFolders {
        let url = try directory(path ?? NSHomeDirectory())
        let children = try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
        let folders = children.compactMap { child -> Companion.ProjectFolders.Folder? in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true, values.isPackage != true else { return nil }
            return .init(path: child.path, name: child.lastPathComponent)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return .init(path: url.path, parent: url.path == "/" ? nil : url.deletingLastPathComponent().path, folders: folders)
    }
}

extension ConversationRuntime {
    /// The companion keeps one conversation: promotion changes its location, never its history.
    func promote(_ chat: ChatSession, using request: Companion.PromotionRequest) throws {
        guard ChatPromotion.eligible(chat) else { throw RuntimeFailure("Only ordinary, unarchived sessions can be promoted.") }
        guard !chat.isRunning, !chat.hasBackgroundWork, !chat.isRestartingThread, !chat.awaitingHostResume else {
            throw RuntimeFailure("Wait for this session's reply to finish before promoting it.")
        }
        let before = chat.record
        let previousStudios = studios
        var createdFolder: URL?
        var addedStudio: Studio?
        do {
            switch request.kind {
            case .studio:
                let destination: Studio
                if let id = request.studioID {
                    guard let existing = studios.first(where: { $0.id == id && $0.archivedAt == nil }) else {
                        throw RuntimeFailure("That Studio is no longer available. Choose another one.")
                    }
                    _ = try ChatPromotion.directory(existing.folder)
                    if request.keepFolder { _ = try ChatPromotion.directory(chat.workingFolder) }
                    destination = existing
                } else {
                    let name = try ChatPromotion.folderName(request.name ?? "")
                    let base = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"].map {
                        URL(fileURLWithPath: $0).appendingPathComponent("Studios", isDirectory: true)
                    } ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Chatterbox/Studios", isDirectory: true)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    var url = base.appendingPathComponent(name, isDirectory: true), number = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        url = base.appendingPathComponent("\(name) \(number)", isDirectory: true); number += 1
                    }
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    createdFolder = url
                    destination = Studio(name: name, folder: url.resolvingSymlinksInPath().path)
                    addedStudio = destination
                    try updateStudios(studios + [destination])
                }
                chat.setStudio(destination, keepingFolder: request.studioID != nil && request.keepFolder ? chat.workingFolder : nil)
            case .project:
                var folder = try ChatPromotion.directory(request.folder ?? "")
                if let name = request.newFolderName {
                    folder = folder.appendingPathComponent(try ChatPromotion.folderName(name), isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: folder.path) else {
                        throw RuntimeFailure("That folder already exists. Choose it as an existing folder or use another name.")
                    }
                }
                let path = folder.resolvingSymlinksInPath().path
                guard !sessions.contains(where: { other in
                    other.id != chat.id && (other.record.projectFolder ?? other.record.convertedProjectFolder).map(RuntimePaths.normalize) == path
                }) else { throw RuntimeFailure("That folder already has a project chat. Choose another folder.") }
                if request.newFolderName != nil {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    createdFolder = folder
                }
                chat.bindProject(path)
            }
            try flush()
            addedStudio?.ensureDesignFile()
        } catch {
            chat.record = before
            chat.onChange?(chat)
            if studios != previousStudios { try? updateStudios(previousStudios) }
            try? flush()
            // Only remove a directory this operation made, and only while still empty.
            if let createdFolder, (try? FileManager.default.contentsOfDirectory(atPath: createdFolder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: createdFolder)
            }
            throw error
        }
    }
}
