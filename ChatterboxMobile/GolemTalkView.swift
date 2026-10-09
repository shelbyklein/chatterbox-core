#if GOLEM_APP
import SwiftUI

/// The Talk tab: talking with Golem, no typing. Hold the big button and speak; your words show
/// above it as you talk, and they're sent when you let go. His replies stack up above and are read
/// aloud, each whole and in order. It's the same conversation as the Golem tab.
struct GolemTalkView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: MobileChatHistory?
    @State private var dictation = Dictation()
    /// The button is down.
    @State private var holding = false
    /// The microphone is on (between presses too, until a minute goes by unused).
    @State private var warm = false
    @State private var starting = false
    @State private var live = ""
    @State private var sending = false
    @State private var problem: String?
    @State private var idle: Task<Void, Never>?
    /// His messages already accounted for (here when the tab opened, or being read), and the ones
    /// being read aloud now.
    @State private var known: Set<UUID>?
    @State private var reading: [UUID] = []
    @AppStorage("golemTalkMuted") private var muted = false

    private var golem: Companion.ChatSummary? { store.chatList?.groups.first { $0.kind == .dot }?.chats.first }
    private var detail: Companion.ChatDetail? { history?.detail }
    private var running: Bool { detail?.summary.isRunning ?? false }
    /// Your messages and his, newest last.
    private var exchange: [Companion.Item] {
        Array((detail?.items ?? []).filter { ($0.kind == .user || $0.kind == .assistant) && !$0.text.isEmpty }.suffix(40))
    }
    private var messages: [Companion.Item] { (detail?.items ?? []).filter { $0.kind == .assistant && !$0.text.isEmpty } }
    private var followKey: String {
        messages.suffix(6).map { "\($0.id)\($0.text.count)\($0.isStreaming)" }.joined(separator: "|") + "|\(running)|\(holding)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                VStack(spacing: 14) {
                    liveWords
                    talkButton
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle("Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { muted.toggle(); if muted { GolemVoice.shared.stop() } } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(muted ? "Unmute Golem" : "Mute Golem")
                }
            }
        }
        .onChange(of: golem?.id) { attach() }
        .onChange(of: followKey) { follow() }
        .onChange(of: running) { _, now in if now, warm { GolemCues.play(.thinking) } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { endTalking(); return }
            while !Task.isCancelled {
                if store.chatList == nil { await store.loadChats() }
                attach()
                if let history { await history.refresh(in: store).value }
                do { try await Task.sleep(for: .seconds(running || !reading.isEmpty ? 1 : 3)) } catch { return }
            }
        }
        .onDisappear { endTalking() }
    }

    // MARK: - The conversation

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if detail == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if exchange.isEmpty {
                        Text("Hold the button and talk to Golem.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(exchange) { item in row(item).id(item.id) }
                    if running {
                        Text("•••").font(.title2.bold()).foregroundStyle(.secondary)
                            .accessibilityLabel("Golem is thinking")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: "\(exchange.last?.id.uuidString ?? "")|\(exchange.last?.text.count ?? 0)|\(running)") {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func row(_ item: Companion.Item) -> some View {
        if item.kind == .user {
            Text(item.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        } else {
            MarkdownText(text: item.text)
                .font(item.isCommentary ? .callout : .title3)
                .foregroundStyle(item.isCommentary ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
        }
    }

    // MARK: - Talking

    private var liveWords: some View {
        Group {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if !live.isEmpty {
                Text(live).foregroundStyle(.primary)
            } else if holding {
                Text(starting ? "Starting the microphone…" : "Listening…").foregroundStyle(.secondary)
            } else if sending {
                Text("Sending…").foregroundStyle(.secondary)
            } else {
                Text(running ? "Golem is thinking. Hold to add something." : "Hold to talk, let go to send.").foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .multilineTextAlignment(.center)
        .lineLimit(5)
        .frame(maxWidth: .infinity, minHeight: 44)
        .animation(.easeOut(duration: 0.15), value: live)
    }

    private var talkButton: some View {
        Image(systemName: holding ? "mic.fill" : "waveform")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(holding ? Color.white : Color.primary)
            .frame(width: 96, height: 96)
            .background(holding ? Color.red : Color(uiColor: .secondarySystemBackground), in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(holding ? 0 : 0.12), lineWidth: 1))
            .shadow(color: .black.opacity(holding ? 0.25 : 0.1), radius: holding ? 14 : 6, y: 3)
            .scaleEffect(holding ? 1.1 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: holding)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 200, perform: {}) { down in
                if down { press() } else { release() }
            }
            .opacity(golem == nil || detail == nil ? 0.4 : 1)
            .allowsHitTesting(golem != nil && detail != nil)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(holding ? "Listening. Activate again to send." : "Hold to talk")
            .accessibilityAction { if holding { release() } else { press() } }
            .accessibilityIdentifier("golem-talk-button")
    }

    /// Button down: he stops talking (you're taking your turn) and the microphone records.
    private func press() {
        guard !holding else { return }
        holding = true
        problem = nil
        live = ""
        idle?.cancel()
        GolemVoice.shared.stop()
        reading = []
        if warm {
            dictation.beginHold()
            GolemCues.play(.listening)
            return
        }
        guard !starting else { return }
        starting = true
        Task {
            let started = await dictation.startConversation(giveUp: 30, holding: true, onSpeechDetected: {}, onUtterance: { spoken in
                heard(spoken)
            }, onText: { spoken in
                live = spoken
            })
            starting = false
            guard started else { problem = dictation.problem ?? "The microphone didn't start."; holding = false; return }
            warm = true
            // Let go while it was starting: nothing was said.
            if holding { GolemCues.play(.listening) } else { dictation.endHold(grace: 0) }
        }
    }

    /// Button up: what you said is sent (after a moment for your last words).
    private func release() {
        guard holding else { return }
        holding = false
        if warm { dictation.endHold() }
    }

    private func heard(_ spoken: String) {
        armIdle()
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let golem else { live = ""; return }
        sending = true
        Task {
            defer { sending = false }
            do {
                let result = try await store.send(text, to: golem.id)
                history?.apply(result)
                live = ""
                GolemCues.play(.sent)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// A minute unused (and he isn't talking or thinking): the microphone switches off.
    private func armIdle() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, !holding else { return }
            if GolemVoice.shared.speakingID != nil || running { armIdle(); return }
            dictation.stop()
            warm = false
        }
    }

    private func endTalking() {
        idle?.cancel()
        if holding || warm { dictation.stop() }
        holding = false
        warm = false
        starting = false
    }

    // MARK: - Reading his replies

    private func attach() {
        guard let golem, history?.id != golem.id else { return }
        history?.cancel()
        let fresh = MobileChatHistory(id: golem.id)
        history = fresh
        known = nil
        fresh.refresh(in: store, force: true)
    }

    /// Each new message is read aloud whole and in order (GolemVoice queues them); ones already
    /// here when the tab opened stay quiet. While you hold the button, he waits.
    private func follow() {
        guard scenePhase == .active, let history, !history.isCached, history.detail != nil else { return }
        let all = messages
        guard var seen = known else { known = Set(all.map(\.id)); return }
        for message in all where !seen.contains(message.id) {
            seen.insert(message.id)
            if !muted { reading.append(message.id) }
        }
        known = seen
        guard !holding, !muted else { return }
        for id in reading {
            guard let message = all.first(where: { $0.id == id }) else { continue }
            GolemVoice.shared.update(reply: id, text: message.text, final: !message.isStreaming || !running) {
                reading = []
                if warm { armIdle() }
            }
        }
    }
}
#endif
