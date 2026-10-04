import Foundation

/// How the sidebar orders projects.
enum ProjectSort: String, CaseIterable {
    case recent, stalest, name

    static let key = "sidebarProjectSort"
    static var current: ProjectSort { AppPreferences.defaults.string(forKey: key).flatMap(Self.init) ?? .recent }

    var label: String {
        switch self {
        case .recent: "Recent Activity"
        case .stalest: "Stalest First"
        case .name: "Name"
        }
    }
}

/// Which projects the sidebar shows, by how recently they were active.
enum ProjectActivity: String, CaseIterable {
    case all, active, stale

    var label: String {
        switch self {
        case .all: "All Projects"
        case .active: "Active This Week"
        case .stale: "Stale (2+ Weeks)"
        }
    }

    @MainActor func includes(_ session: ChatSession) -> Bool {
        switch self {
        case .all: true
        case .active: Date().timeIntervalSince(session.lastActivity) < 7 * 86_400
        case .stale: session.isStale
        }
    }
}

extension ChatSession {
    /// When you or its agent last did something here: a message sent or a reply finished.
    var lastActivity: Date { max(record.updatedAt, record.createdAt) }

    /// Quiet for two weeks or more.
    var isStale: Bool { Date().timeIntervalSince(lastActivity) >= 14 * 86_400 }
}
