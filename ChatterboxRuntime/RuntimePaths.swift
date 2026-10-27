import Foundation

/// Shared identities stay stable when a UI is replaced or a daemon is restarted.
enum RuntimePaths {
    static var data: URL {
        if let path = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chatterbox", isDirectory: true)
    }
    static func normalize(_ folder: String) -> String { URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path }
    static func effortLabel(_ effort: String) -> String { effort == "xhigh" ? "Extra High" : effort.capitalized }
}

/// Runtime emits domain activity; each process supplies its own side effects.
/// The conversation core never starts a UI or a scheduler.
@MainActor enum RuntimeHooks {
    static var note: (String) -> Void = { _ in }
    static var clearSuggestions: (ChatSession) -> Void = { _ in }
    static var turnEnded: (ChatSession) -> Void = { $0.automaticTurn = false }
}
