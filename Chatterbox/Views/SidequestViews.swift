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
                .frame(width: 36, height: 32).contentShape(Rectangle())
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
            Text("\(agent) gets a handoff with this session's brief and recent conversation, does the task in its own Sidechat, and its answer comes back here for \(from) to carry on from.")
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

/// Context stays inspectable after the one-shot provider handoff has been consumed.
struct ParentContextBanner: View {
    let context: ParentContext
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text("Context from \u{201C}\(context.sourceTitle)\u{201D}").lineLimit(1)
                Spacer(minLength: 8)
                Text("View handoff").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption)
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04))
        .accessibilityLabel("View context handoff from \(context.sourceTitle)")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Context handoff").font(.headline)
                    Spacer()
                    Button("Done") { showing = false }
                }
                Text("Saved at creation · recent conversation excerpt")
                    .font(.caption).foregroundStyle(.secondary)
                Text(context.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(context.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16).frame(width: 520, height: 440)
        }
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
                Button("Open Session") { model.selectedID = parent.id }
            }
            Button("End Sidequest") {
                if let parent { model.selectedID = parent.id }
                model.archive(session)
            }
            .disabled(session.isRunning)
            .help(session.isRunning ? "Stop it first, or wait for it to finish" : "Archive this sidequest; it moves to Archived")
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

/// A sidechat or sidequest inside its parent's card, with its relationship and live status.
struct ChildChatCardRow: View {
    let chat: ChatSession
    var scale: CGFloat = 1
    @Environment(AppModel.self) private var model
    private let appearance = ReaderStyleSettings()
    private var kind: String { chat.isSidequest ? "Sidequest" : "Sidechat" }
    private var title: String { chat.record.sidequestTask ?? chat.title }

    var body: some View {
        Button { model.selectedID = chat.id } label: {
            HStack(spacing: 5) {
                Image(systemName: chat.isSidequest ? "point.topleft.down.to.point.bottomright.curvepath" : "bubble.left.and.bubble.right")
                    .font(.system(size: 9 * scale)).foregroundStyle(.secondary)
                Image(chat.record.provider.iconName).resizable().scaledToFit()
                    .foregroundStyle(appearance.style.color(for: chat))
                    .frame(width: 10 * scale, height: 10 * scale)
                Text(title).font(.system(size: 10 * scale)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if chat.isWaitingOnYou {
                        Circle().fill(.yellow).frame(width: 6 * scale, height: 6 * scale)
                    } else if chat.isRunning {
                        ActivitySpinner(color: appearance.style.color(for: chat))
                    } else if chat.record.sidequestReturned != nil {
                        Image(systemName: "checkmark").font(.system(size: 8 * scale, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 10 * scale, height: 10 * scale)
            }
            .padding(.horizontal, 6 * scale).padding(.vertical, 3 * scale)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open \(kind)") { model.selectedID = chat.id }
            Button("End \(kind)") { model.archive(chat) }.disabled(chat.isRunning)
        }
        .help("\(kind) · \(chat.record.backend.label): \(title)"
              + (chat.isRunning ? " (working)" : chat.record.sidequestReturned != nil ? " (answer sent back)" : ""))
        .accessibilityLabel("Open \(kind.lowercased()): \(title)")
    }
}
