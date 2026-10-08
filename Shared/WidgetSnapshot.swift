import Foundation
import Security

/// What the iPhone widget shows: chats waiting on you, new replies, and chats working now.
/// The Chatterbox app writes it whenever its chat list changes or you open a chat; the
/// widget reads it, since a widget can't hold a connection to the Mac itself. It's kept in a
/// Keychain group both share (ChatterboxSharedKeychainGroup in their Info.plists): the team's
/// signing already allows that, where an app group would need registering with Apple first.
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

    private static var group: String? { Bundle.main.object(forInfoDictionaryKey: "ChatterboxSharedKeychainGroup") as? String }
    private static func query(_ group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.shelbyklein.Chatterbox.widget",
         kSecAttrAccount as String: "snapshot", kSecAttrAccessGroup as String: group]
    }

    static func load() -> WidgetSnapshot {
        guard let group else { return .empty }
        var query = query(group)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Saves it; returns false when nothing changed, so callers can skip reloading the widget.
    @discardableResult
    func save() -> Bool {
        guard let group = Self.group else { return false }
        var unchanged = Self.load()
        unchanged.updatedAt = updatedAt
        if unchanged == self { return false }
        guard let data = try? Self.encoder.encode(self) else { return false }
        let query = Self.query(group)
        // Readable by the widget while the phone is locked after its first unlock.
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecSuccess { return true }
        return SecItemAdd(query.merging(values) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
