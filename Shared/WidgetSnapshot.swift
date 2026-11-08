import Foundation

/// Fixed quick starts shared by the widget and the phone. Links never supply arbitrary settings.
enum WidgetChatShortcut: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude" }
    var modelTitle: String { self == .codex ? "Sol" : "Opus 5.5" }
    var model: String { self == .codex ? "gpt-6.1-sol" : "claude-opus-5-5" }
    var effort: String { "medium" }
    var link: URL { URL(string: "\(Flavor.current.urlScheme)://new-chat/\(rawValue)")! }
    static let widgetKind = "ChatterboxNewChat"
    static let selectionKey = "newChatWidgetProvider"
    static var preferences: UserDefaults {
        Flavor.current.appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static var fieldLink: URL { URL(string: "\(Flavor.current.urlScheme)://new-chat")! }

    static func selected(in preferences: UserDefaults = Self.preferences) -> Self {
        preferences.string(forKey: selectionKey).flatMap(Self.init(rawValue:)) ?? .codex
    }

    static func select(_ provider: Self, in preferences: UserDefaults = Self.preferences) {
        preferences.set(provider.rawValue, forKey: selectionKey)
    }

    init?(url: URL, preferences: UserDefaults = Self.preferences) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Flavor.current.urlScheme, parts.host == "new-chat",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        if parts.path.isEmpty { self = Self.selected(in: preferences); return }
        guard let shortcut = Self(rawValue: String(parts.path.dropFirst())), parts.path == "/\(shortcut.rawValue)" else { return nil }
        self = shortcut
    }
}

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

            var compactLabel: String {
                label.replacingOccurrences(of: "Weekly limit", with: "7d")
                    .replacingOccurrences(of: "-hour", with: "h")
                    .replacingOccurrences(of: "-day", with: "d")
                    .replacingOccurrences(of: "-minute", with: "m")
                    .replacingOccurrences(of: " window", with: "")
            }

            /// Text and meters must agree about unavailable or expired readings.
            func usedFraction(at date: Date) -> Double? {
                guard let fraction, fraction.isFinite, resetsAt.map({ $0 > date }) ?? true else { return nil }
                return min(1, max(0, fraction))
            }

            func text(at date: Date) -> String {
                let name = compactLabel
                guard let fraction = usedFraction(at: date) else {
                    return "\(name) —"
                }
                return "\(name) \(Int((fraction * 100).rounded()))%"
            }
        }
        struct Account: Codable, Equatable {
            var provider: String
            var name: String
            var status: String
            /// Normalized to used, unlike proxy remaining fractions on the companion wire.
            var windows: [Window]
            var problem: String?

            func tightest(at date: Date) -> Window? {
                windows.filter { $0.usedFraction(at: date) != nil }
                    .max { ($0.usedFraction(at: date) ?? 0) < ($1.usedFraction(at: date) ?? 0) }
            }
        }
        var syncedAt: Date
        var claude: [Window]
        var codex: [Window]
        var proxyAccounts: [Account]? = nil
        var proxyChecked: Date? = nil
        var proxyProblem: String? = nil
        var proxyRefreshing: Bool? = nil

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
