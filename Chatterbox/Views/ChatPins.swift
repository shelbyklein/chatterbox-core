import AppKit
import SwiftUI

/// A message pinned to the top of its chat. The text is a copy, so the pin reads the same
/// even when the message is far back and not drawn.
struct PinnedMessage: Codable, Identifiable, Equatable {
    /// The transcript item's id.
    var id: UUID
    var text: String
    var fromUser: Bool
    var pinnedAt = Date()
}

/// Pinned messages per chat, kept in this Mac's preferences.
@MainActor @Observable final class PinnedMessagesStore {
    static let shared = PinnedMessagesStore()
    private let defaults: UserDefaults
    private let key = "macPinnedMessages"
    private(set) var pins: [String: [PinnedMessage]]
    /// The panel's open state, shared by every chat.
    var expanded: Bool { didSet { defaults.set(!expanded, forKey: "macPinnedMessagesCollapsed") } }

    init(defaults: UserDefaults = AppPreferences.defaults) {
        self.defaults = defaults
        pins = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: [PinnedMessage]].self, from: $0) } ?? [:]
        expanded = !defaults.bool(forKey: "macPinnedMessagesCollapsed")
    }

    func pins(for chat: UUID) -> [PinnedMessage] { pins[chat.uuidString] ?? [] }
    func isPinned(_ item: UUID, in chat: UUID) -> Bool { pins(for: chat).contains { $0.id == item } }

    /// Pins the message (newest pin first), or unpins it if it's already pinned.
    func toggle(_ item: DisplayItem, in chat: UUID) {
        let key = chat.uuidString
        if isPinned(item.id, in: chat) {
            pins[key]?.removeAll { $0.id == item.id }
            if pins[key]?.isEmpty == true { pins[key] = nil }
        } else {
            pins[key, default: []].insert(PinnedMessage(id: item.id, text: item.text, fromUser: item.kind == .user), at: 0)
            expanded = true
        }
        save()
    }

    func remove(_ item: UUID, in chat: UUID) {
        pins[chat.uuidString]?.removeAll { $0.id == item }
        if pins[chat.uuidString]?.isEmpty == true { pins[chat.uuidString] = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: key) }
    }
}

/// Lets a message offer Pin in chats that show the pins panel (the chat view, not tiles).
struct PinMessageAction {
    var chat: UUID?
    var jump: (UUID) -> Void = { _ in }
}

private struct PinMessageKey: EnvironmentKey {
    static let defaultValue = PinMessageAction()
}

extension EnvironmentValues {
    var pinMessage: PinMessageAction {
        get { self[PinMessageKey.self] }
        set { self[PinMessageKey.self] = newValue }
    }
}

/// "Pin" / "Unpin" for a message's context menu; nothing where pins aren't shown.
struct PinMenuItem: View {
    let item: DisplayItem
    @Environment(\.pinMessage) private var action
    var body: some View {
        if let chat = action.chat {
            let pinned = PinnedMessagesStore.shared.isPinned(item.id, in: chat)
            Button(pinned ? "Unpin" : "Pin to Top") { PinnedMessagesStore.shared.toggle(item, in: chat) }
        }
    }
}

/// "Pin" under a reply, beside Copy.
struct PinMessageButton: View {
    let item: DisplayItem
    @Environment(\.pinMessage) private var action
    var body: some View {
        if let chat = action.chat {
            let pinned = PinnedMessagesStore.shared.isPinned(item.id, in: chat)
            Button { PinnedMessagesStore.shared.toggle(item, in: chat) } label: {
                Label(pinned ? "Pinned" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin this reply" : "Pin this reply to the top of the chat")
        }
    }
}

/// The chat's pinned messages, down the top right; folds to a pin and a count, like the notes
/// on the left. Click a pin to go to its message. Hidden while nothing is pinned.
struct ChatPins: View {
    let chat: UUID
    var agentName: String
    var panelWidth: CGFloat = 280
    var store = PinnedMessagesStore.shared
    let jump: (UUID) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let entries = store.pins(for: chat)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { store.expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pin")
                        if store.expanded { Text("Pinned").font(.headline) }
                        else { Text("\(entries.count)").font(.caption.monospacedDigit()) }
                        if store.expanded { Spacer(); Image(systemName: "chevron.up").font(.caption) }
                    }
                    .padding(store.expanded ? 0 : 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(store.expanded ? "Collapse pinned messages" : "Show pinned messages")
                .accessibilityLabel(store.expanded ? "Collapse pinned messages" : "Show \(entries.count) pinned messages")
                if store.expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { pin in row(pin) }
                        }
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(store.expanded ? 14 : 0)
            .frame(width: store.expanded ? panelWidth : nil, alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ pin: PinnedMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { jump(pin.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pin.fromUser ? "You" : agentName).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(MessageClipboard.plain(pin.text).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to this message")
            HStack {
                Text(pin.pinnedAt, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { MessageClipboard.copy(pin.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy message")
                Button { store.remove(pin.id, in: chat) } label: { Image(systemName: "pin.slash") }.help("Unpin")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button("Go to Message") { jump(pin.id) }
            Button("Copy Message") { MessageClipboard.copy(pin.text) }
            Button("Unpin") { store.remove(pin.id, in: chat) }
        }
    }
}
