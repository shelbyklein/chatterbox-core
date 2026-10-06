import Foundation

/// How the sidebar orders projects.
enum ProjectSort: String, CaseIterable {
    case recent, active, stalest, name

    static let key = "sidebarProjectSort"
    static var current: ProjectSort { AppPreferences.defaults.string(forKey: key).flatMap(Self.init) ?? .recent }

    var label: String {
        switch self {
        case .recent: "Recent Activity"
        case .active: "Most Active"
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

    /// How busy it is, for "Most Active": turns in the last day, then the last week (from the
    /// turn times chats record), then its lifetime average a day (for chats from before that).
    var activityRank: (day: Int, week: Int, perDay: Double) {
        let now = Date()
        let dates = record.turnDates ?? []
        let day = dates.filter { now.timeIntervalSince($0) < 86_400 }.count
        let week = dates.filter { now.timeIntervalSince($0) < 7 * 86_400 }.count
        let turns = max(dates.count, items.reduce(0) { $0 + ($1.kind == .user ? 1 : 0) })
        let days = max(1, now.timeIntervalSince(record.createdAt) / 86_400)
        return (day, week, Double(turns) / days)
    }

    /// Quiet for two weeks or more.
    var isStale: Bool { Date().timeIntervalSince(lastActivity) >= 14 * 86_400 }
}
