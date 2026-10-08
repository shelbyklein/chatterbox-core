#if GOLEM_APP
import SwiftUI

/// "What Golem can do": every capability, how to use it, and (for the ones with a setting)
/// whether it's on. Opened from Golem's top-left menu and from Settings.
struct GolemCapabilitiesView: View {
    @Environment(MobileStore.self) private var store
    @AppStorage(GolemQuickPrompts.key) private var quickPromptData = Data()
    /// The Mac's automation settings; nil until loaded (or if the Mac can't be reached).
    @State private var automation: [String: Bool]?

    private struct Item: Identifiable {
        var id: String { title }
        let icon: String, title: String, how: String
        var on: Bool? = nil
    }

    private func on(_ key: String) -> Bool? { automation.map { $0[key] ?? true } }

    private var sections: [(String, [Item])] {
        let prompts = GolemQuickPrompts.decode(quickPromptData).count
        return [
            ("Talk", [
                Item(icon: "waveform", title: "Conversation",
                     how: "Tap the waveform button by the message box, then speak. Pause to send; he answers out loud and listens for your turn. Stay quiet or tap stop to end."),
                Item(icon: "speaker.wave.2", title: "Read replies aloud",
                     how: "He reads each new reply while his conversation is open. Settings → Voice.", on: GolemVoice.shared.autoRead),
                Item(icon: "hand.raised", title: "He finishes what he's saying",
                     how: "Talking over him doesn't cut him off; tap stop or mute to stop him."),
                Item(icon: "mic.badge.plus", title: "Siri and Shortcuts",
                     how: "Say “Talk to Golem” to start a conversation, or “End conversation with Golem”. Both are actions in the Shortcuts app."),
            ]),
            ("Ask", [
                Item(icon: "list.bullet", title: "Quick prompts",
                     how: "Tap Golem at the top left to send one (\(prompts) set up). Add, edit or reorder them in Settings → Quick Prompts."),
                Item(icon: "clock.arrow.circlepath", title: "Catch me up",
                     how: "A quick prompt for what changed in your chats and email over the last hour, most urgent first."),
                Item(icon: "cpu", title: "Choose his model",
                     how: "The pill at the top of his conversation shows the model he's on; tap it (or the gear) to switch between Claude and Codex."),
            ]),
            ("Notes", [
                Item(icon: "note.text", title: "Quick notes",
                     how: "Say or type “note: …”. He confirms with “Noted:” and it appears in the Notes tab. Ask “what are my notes?” to hear them; swipe one away to delete it."),
            ]),
            ("Journal", [
                Item(icon: "book", title: "Journal",
                     how: "His briefings, decisions and notes, filed by Projects, Studios, Chats and Golem. Open in Chatterbox jumps to the chat."),
            ]),
            ("Email", [
                Item(icon: "envelope.badge", title: "Important email alerts",
                     how: "He watches your Gmail accounts and notifies you once about mail that matters. He never sends, archives or marks mail read.", on: on("dotEmailWatch")),
                Item(icon: "envelope.open", title: "Ask about email",
                     how: "Ask him to find or summarize mail. This needs him on Codex, which has your Gmail connections."),
            ]),
            ("Your Chatterbox chats", [
                Item(icon: "bubble.left.and.bubble.right", title: "Run your chats",
                     how: "Ask him what a chat is doing, to tell a chat what to do next, or to start or stop one. He reads the chat before acting on it."),
                Item(icon: "calendar.badge.clock", title: "Scheduled check-ins",
                     how: "Briefings at set times on weekdays. Settings → Automation on your Mac.", on: on("dotCheckIns")),
                Item(icon: "exclamationmark.bubble", title: "When a chat needs you",
                     how: "He tells you when a chat is waiting on your answer or approval.", on: on("dotWatchWaiting")),
                Item(icon: "checkmark.bubble", title: "When a chat finishes",
                     how: "He summarizes what a chat did once it's done.", on: on("dotSummarizeFinished")),
            ]),
            ("Home Screen and iPhone", [
                Item(icon: "square.grid.2x2", title: "Golem widget",
                     how: "Small: tap Golem to dictate one message. Medium and large add your quick prompts. Long-press the Home Screen → Edit → Add Widget → Golem."),
                Item(icon: "iphone", title: "Stays awake",
                     how: "While Golem is open on screen, your iPhone doesn't auto-lock."),
                Item(icon: "bell.badge", title: "Notifications",
                     how: "His alerts and replies arrive as notifications. Settings → Notifications."),
            ]),
        ]
    }

    var body: some View {
        List {
            ForEach(sections, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon).font(.body).foregroundStyle(.tint)
                                .frame(width: 26).padding(.top, 2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.title).font(.headline)
                                    Spacer(minLength: 8)
                                    if let on = item.on {
                                        Text(on ? "On" : "Off").font(.caption.weight(.semibold))
                                            .foregroundStyle(on ? .green : .secondary)
                                    }
                                }
                                Text(item.how).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if automation == nil {
                Section { Text("Connect to your Mac to see which automations are on.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("What Golem Can Do")
        .task { automation = try? await store.golemPreferences() }
    }
}
#endif
