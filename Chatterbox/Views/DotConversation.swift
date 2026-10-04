#if GOLEM_APP
import SwiftUI

/// Dot's chat as a conversation: your messages on the right, its replies in bubbles on the
/// left, and the steps behind each reply (tools, notes) folded under it. Check-ins and other
/// notes from Chatterbox are small centered labels; email alerts are cards.
struct DotConversation: View {
    let session: ChatSession
    @State private var openSteps: Set<UUID> = []
    /// Only the newest rows are drawn, so a long history stays quick.
    @State private var shown: Int
    let showsInlineAvatar: Bool

    init(session: ChatSession, initialRows: Int = 80, showsInlineAvatar: Bool = true) {
        self.session = session
        self.showsInlineAvatar = showsInlineAvatar
        _shown = State(initialValue: max(1, initialRows))
    }
    @Environment(\.readerStyle) private var style
    @Environment(\.chatFolder) private var chatFolder
    @Environment(AppModel.self) private var model

    private enum Row: Identifiable {
        case mine(DisplayItem)
        case label(DisplayItem)
        /// A reply, the steps behind it, and the chats it's about (to jump to).
        case reply(DisplayItem, steps: [DisplayItem], context: String)
        case steps(UUID, [DisplayItem])
        case email(DisplayItem)
        case other(DisplayItem)

        var id: UUID {
            switch self {
            case .mine(let item), .label(let item), .reply(let item, _, _), .email(let item), .other(let item): item.id
            case .steps(let id, _): id
            }
        }
    }

    /// Groups the transcript into conversation rows; steps still under way stay with the
    /// working bubble instead.
    private var rows: (rows: [Row], working: [DisplayItem]) {
        var rows: [Row] = []
        var steps: [DisplayItem] = []
        let liveNotes = session.liveCommentaryIDs
        // The message that started this turn: Chatterbox's notes name the chats they're about.
        var prompt = ""
        func flushSteps() {
            if let first = steps.first { rows.append(.steps(first.id, steps)) }
            steps = []
        }
        for item in session.items {
            switch item.kind {
            case .user:
                flushSteps()
                prompt = item.text
                rows.append(item.automatic == true ? .label(item) : .mine(item))
            case .assistant where item.phase != .commentary:
                guard !item.text.isEmpty else { continue }
                rows.append(.reply(item, steps: steps, context: prompt + "\n" + item.text))
                steps = []
            case .assistant where liveNotes.contains(item.id):
                flushSteps()
                rows.append(.other(item))
            case .assistant, .tool, .thought, .plan:
                steps.append(item)
            case .notice:
                rows.append(item.text.hasPrefix("Email for you") ? .email(item) : .label(item))
            default:
                rows.append(.other(item))
            }
        }
        if session.isRunning { return (rows, steps) }
        flushSteps()
        return (rows, [])
    }

