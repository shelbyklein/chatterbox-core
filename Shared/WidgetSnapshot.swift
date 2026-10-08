import Foundation

/// What the iPhone widget shows: chats waiting on you, new replies, and chats working now.
/// The Chatterbox app writes it whenever its chat list changes or you open a chat; the
/// widget reads it from their shared app group, since a widget can't hold a connection to the
/// Mac itself.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var chatID: UUID
        var title: String
        var detail: String?
        /// "claude" or "codex": picks the row's color.
        var backend: String
        /// When it finished, started working, or started waiting.
        var date: Date
        var id: UUID { chatID }
        var link: URL { URL(string: "chatterbox://chat/\(chatID.uuidString)")! }
    }

    var updatedAt: Date
    var macName: String
    var waiting: [Item]
    var newReplies: [Item]
    var working: [Item]

    static let empty = WidgetSnapshot(updatedAt: .distantPast, macName: "", waiting: [], newReplies: [], working: [])

    static let appGroup = "group.com.shelbyklein.Chatterbox"
    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot {
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Saves it; returns false when nothing changed, so callers can skip reloading the widget.
    @discardableResult
    func save() -> Bool {
        guard let file = Self.file else { return false }
        var unchanged = Self.load()
        unchanged.updatedAt = updatedAt
        if unchanged == self { return false }
        guard let data = try? Self.encoder.encode(self) else { return false }
        // Readable by the widget while the phone is locked after its first unlock.
        return (try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
