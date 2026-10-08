import Foundation
import WidgetKit

/// Keeps the widget's snapshot current: what's waiting on you, new replies (the same ones as
/// New replies at the top of the list) and what's working now.
@MainActor
enum MobileWidgetSync {
    private static var lastList: Companion.ChatList?
    private static var lastMac = ""

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
        let snapshot = WidgetSnapshot(updatedAt: Date(), macName: lastMac, waiting: waiting, newReplies: replies, working: working)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
