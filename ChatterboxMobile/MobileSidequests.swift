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

    /// A sidequest in a few words, for its popover: its title without "Sidequest · ", else the
    /// first sentence of its task, never the whole brief (Shelby, 2026-11-20).
    static func shortTitle(_ quest: Companion.ChatSummary) -> String {
        let title = quest.title.hasPrefix("Sidequest · ") ? String(quest.title.dropFirst("Sidequest · ".count)) : quest.title
        if !title.trimmingCharacters(in: .whitespaces).isEmpty, title != "New chat" { return title }
        let task = quest.sidequestTask ?? quest.title
        let sentence = task.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? task
        return sentence.count > 90 ? String(sentence.prefix(88)) + "\u{2026}" : sentence
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

/// A sidequest as a small icon: its agent, with a mark for its state (a spinner while it
/// works, yellow when it needs you, a check when done). Tapping shows its task, with Open.
struct MobileSidequestIcon: View {
    @Environment(MobileStore.self) private var store
    let quest: Companion.ChatSummary
    let open: () -> Void
    @State private var showing = false

    private var task: String { quest.sidequestTask ?? quest.title }
    private var agent: String { quest.backend == "codex" ? "Codex" : "Claude" }
    private var state: String { quest.isWaitingOnYou ? "Needs you" : quest.isRunning ? "Working" : "Finished" }

    var body: some View {
        Button { showing = true } label: {
            Image((Backend(rawValue: quest.backend) ?? .codex).iconName).resizable().scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(MobileConversationStyle.accent(for: quest.backend))
                .opacity(quest.isRunning || quest.isWaitingOnYou ? 1 : 0.6)
                .frame(width: 38, height: 32)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .overlay(alignment: .topTrailing) {
                    Group {
                        if quest.isWaitingOnYou { Circle().fill(.yellow).frame(width: 8, height: 8) }
                        else if quest.isRunning { ProgressView().controlSize(.mini).tint(MobileConversationStyle.accent(for: quest.backend)).scaleEffect(0.7) }
                        else { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    .offset(x: 2, y: -2)
                }
                .padding(.top, 3).padding(.trailing, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sidequest to \(agent): \(task)\(quest.isRunning ? ", working" : quest.isWaitingOnYou ? ", needs you" : "")")
        .accessibilityIdentifier("sidequest-icon-" + quest.id.uuidString)
        .accessibilityAction(named: "Open") { open() }
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(MobileSidequests.shortTitle(quest)).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(agent) · \(state)").font(.caption).foregroundStyle(.secondary)
                QuestBubbleActions(openID: "sidequest-open", confirmsDelete: true,
                    open: { showing = false; open() },
                    archive: { showing = false; Task { _ = try? await store.setArchived(true, chat: quest.id); await store.loadChats() } },
                    delete: { showing = false; Task { try? await store.deleteChat(quest.id); await store.loadChats() } })
            }
            .padding(14)
            .frame(width: 260)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A chat's sidequests as one scrolling row of icons.
struct MobileSidequestIcons: View {
    let quests: [Companion.ChatSummary]
    let open: (Companion.ChatSummary) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quests) { quest in MobileSidequestIcon(quest: quest) { open(quest) } }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
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
                if let parent { Button("Open Session") { open(parent) }.font(.caption.weight(.semibold)) }
                Button("End", role: .destructive, action: end).font(.caption.weight(.semibold))
                    .disabled(summary.isRunning)
                    .accessibilityLabel("End Sidequest")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        } else {
            let quests = MobileSidequests.of(summary.id, in: chats)
            if !quests.isEmpty {
                // One row of icons, however many there are; tap one for its task and Open.
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    MobileSidequestIcons(quests: quests, open: open)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidequest-strip")
            }
        }
    }
}

/// A sidequest bubble's actions, one row of icons: Open, Archive and Delete (Shelby,
/// 2026-11-20). Delete asks first unless the caller already does.
struct QuestBubbleActions: View {
    let openID: String
    var confirmsDelete = true
    let open: () -> Void
    let archive: () -> Void
    let delete: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                Image(systemName: "arrow.up.right").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Open")
            .accessibilityIdentifier(openID)
            Button(action: archive) {
                Image(systemName: "archivebox").frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Archive")
            .accessibilityIdentifier("quest-archive")
            Button(role: .destructive) { if confirmsDelete { confirming = true } else { delete() } } label: {
                Image(systemName: "trash").frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("quest-delete")
        }
        .font(.body.weight(.semibold))
        .confirmationDialog("Delete this sidequest?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        }
    }
}
