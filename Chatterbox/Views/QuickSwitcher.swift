import SwiftUI

/// ⌘K: type to find a chat or project (by name, title, tag, or agent) or run a common action.
/// ↑/↓ move, Return opens, Esc closes.
struct QuickSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused
    private let appearance = ReaderStyleSettings()

    private struct Action: Identifiable {
        var id: String { title }
        var title: String
        var systemImage: String
        var shortcut: String
        var perform: @MainActor () -> Void
    }

    private enum Entry: Identifiable {
        case chat(ChatSession)
        case pin(Pin)
        case action(Action)

        var id: String {
            switch self {
            case .chat(let session): session.id.uuidString
            case .pin(let pin): pin.id.uuidString
            case .action(let action): action.id
            }
        }
    }

    private var actions: [Action] {
        [
            Action(title: "New Chat", systemImage: "square.and.pencil", shortcut: "\u{2318}N") { model.newChat() },
            Action(title: "New Claude Chat", systemImage: "sparkle", shortcut: "\u{2325}\u{2318}N") { model.newChat(backend: .claude) },
            Action(title: "New Codex Chat", systemImage: "terminal", shortcut: "\u{21E7}\u{2318}N") { model.newChat(backend: .codex) },
            Action(title: "New Project\u{2026}", systemImage: "folder.badge.plus", shortcut: "\u{2303}\u{2318}N") { model.showingNewProject = true },
            Action(title: "Open Project\u{2026}", systemImage: "folder", shortcut: "\u{2318}O") { model.chooseAndOpenProject() },
            Action(title: "New Project from GitHub\u{2026}", systemImage: "arrow.down.circle", shortcut: "\u{21E7}\u{2318}O") { model.showingCloneFromGitHub = true },
            Action(title: "Settings\u{2026}", systemImage: "gearshape", shortcut: "\u{2318},") { model.showingSettings = true },
        ]
    }

    private var words: [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func matches(_ haystack: [String]) -> Bool {
        let text = haystack.joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }

    /// Open chats in sidebar order, then (while searching) archived ones, then actions.
    private var entries: [Entry] {
        let chats = words.isEmpty ? model.sidebarOrder : model.sidebarOrder + model.archivedSessions
        let found = chats.filter { session in
            matches([session.projectName, session.title, session.record.backend.label] + session.tags)
        }
        let pins = PinStore.shared.visiblePins(in: model.selectedPinPlace).filter { matches([$0.title, $0.target, $0.kind.label, "pin"]) }
        return found.map(Entry.chat) + pins.map(Entry.pin) + actions.filter { matches([$0.title]) }.map(Entry.action)
    }

    var body: some View {
        let entries = self.entries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats and projects, or pick an action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { move(-1, count: entries.count) }
                    .onKeyPress(.downArrow) { move(1, count: entries.count) }
                    .onKeyPress(.return) {
                        if entries.indices.contains(selection) { open(entries[selection]) }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        if entries.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(.top, 30)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Button { open(entry) } label: { row(entry, selected: index == selection) }
                                .buttonStyle(.plain)
                                .id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) {
                    if entries.indices.contains(selection) { proxy.scrollTo(entries[selection].id) }
                }
            }
        }
        .frame(width: 540, height: 420)
        .onAppear { searchFocused = true }
    }

    private func move(_ offset: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selection = (selection + offset + count) % count
        return .handled
    }

    private func open(_ entry: Entry) {
        dismiss()
        switch entry {
        case .chat(let session):
            model.selectedID = session.id
        case .pin(let pin):
            PinStore.shared.open(pin)
        case .action(let action):
            // Let the sheet close first: some actions open a panel or another sheet.
            DispatchQueue.main.async { action.perform() }
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch entry {
            case .chat(let session):
                Group {
                    if session.isDot { Image(systemName:"sparkles").frame(width:16,height:16) }
                    else { Image(session.record.backend.iconName).resizable().scaledToFit().frame(width: 16, height: 16) }
                }
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityLabel(session.record.backend.label)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.record.projectFolder != nil ? session.projectName : session.title).lineLimit(1)
                        if session.record.archivedAt != nil {
                            Text("Archived").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if session.record.projectFolder != nil,
                       let summary = session.lastActionSummary ?? (session.title != "New chat" ? session.title : nil) {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !session.tags.isEmpty {
                    TagPills(tags: session.tags).fixedSize()
                }
                Text(session.record.backend.label).font(.caption).foregroundStyle(.secondary)
            case .pin(let pin):
                PinIcon(pin: pin).frame(width: 18, height: 18)
                Text(pin.title).lineLimit(1)
                Spacer(minLength: 8)
                Text("Pin \u{00B7} \(pin.kind.label)").font(.caption).foregroundStyle(.secondary)
            case .action(let action):
                Image(systemName: action.systemImage).foregroundStyle(.secondary).frame(width: 18)
                Text(action.title)
                Spacer(minLength: 8)
                Text(action.shortcut).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.highlight.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}