    var body: some View {
        let grouped = rows
        let lastReply = grouped.rows.last { if case .reply = $0 { return true }; return false }?.id
        VStack(alignment: .leading, spacing: 10) {
            if grouped.rows.count > shown {
                Button { shown += 80 } label: {
                    Label("Show earlier", systemImage: "arrow.up.circle").font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            ForEach(grouped.rows.suffix(shown)) { row in
                // Golem sits beside his latest reply (or the typing bubble while he works).
                if case .reply = row, showsInlineAvatar, GolemAvatar.shared.hasAnimations {
                    HStack(alignment: .bottom, spacing: 8) {
                        avatarColumn(show: row.id == lastReply && !session.isRunning)
                        view(for: row)
                    }
                    .id(row.id)
                } else {
                    view(for: row).id(row.id)
                }
            }
            if session.isRunning {
                HStack(alignment: .bottom, spacing: 8) {
                    if showsInlineAvatar, GolemAvatar.shared.hasAnimations { avatarColumn(show: true) }
                    working(grouped.working)
                }
            }
        }
    }

    /// Room for Golem beside a reply; only the newest shows him, as a conversation would.
    @ViewBuilder
    private func avatarColumn(show: Bool) -> some View {
        if show {
            GolemAnimated(mood: GolemAvatar.mood(of: session))
                .frame(width: 56, height: 56)
                .padding(.bottom, -6)
        } else {
            Color.clear.frame(width: 56, height: 1)
        }
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row {
        case .mine(let item):
            ItemView(item: item, agent: session.record.backend, onSendNow: session.sendQueuedNow)
        case .label(let item):
            Text(item.kind == .user ? (item.detail ?? "Check-in") : item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
                .frame(maxWidth: .infinity)
                .help(item.kind == .user ? item.text : "")
        case .reply(let item, let steps, let context):
            let chats = chatIDs(in: context)
            VStack(alignment: .leading, spacing: 4) {
                bubble(item)
                if !chats.isEmpty {
                    HStack(spacing: 6) { chatShortcuts(chats) }
                        .padding(.leading, 10)
                }
                if !steps.isEmpty { stepsToggle(item.id, steps) }
            }
        case .steps(let id, let steps):
            stepsToggle(id, steps)
        case .email(let item):
            HStack(alignment: .top, spacing: 9) {
                Image("Gmail").resizable().scaledToFit().frame(width: 20, height: 20).accessibilityLabel("Gmail")
                Text(item.text.replacingOccurrences(of: "Email for you \u{00B7} ", with: ""))
                    .font(style.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.highlight.opacity(0.4)))
            .padding(.trailing, 80)
        case .other(let item):
            ItemView(item: item, agent: session.record.backend,
                     onApproval: session.resolveApproval, onAnswer: session.answerQuestions)
        }
    }

    /// Chat ids ("[UUID]") in a note or reply, for chats that still exist, in order.
    private static let chatIDPattern = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    private func chatIDs(in text: String) -> [UUID] {
        guard let regex = Self.chatIDPattern else { return [] }
        let ns = text as NSString
        var ids: [UUID] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let id = UUID(uuidString: ns.substring(with: match.range)), !ids.contains(id), id != session.id,
                  model.sessions.contains(where: { $0.id == id }) else { continue }
            ids.append(id)
        }
        return ids
    }

    /// "↗ SDHQ": opens that chat, to follow up there.
    @ViewBuilder
    private func chatShortcuts(_ ids: [UUID]) -> some View {
        ForEach(ids, id: \.self) { id in
            if let chat = model.sessions.first(where: { $0.id == id }) {
                let name = chat.record.projectFolder != nil ? chat.projectName : chat.title
                Button {
                    if chat.record.archivedAt != nil { model.unarchive(chat) }
                    model.selectedID = id
                    if model.showingDot { model.dotMiniWindow?.revealMainWindow() }
                } label: {
                    Label(name, systemImage: "arrow.up.right")
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open \u{201C}\(name)\u{201D}")
            }
        }
    }

    /// One of Dot's replies, in a bubble on the left.
    private func bubble(_ item: DisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: item.text)
            if item.phase == .final {
                ForEach(ChatSession.referencedMedia(in: item.text, folder: chatFolder), id: \.self) { url in
                    if let kind = MediaKind.of(url) { MediaPreview(url: url, kind: kind).frame(maxWidth: 480, alignment: .leading) }
                }
                ReplyImages(urls: ChatSession.referencedImages(in: item.text, folder: chatFolder))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.55)))
        .contextMenu {
            Button("Copy Message") { MessageClipboard.copy(item.text) }
            Button("Copy as Plain Text") { MessageClipboard.copy(MessageClipboard.plain(item.text)) }
        }
        .padding(.trailing, 60)
    }

    /// "3 steps", opening to show what Dot did behind a reply.
    private func stepsToggle(_ id: UUID, _ steps: [DisplayItem]) -> some View {
        let open = openSteps.contains(id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if open { openSteps.remove(id) } else { openSteps.insert(id) }
            } label: {
                Label(steps.count == 1 ? "1 step" : "\(steps.count) steps", systemImage: open ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { ItemView(item: $0, agent: session.record.backend) }
                }
                .padding(.leading, 14)
            }
        }
    }

    /// The typing bubble while Dot works, with what it's doing right now.
    private func working(_ steps: [DisplayItem]) -> some View {
        HStack(spacing: 8) {
            TypingIndicator()
            if let step = steps.last(where: { $0.kind == .tool || $0.kind == .assistant }) {
                Text(ContentView.plainPreview(step.text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.55)))
    }
}

#endif
