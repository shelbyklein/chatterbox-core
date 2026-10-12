import SwiftUI

/// Sidequests on the phone: a chat hands a task to the other agent (Claude ↔ Codex); the
/// answer comes back to the chat by itself and the sidequest archives itself. They're
/// listed with the chat that started them, never as chats of their own.
extension Companion.ChatSummary {
    var isSidequest: Bool { sidequestOf != nil }
    var otherAgentLabel: String { backend == "codex" ? "Claude" : "Codex" }
}

enum MobileSidequests {
    /// The open sidequests a chat started, oldest first.
    static func of(_ chat: UUID, in chats: [Companion.ChatSummary]) -> [Companion.ChatSummary] {
        chats.filter { $0.sidequestOf == chat }.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// A sidequest listed with its chat, so not on its own.
    static func listedWithParent(_ chat: Companion.ChatSummary, in chats: [Companion.ChatSummary]) -> Bool {
        guard let parent = chat.sidequestOf else { return false }
        return chats.contains { $0.id == parent }
    }

    /// "Codex is working on: Render four options" in a card's or row's own words.
    static func line(_ quests: [Companion.ChatSummary]) -> String? {
        guard let first = quests.first else { return nil }
        let agent = first.backend == "codex" ? "Codex" : "Claude"
        let task = first.sidequestTask ?? first.title
        let more = quests.count > 1 ? " +\(quests.count - 1)" : ""
        return (first.isWaitingOnYou ? "\(agent) needs you: " : first.isRunning ? "\(agent): " : "\(agent) finished: ") + task + more
    }
}

/// One sidequest as a compact, tappable row: its status, agent and task.
struct MobileSidequestRow: View {
    let quest: Companion.ChatSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Group {
                    if quest.isWaitingOnYou { Circle().fill(.yellow).frame(width: 7, height: 7) }
                    else if quest.isRunning { ProgressView().controlSize(.mini).tint(MobileConversationStyle.accent(for: quest.backend)) }
                    else { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                }
                .frame(width: 14)
                Image((Backend(rawValue: quest.backend) ?? .codex).iconName).resizable().scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(MobileConversationStyle.accent(for: quest.backend))
                Text(quest.sidequestTask ?? quest.title).font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sidequest to \(quest.backend == "codex" ? "Codex" : "Claude"): \(quest.sidequestTask ?? quest.title)\(quest.isRunning ? ", working" : quest.isWaitingOnYou ? ", needs you" : "")")
    }
}

/// Above a chat's transcript: the sidequests it started; inside a sidequest, where it reports.
struct MobileSidequestStrip: View {
    let summary: Companion.ChatSummary
    let chats: [Companion.ChatSummary]
    let open: (Companion.ChatSummary) -> Void
    let end: () -> Void

    var body: some View {
        if summary.isSidequest {
            let parent = chats.first { $0.id == summary.sidequestOf }
            HStack(spacing: 8) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                Text(summary.sidequestReturned == true ? "Reported back to \u{201C}\(parent?.title ?? "its chat")\u{201D}."
                     : "Sidequest from \u{201C}\(parent?.title ?? "another chat")\u{201D}. The answer goes back when it finishes.")
                    .font(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let parent { Button("Open Chat") { open(parent) }.font(.caption.weight(.semibold)) }
                Button("End", role: .destructive, action: end).font(.caption.weight(.semibold))
                    .disabled(summary.isRunning)
                    .accessibilityLabel("End Sidequest")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        } else {
            let quests = MobileSidequests.of(summary.id, in: chats)
            if !quests.isEmpty {
                VStack(spacing: 6) {
                    ForEach(quests) { quest in MobileSidequestRow(quest: quest) { open(quest) } }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}
