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

/// At the top of the chat list, like the Mac sidebar's Activity: the three newest replies you
/// haven't opened on the phone, then every chat working now. Opening a reply marks it seen,
/// and the next unseen reply takes its place. Folds to its heading and counts.
struct MobileNewReplies: View {
    let activity: [Companion.TurnCompletion]
    /// Every chat on the Mac, for the working ones.
    var chats: [Companion.ChatSummary] = []
    let summary: (UUID) -> Companion.ChatSummary?
    let open: (Companion.ChatSummary) -> Void
    /// The heading's inset: a list's rounded row would clip it at the corners.
    var headingInset: CGFloat = 4
    @AppStorage("mobileActivityExpanded") private var expanded = true
    private var replies: [Companion.TurnCompletion] { MobileSeenReplies.shared.newest(in: activity, limit: 3) }
    private var working: [Companion.ChatSummary] { chats.filter { $0.isRunning && $0.isDot != true } }

    var body: some View {
        let replies = replies.filter { summary($0.chatID) != nil }
        let working = working
        if !replies.isEmpty || !working.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("ACTIVITY")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer()
                        if !replies.isEmpty { Text("\(replies.count) new").foregroundStyle(.blue) }
                        if !working.isEmpty { Text("\(working.count) working") }
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.horizontal, headingInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activity, \(replies.count) new replies, \(working.count) working")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    VStack(spacing: 0) {
                        ForEach(replies) { reply in
                            if let chat = summary(reply.chatID) {
                                Button { open(chat) } label: { row(chat, backend: reply.backend, date: reply.endedAt, running: false) }
                                    .buttonStyle(.plain)
                                if reply.id != replies.last?.id || !working.isEmpty { Divider().padding(.leading, 40) }
                            }
                        }
                        ForEach(working) { chat in
                            Button { open(chat) } label: { row(chat, backend: chat.backend, date: nil, running: true) }
                                .buttonStyle(.plain)
                            if chat.id != working.last?.id { Divider().padding(.leading, 40) }
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func row(_ chat: Companion.ChatSummary, backend: String, date: Date?, running: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if running { ProgressView().controlSize(.mini).tint(MobileConversationStyle.accent(for: backend)) }
                else { Circle().fill(.blue).frame(width: 8, height: 8) }
            }.frame(width: 10)
            Image((Backend(rawValue: backend) ?? .claude).iconName).resizable().scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(MobileConversationStyle.accent(for: backend))
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.worktreeBranch ?? chat.project ?? chat.title).font(.body.weight(.semibold)).lineLimit(1)
                if let subtitle = chat.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let date {
                Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 80, alignment: .trailing)
            } else {
                Text("Working").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityLabel("\(running ? "Working" : "New reply"): \(chat.title)")
    }
}
