import Foundation

/// Shared identities stay stable when a UI is replaced or a daemon is restarted.
enum RuntimePaths {
    static var data: URL {
        if let path = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chatterbox", isDirectory: true)
    }
    static var assistantFolder: String {
        if let path=ProcessInfo.processInfo.environment["CHATTERBOX_ASSISTANT_DIR"] {return URL(fileURLWithPath:path).standardizedFileURL.path}
        let root = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Chatterbox")
        let folder = root.appendingPathComponent("Dot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }
    static var assistantMemoryFolder: URL {
        if let path=ProcessInfo.processInfo.environment["CHATTERBOX_MEMORY_DIR"] {return URL(fileURLWithPath:path,isDirectory:true)}
        let cwd = realpath(assistantFolder, nil).map { p in defer { free(p) }; return String(cString: p) } ?? assistantFolder
        let encoded = cwd.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects/\(encoded)/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func normalize(_ folder: String) -> String { URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path }
    static func effortLabel(_ effort: String) -> String { effort == "xhigh" ? "Extra High" : effort.capitalized }
}

/// Runtime emits domain activity; each process supplies its own side effects.
/// The conversation core never starts a UI or an assistant scheduler.
@MainActor enum RuntimeHooks {
    static var note: (String) -> Void = { _ in }
    static var clearSuggestions: (ChatSession) -> Void = { _ in }
    static var turnEnded: (ChatSession) -> Void = { $0.automaticTurn = false }
    static var answered: (ChatSession, DisplayItem, [String:[String]], [String:[String]]?) -> Void = { _,_,_,_ in }
    static var suggested: (ChatSession, DisplayItem) -> Void = { _,_ in }
}
