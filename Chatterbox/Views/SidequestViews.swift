import SwiftUI

/// Beside Notes: send a task to the other agent as a sidequest. Its answer comes back to this
/// chat by itself, and this chat's agent carries on from it.
struct SidequestButton: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var open = false
    @State private var task = ""
    private var other: Backend { session.record.backend == .claude ? .codex : .claude }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .help("Sidequest: send a task to \(other.label), and its answer comes back here")
        .accessibilityLabel("Sidequest to \(other.label)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SidequestForm(agent: other.label, from: session.record.backend.label, task: $task) {
                model.newSidequest(of: session, task: task)
                task = ""; open = false
            }
        }
    }
}

struct SidequestForm: View {
    let agent: String
    let from: String
    @Binding var task: String
    let start: () -> Void
    private var ready: Bool { !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sidequest to \(agent)").font(.headline)
            Text("\(agent) reads this chat, does the task in its own Sidechat, and its answer comes back here for \(from) to carry on from.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("What should \(agent) do?", text: $task, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...8)
                .onSubmit { if ready { start() } }
                .accessibilityLabel("Sidequest task")
            HStack {
                Spacer()
                Button("Start Sidequest", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Across the top of a sidequest: where its answer goes, and Send Back for later replies.
struct SidequestBanner: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let parent = session.record.sidequestOf.flatMap { id in model.sessions.first { $0.id == id } }
        let sentBack = session.record.sidequestReturned != nil
        HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            Text(sentBack ? "Sent back to \u{201C}\(parent?.title ?? "its chat")\u{201D}."
                 : "Sidequest from \u{201C}\(parent?.title ?? "another chat")\u{201D}. The answer goes back when \(session.record.backend.label) finishes.")
                .lineLimit(2)
            Spacer()
            if sentBack, !session.isRunning, session.unreturnedSidequestReply != nil {
                Button("Send Back") { model.returnSidequest(session) }
                    .help("Send the newest reply back to \u{201C}\(parent?.title ?? "its chat")\u{201D}")
            }
            if let parent {
                Button("Open Chat") { model.selectedID = parent.id }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }
}

/// Lets transcript rows open another chat (a sidequest, or where one came from).
struct OpenChatAction {
    var open: (UUID) -> Void = { _ in }
}

private struct OpenChatKey: EnvironmentKey {
    static let defaultValue = OpenChatAction()
}

extension EnvironmentValues {
    var openChat: OpenChatAction {
        get { self[OpenChatKey.self] }
        set { self[OpenChatKey.self] = newValue }
    }
}

/// In the bottom right of a chat: its sidequests, each a small chat window that shrinks to a
/// bubble, opens full size, or closes (the sidequest stays in the sidebar).
struct SidequestWindows: View {
    let parent: ChatSession
    var maxHeight: CGFloat = 560
    @Environment(AppModel.self) private var model
    @AppStorage("closedSidequestWindows") private var closed = ""
    /// The window you're typing in takes the keyboard's chat shortcuts.
    @State private var focused: UUID?

    private var quests: [ChatSession] {
        let shut = Set(closed.split(separator: ",").map(String.init))
        return model.sessions
            .filter { $0.record.sidequestOf == parent.id && $0.record.archivedAt == nil && !shut.contains($0.id.uuidString) }
            .sorted { $0.record.createdAt < $1.record.createdAt }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(quests) { quest in
                FloatingChat(session: quest, icon: "point.topleft.down.to.point.bottomright.curvepath",
                             storageKey: "sidequestWindowCollapsed-" + quest.id.uuidString,
                             label: "\(quest.record.backend.label) \u{00B7} Sidequest",
                             title: quest.record.sidequestTask,
                             height: min(560, maxHeight),
                             tile: CommandCenterTileContext(isActive: focused == quest.id, activate: { focused = quest.id }),
                             onClose: { close(quest) }) {
                    model.selectedID = quest.id
                }
            }
        }
    }

    private func close(_ quest: ChatSession) {
        var ids = closed.split(separator: ",").map(String.init)
        ids.append(quest.id.uuidString)
        closed = ids.suffix(200).joined(separator: ",")
    }
}
