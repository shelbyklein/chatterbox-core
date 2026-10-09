import AppKit
import SwiftUI

/// Chatterbox in the menu bar: an icon that shows when a chat waits on you or has a new
/// reply, and a panel listing them, the chats working now and recent ones. Click one to open
/// it in the main window. Settings → Behavior turns it off.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let waiting = model.activeSessions.contains { $0.isWaitingOnYou && !$0.isDot }
        let replies = !Attention.shared.finishedChats(in: model).isEmpty
        let working = !Attention.shared.workingChats(in: model).isEmpty
        Image(systemName: waiting ? "exclamationmark.bubble.fill"
              : replies ? "bubble.left.and.bubble.right.fill"
              : working ? "ellipsis.bubble" : "bubble.left.and.bubble.right")
            .accessibilityLabel(waiting ? "Chatterbox: a chat is waiting on you" : replies ? "Chatterbox: new replies" : working ? "Chatterbox: working" : "Chatterbox")
    }
}

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    private let appearance = ReaderStyleSettings()

    var body: some View {
        let waiting = model.activeSessions.filter { $0.isWaitingOnYou && !$0.isDot }
        let replies = Attention.shared.finishedChats(in: model).filter { !$0.isWaitingOnYou }
        let working = Attention.shared.workingChats(in: model).filter { !$0.isWaitingOnYou }
        let recent = Array(Attention.shared.recentChats(in: model).filter { !$0.isWaitingOnYou && !$0.items.isEmpty }.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Chatterbox").font(.headline)
                Spacer()
                Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New Chat")
            }
            if waiting.isEmpty && replies.isEmpty && working.isEmpty && recent.isEmpty {
                Label("All caught up", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            section("Waiting on you", waiting) { Circle().fill(.yellow).frame(width: 7, height: 7) }
            section("New replies", replies) { Circle().fill(.blue).frame(width: 7, height: 7) }
            section("Working", working) { session in
                ActivitySpinner(color: appearance.style.color(for: session.record.backend)).frame(width: 11, height: 11)
            }
            section("Recent", recent) { Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary) }
            Divider()
            HStack {
                Button("Open Chatterbox") { reveal() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private func section<Mark: View>(_ title: String, _ chats: [ChatSession], @ViewBuilder mark: @escaping (ChatSession) -> Mark) -> some View {
        if !chats.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(chats.prefix(8)) { session in
                    Button { open(session) } label: {
                        HStack(spacing: 8) {
                            mark(session).frame(width: 12)
                            Text(session.record.projectFolder != nil ? session.projectName : session.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.lastActionSummary ?? session.title)
                }
            }
        }
    }

    private func section<Mark: View>(_ title: String, _ chats: [ChatSession], @ViewBuilder mark: @escaping () -> Mark) -> some View {
        section(title, chats) { _ in mark() }
    }

    private func open(_ session: ChatSession) {
        model.showingSettings = false; model.showingHome = false; model.showingCommandCenter = false
        model.showingChatsSidebar = session.record.projectFolder == nil && session.record.studioID == nil
        model.selectedID = session.id
        Attention.shared.markSeen(session.id)
        reveal()
    }

    private func newChat() {
        model.newChat()
        reveal()
    }

    private func reveal() {
        dismiss()
        NSApp.activate()
        if let window = model.mainChatWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
