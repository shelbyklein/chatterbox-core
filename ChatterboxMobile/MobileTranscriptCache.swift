import Foundation

/// The last transcript of each chat this phone loaded, so opening one shows its text at once
/// while the Mac's copy loads, and the last chat list, so they can be found without the Mac.
/// The 30 most recent transcripts, in Caches; cleared when the phone disconnects.
enum MobileTranscriptCache {
    static let limit = 30
    private static let queue = DispatchQueue(label: "mobile.transcript-cache", qos: .utility)
    private static var directory: URL {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["CHATTERBOX_TEST_TRANSCRIPT_CACHE"] { return URL(fileURLWithPath: test, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripts", isDirectory: true)
    }
    private static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    /// Beside the transcripts, so it never counts against their limit.
    private static var listFile: URL { directory.deletingLastPathComponent().appendingPathComponent("Transcripts-chats.json") }

    static func loadList() -> Companion.ChatList? {
        guard let data = try? Data(contentsOf: listFile) else { return nil }
        return try? Companion.decoder.decode(Companion.ChatList.self, from: data)
    }

    static func saveList(_ list: Companion.ChatList) {
        guard let data = try? Companion.encoder.encode(list) else { return }
        let url = listFile
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func load(_ id: UUID) -> Companion.ChatDetail? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? Companion.decoder.decode(Companion.ChatDetail.self, from: data)
    }

    static func save(_ detail: Companion.ChatDetail) {
        guard let data = try? Companion.encoder.encode(detail) else { return }
        let url = file(detail.summary.id)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // Newest first; past the limit, the oldest go.
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            guard files.count > limit else { return }
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) { try? fm.removeItem(at: old) }
        }
    }

    static func clear() {
        let list = listFile
        queue.async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: list)
        }
    }

    /// Waits for saves and clears already queued (tests).
    static func flush() { queue.sync {} }
}
