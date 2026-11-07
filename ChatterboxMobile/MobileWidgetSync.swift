import Foundation
import WidgetKit

/// Keeps activity and account limits together in the widget's shared snapshot.
@MainActor
enum MobileWidgetSync {
    private static var lastList: Companion.ChatList?
    private static var lastMac = ""
    private static var lastUsage = WidgetSnapshot.load().usage

    static func proxyCheckPending(_ usage: Companion.Usage) -> Bool {
        usage.proxyAccounts != nil && usage.proxyChecked == nil && usage.proxyProblem == nil
    }

    static func updateUsage(_ usage: Companion.Usage, at date: Date) {
        func windows(_ source: [Companion.Usage.Window]) -> [WidgetSnapshot.Usage.Window] {
            source.map { .init(label: $0.label, fraction: $0.fraction, resetsAt: $0.resetsAt) }
        }
        let accounts = usage.proxyAccounts?.map { account in
            WidgetSnapshot.Usage.Account(provider: account.provider, name: account.name, status: account.status,
                windows: account.windows.map { window in
                    let used = window.fraction.flatMap { $0.isFinite ? 1 - min(1, max(0, $0)) : nil }
                    return .init(label: window.label, fraction: used, resetsAt: window.resetsAt)
                }, problem: account.problem)
        }
        // A service restart clears its quota cache. Keep previously checked readings while
        // it checks again, with their original timestamp and an explicit checking state.
        let keepChecked = proxyCheckPending(usage) && lastUsage?.proxyChecked != nil
        let syncedAt = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        lastUsage = .init(syncedAt: syncedAt, claude: windows(usage.claude), codex: windows(usage.codex),
                          proxyAccounts: keepChecked ? lastUsage?.proxyAccounts : accounts,
                          proxyChecked: keepChecked ? lastUsage?.proxyChecked : usage.proxyChecked,
                          proxyProblem: usage.proxyProblem, proxyRefreshing: proxyCheckPending(usage))
        refresh()
    }

    static func clear() {
        lastList = nil
        lastMac = ""
        lastUsage = nil
        if WidgetSnapshot.empty.save() { WidgetCenter.shared.reloadAllTimelines() }
    }

    static func update(_ list: Companion.ChatList?, macName: String) {
        guard let list else { return }
        lastList = list
        lastMac = macName
        refresh()
    }

    /// After you open a chat, so it leaves New replies on the widget too.
    static func refresh() {
        guard let list = lastList else { return }
        let chats = list.groups.flatMap(\.chats)
        func item(_ chat: Companion.ChatSummary, _ date: Date) -> WidgetSnapshot.Item {
            .init(chatID: chat.id, title: chat.title, detail: chat.subtitle, backend: chat.backend, date: date)
        }
        var seen = Set<UUID>()
        let waiting = chats.filter { $0.isWaitingOnYou && seen.insert($0.id).inserted }.map { item($0, $0.updatedAt) }
        let replies = MobileSeenReplies.shared.newest(in: list.activity ?? [], limit: 6).compactMap { reply in
            chats.first { $0.id == reply.chatID && !seen.contains($0.id) }.map { item($0, reply.endedAt) }
        }
        replies.forEach { seen.insert($0.chatID) }
        let working = chats.filter { $0.isRunning && seen.insert($0.id).inserted }.map { item($0, $0.updatedAt) }
        let snapshot = WidgetSnapshot(updatedAt: Date(), macName: lastMac, waiting: waiting, newReplies: replies, working: working, usage: lastUsage)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
