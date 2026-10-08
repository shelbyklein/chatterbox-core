import Observation
import SwiftUI

/// Which chats' replies you've seen on this phone: a chat's finished replies count as new until
/// you open it here. Starts caught up, so the first launch doesn't list old replies.
@MainActor
@Observable
final class MobileSeenReplies {
    static let shared = MobileSeenReplies()
    private let key = "mobileSeenReplies"
    private let baselineKey = "mobileSeenRepliesSince"
    private var seen: [String: Date]
    private let baseline: Date

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: baselineKey) as? Date { baseline = saved }
        else { baseline = Date(); defaults.set(baseline, forKey: baselineKey) }
        seen = (defaults.dictionary(forKey: key) as? [String: Date]) ?? [:]
    }

    func isNew(_ completion: Companion.TurnCompletion) -> Bool {
        completion.endedAt > max(baseline, seen[completion.chatID.uuidString] ?? .distantPast)
    }

    func markSeen(_ chat: UUID) {
        seen[chat.uuidString] = Date()
        // Keep the record small: chats seen in the last 30 days.
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        seen = seen.filter { $0.value > cutoff }
        UserDefaults.standard.set(seen, forKey: key)
        MobileWidgetSync.refresh()
    }

    /// The newest unseen reply of each chat, newest first.
    func newest(in activity: [Companion.TurnCompletion], limit: Int) -> [Companion.TurnCompletion] {
        var chats = Set<UUID>()
        return activity.sorted { $0.endedAt > $1.endedAt }
            .filter { isNew($0) && chats.insert($0.chatID).inserted }
            .prefix(limit).map { $0 }
    }
}

/// The three newest replies you haven't opened on the phone, at the top of the chat list.
/// Opening one marks it seen, and the next unseen reply takes its place.
struct MobileNewReplies: View {
    let activity: [Companion.TurnCompletion]
    let summary: (UUID) -> Companion.ChatSummary?
    let open: (Companion.ChatSummary) -> Void
    private var replies: [Companion.TurnCompletion] { MobileSeenReplies.shared.newest(in: activity, limit: 3) }

    var body: some View {
        let replies = replies.filter { summary($0.chatID) != nil }
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("New replies").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(replies) { reply in
                        if let chat = summary(reply.chatID) {
                            Button { open(chat) } label: { row(reply, chat) }
                                .buttonStyle(.plain)
                            if reply.id != replies.last?.id { Divider().padding(.leading, 40) }
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func row(_ reply: Companion.TurnCompletion, _ chat: Companion.ChatSummary) -> some View {
        HStack(spacing: 10) {
            Circle().fill(.blue).frame(width: 8, height: 8)
            Image((Backend(rawValue: reply.backend) ?? .claude).iconName).resizable().scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(MobileConversationStyle.accent(for: reply.backend))
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.body.weight(.semibold)).lineLimit(1)
                if let subtitle = chat.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(reply.endedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).frame(maxWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
