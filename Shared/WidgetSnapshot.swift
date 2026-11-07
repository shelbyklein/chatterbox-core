import Foundation

/// What the iPhone widget shows: activity and the account limits last synced by the phone.
/// The Chatterbox app writes it whenever its chat list changes or you open a chat; the
/// widget reads it from their shared app group, since a widget can't hold a connection to the
/// Mac itself.
struct WidgetSnapshot: Codable, Equatable {
    struct Usage: Codable, Equatable {
        struct Window: Codable, Equatable {
            var label: String
            var fraction: Double?
            var resetsAt: Date?

            /// Text and meters must agree about unavailable or expired readings.
            func usedFraction(at date: Date) -> Double? {
                guard let fraction, fraction.isFinite, resetsAt.map({ $0 > date }) ?? true else { return nil }
                return min(1, max(0, fraction))
            }

            func text(at date: Date) -> String {
                let name = label.replacingOccurrences(of: "-hour", with: "h")
                    .replacingOccurrences(of: "-day", with: "d")
                guard let fraction = usedFraction(at: date) else {
                    return "\(name) —"
                }
                return "\(name) \(Int((fraction * 100).rounded()))%"
            }
        }
        var syncedAt: Date
        var claude: [Window]
        var codex: [Window]

        static func summary(_ windows: [Window], at date: Date) -> String {
            guard !windows.isEmpty else { return "Not reported" }
            return windows.prefix(2).map { $0.text(at: date) }.joined(separator: " · ") + " used"
        }
    }
    struct Item: Codable, Equatable, Identifiable {
        var chatID: UUID
        var title: String
        var detail: String?
        /// "claude" or "codex": picks the row's color.
        var backend: String
        /// When it finished, started working, or started waiting.
        var date: Date
        var id: UUID { chatID }
        var link: URL { URL(string: "\(Flavor.current.urlScheme)://chat/\(chatID.uuidString)")! }
    }

    var updatedAt: Date
    var macName: String
    var waiting: [Item]
    var newReplies: [Item]
    var working: [Item]
    var usage: Usage? = nil

    static let empty = WidgetSnapshot(updatedAt: .distantPast, macName: "", waiting: [], newReplies: [], working: [])

    static let appGroup = Flavor.current.appGroup
    private static var file: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot {
        load(from: file)
    }

    static func load(from file: URL?) -> WidgetSnapshot {
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Saves it; returns false when nothing changed, so callers can skip reloading the widget.
    @discardableResult
    func save() -> Bool {
        save(to: Self.file)
    }

    @discardableResult
    func save(to file: URL?) -> Bool {
        guard let file else { return false }
        var unchanged = Self.load(from: file)
        unchanged.updatedAt = updatedAt
        if unchanged == self { return false }
        guard let data = try? Self.encoder.encode(self) else { return false }
        // Readable by the widget while the phone is locked after its first unlock.
        return (try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
