import PhotosUI
import SwiftUI

/// An image waiting to go with the next message: a sketch, or a photo from the library.
struct PendingImage: Identifiable {
    let id = UUID()
    var preview: UIImage
    var upload: Companion.Upload
}

/// Invalidates queued scroll work when the reader drags or a newer follow request replaces it.
/// Reference-typed so every drag update doesn't redraw the chat.
final class ScrollWork {
    var generation = 0
    var request = 0
    var dragging = false
    var towardNewest = false
}

/// Reports whether the visible part of a scroll view is within a couple of lines of its end,
/// measured from the scroll geometry (iOS 18 and later).
private struct NearBottom: ViewModifier {
    var report: (Bool) -> Void
    var settled: (Bool) -> Void
    @available(iOS 18, *)
    private func nearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY < 40
    }
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { nearBottom($0) } action: { _, near in
                report(near)
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .idle { settled(nearBottom(context.geometry)) }
            }
        } else {
            content
        }
    }
}

/// Bottom alignment is useful on opening and for short chats. Applying it to every size change
/// also shifts a reader upward when a new row is appended below them; following is explicit.
private struct TranscriptAnchors: ViewModifier {
    var following: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.top, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(following ? .bottom : .top)
        }
    }
}

/// One chat: its transcript, kept current while it's open, and a message box.
struct ChatDetailView: View {
    let chat: Companion.ChatSummary
    /// Opens another chat (a fork) in this one's place.
    var open: (Companion.ChatSummary) -> Void = { _ in }
    let history: MobileChatHistory
    /// Archiving closes the chat: the list stays as it was, with nothing open beside it.
    var closeChat: () -> Void = {}
    /// On the iPhone's Golem tab: false shows him large and centered with no message box,
    /// true tucks him into his spot under the last message and brings the box back.
    var golemComposing: Binding<Bool>? = nil
    @Environment(MobileStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var golemSpace
    /// Next Steps suggestions you closed on this device, until new ones arrive.
    @State private var dismissedSteps: [String]?
    /// The Next Steps set you opened; a new set arrives folded to one line.
    @State private var expandedSteps: [String]?
    @State private var confirmingRestart = false
    @State private var promoting: ChatPromotionTarget?
    @State private var controllingSession = false
    @State private var sessionControlStatus: String?
    #if GOLEM_APP
    /// Golem's quick prompts (Settings → Quick Prompts), in his menu at the top left.
    @AppStorage(GolemQuickPrompts.key) private var quickPromptData = Data()
    #endif
    private var detail: Companion.ChatDetail? { history.detail }
    /// The newest reply that has finished streaming.
    private var latestFinishedReply: Companion.Item? {
        detail?.items.last { $0.kind == .assistant && !$0.isCommentary && !$0.isStreaming && !$0.text.isEmpty }
    }
    private var composerState: MobileComposerDraft<PendingImage> { store.composer(for: chat.id) }
    private var draft: String {
        get { composerState.text }
        nonmutating set { composerState.text = newValue }
    }
    private var pendingImages: [PendingImage] {
        get { composerState.images }
        nonmutating set { composerState.images = newValue }
    }
    private var sending: Bool { composerState.sending }
    /// Visibility and intent are separate: the keyboard or a taller composer can temporarily
    /// cover the end without the reader choosing to stop following it.
    @State private var atBottom = true
    @State private var followingNewest = true
    /// Counts the reader's drags: scroll work queued before one is dropped.
    @State private var scrollWork = ScrollWork()
    @State private var pinRequests = 0
    @State private var layoutRequests = 0
    /// Whether the transcript has been scrolled to the end since it opened with messages in it.
    /// On a slow connection the messages come long after the view does.
    @State private var pinnedLoaded = false
    /// A cover or navigation transition can make this same transcript appear again.
    /// Only a genuinely new view gets the unconditional opening scroll.
    @State private var opened = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var error: String?
    @FocusState private var composing: Bool
    /// The sketch canvas, when open.
    @State private var sketch: SketchRequest?
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var dictation = Dictation()
    #if GOLEM_APP
    @AppStorage("golemDismissedInAppNotice") private var dismissedNotice = ""
    /// Your newest sent message. While set, following the conversation keeps it at the top, so
    /// his reply reads from its start instead of jumping to its end. Scrolling yourself, jumping
    /// to the newest, or reopening the chat clears it.
    @State private var anchoredMessage: UUID?
    /// One dictated message (the widget): after it sends, the microphone stops, and his reply
    /// doesn't reopen it.
    @State private var voiceOnce = false
    @State private var showingCapabilities = false
    @State private var quietAfterReply = false
    @State private var voiceConversation = false
    @State private var voiceGeneration = UUID()
    @State private var voiceEnded = false
    @State private var listeningTask: Task<Void, Never>?
    /// His messages already accounted for (here when the chat opened, or taken up to be read), so
    /// none is read twice; the ones being read aloud, oldest first; and the draft generation spoken
    /// words belong to.
    @State private var knownReplies: Set<UUID>?
    @State private var voiceReplies: [UUID] = []
    @State private var voiceInput: UUID?
    #endif
    @State private var reviewingPDF: Companion.File?
    @State private var showingSettings = false
    @State private var renaming = false
    @State private var newTitle = ""
    /// The Brief editor, and its text while editing.
    @State private var editingBrief = false
    @State private var briefText = ""
    @State private var askingSidequest = false
    @State private var sidequestTask = ""

    private var summary: Companion.ChatSummary { detail?.summary ?? chat }
    private var isConversation: Bool { summary.isDot == true }
    #if DEBUG
    private static let settingsDetents: Set<PresentationDetent> =
        ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SETTINGS"] == "large" ? [.large] : [.medium, .large]
    #else
    private static let settingsDetents: Set<PresentationDetent> = [.medium, .large]
    #endif
    private var golemIdle: Bool { golemComposing?.wrappedValue == false }
    private var agentAccent: Color { MobileConversationStyle.accent(for: summary.backend) }

    private var chatNavigationTitle: String {
        #if GOLEM_APP
        if isConversation { return "" }
        #endif
        return summary.project ?? summary.title
    }

    var body: some View {
        transcript
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isConversation {
                MobileSidequestStrip(summary: summary, chats: store.chatList?.groups.flatMap(\.chats) ?? [], open: open) {
                    let parent = summary.sidequestOf.flatMap { id in store.chatList?.groups.flatMap(\.chats).first { $0.id == id } }
                    perform { try await store.setArchived(true, chat: chat.id) }
                    if let parent { open(parent) }
                }
            }
        }
        // Opening a chat here, from anywhere, clears it from New replies.
        .onAppear { MobileSeenReplies.shared.markSeen(chat.id) }
        .onDisappear { MobileSeenReplies.shared.markSeen(chat.id) }
        .safeAreaInset(edge: .bottom) {
            #if GOLEM_APP
            composer
            #else
            if golemIdle { idleGolem.transition(.opacity) } else { composer.transition(.opacity) }
            #endif
        }
        #if GOLEM_APP
        .toolbarBackground(isConversation ? .hidden : .automatic, for: .navigationBar)
        .sheet(isPresented: $showingCapabilities) {
            NavigationStack {
                GolemCapabilitiesView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingCapabilities = false } } }
            }
        }
        .task {
            guard isConversation else { return }
            while !Task.isCancelled {
                if scenePhase == .active, detail != nil, let request = GolemConversationRequest.shared.pending {
                    if !request.start { endVoiceConversation(); GolemConversationRequest.shared.finish(request) }
                    else if voiceConversation { GolemConversationRequest.shared.finish(request) }
                    else if summary.isRunning || sending || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty {
                        let problem = request.once
                            ? "Golem is busy or your draft isn't empty. Wait for his reply, or send or clear your draft, then try again."
                            : "Wait for Golem to finish and send or clear your draft before starting Conversation."
                        if request.once { error = problem }
                        GolemConversationRequest.shared.finish(request, error: problem)
                    } else {
                        GolemConversationRequest.shared.cancelPending = { endVoiceConversation() }
                        startVoiceConversation(once: request.once)
                        await listeningTask?.value
                        GolemConversationRequest.shared.finish(request, error: dictation.isListening ? nil : dictation.problem ?? "Listening did not start.")
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        #if DEBUG
        .task(id: latestFinishedReply?.id) {
            guard ProcessInfo.processInfo.environment["GOLEM_TEST_DISMISS_NOTICE"] == "1",
                  ProcessInfo.processInfo.environment["CHATTERBOX_TEST_HOST"] == "127.0.0.1",
                  latestFinishedReply != nil else { return }
            dismissedNotice = ""
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            dismissGolemNotice()
        }
        #endif
        #endif
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "chatterbox-document" else { return .systemAction(url) }
            if let id = url.host.flatMap(UUID.init(uuidString:)),
               let file = detail?.items.flatMap(\.attachments).first(where: { $0.id == id }) {
                reviewingPDF = file
            } else { error = "That PDF is no longer listed in this chat. Refresh the chat and try again." }
            return .handled
        })
        .fullScreenCover(item: $reviewingPDF) { file in MobilePDFViewer(file: file, chat: chat.id) }
        .fullScreenCover(item: $sketch) { request in
            SketchView(request: request) { image in
                if let data = image.pngData() {
                    pendingImages.append(PendingImage(preview: image, upload: .init(name: "Sketch", data: data)))
                }
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoPicks, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoPicks) { _, picks in
            guard !picks.isEmpty else { return }
            Task { await addPhotos(picks) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { addImage(data, name: url.lastPathComponent) }
            }
        }
        // Images dragged in from Photos or Files (Split View on iPad).
        .dropDestination(for: Data.self) { items, _ in
            let before = pendingImages.count
            for data in items { addImage(data, name: "Image") }
            return pendingImages.count > before
        }
        .navigationTitle(chatNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .alert("Restart Thread?", isPresented: $confirmingRestart) {
            Button("Restart Thread") { controlSession(restart: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This interrupts any active reply and reconnects this session. History and your draft are kept; send a message to continue.")
        }
        .tint(isConversation ? Color.primary : agentAccent)
        .sheet(isPresented: $showingSettings) {
            if let options = detail?.options {
                ChatSettingsSheet(options: options) { change in perform { try await store.change(change, in: chat.id) } }
                    // The app's own blue, whichever agent: the agent's color stays on its
                    // icons and presets, and orange stays the warning for unrestricted access.
                    .tint(.blue)
                    .presentationDetents(Self.settingsDetents)
            }
        }
        .alert("Sidequest to \(summary.otherAgentLabel)", isPresented: $askingSidequest) {
            TextField("What should \(summary.otherAgentLabel) do?", text: $sidequestTask, axis: .vertical)
            Button("Start Sidequest") {
                let task = sidequestTask.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { return }
                // You stay in this chat; the sidequest shows above the transcript.
                Task {
                    do { _ = try await store.sidequest(from: chat.id, task: task); error = nil; await refresh(force: true) }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(summary.otherAgentLabel) reads this session, does the task in its own sidequest, and its answer comes back here.")
        }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { perform { try await store.rename(chat.id, to: title) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $promoting) { target in
            ChatPromotionSheet(target: target) { result in history.apply(result) }
        }
        .sheet(isPresented: $editingBrief) {
            MobileBriefEditor(text: $briefText, isSet: !(summary.brief ?? "").isEmpty) { brief in
                perform { try await store.setBrief(chat.id, to: brief) }
            }
        }
        #if DEBUG
        // Simulator tests: tap Golem in, then send him back.
        .task(id: detail != nil) {
            guard detail != nil, golemComposing != nil, ProcessInfo.processInfo.environment["CHATTERBOX_TEST_GOLEM_TAP"] != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            setGolemComposing(true)
            try? await Task.sleep(for: .seconds(8))
            setGolemComposing(false)
        }
        .onChange(of: detail?.revision) {
            if ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SETTINGS"] != nil,
               !showingSettings, detail?.options != nil { showingSettings = true }
        }
        #endif
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let detail {
                        if detail.earlierCount > 0 {
                            Text("\(detail.earlierCount) earlier messages are on the Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        MobileTranscriptRows(items: detail.items, chat: chat.id, backend: summary.backend,
                                             conversation: isConversation, actions: actions)
                        #if GOLEM_APP
                        if isConversation, let reply = latestFinishedReply, !summary.isRunning,
                           dismissedNotice != reply.id.uuidString {
                            Button { dismissGolemNotice() } label: {
                                Label("Dismiss notification", systemImage: "xmark")
                                    .font(.caption)
                                    .frame(minHeight: 44)
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityHint("Dismisses this notice and dims Golem. The message stays in your history.")
                        }
                        if isConversation && summary.isRunning {
                            Text("•••").font(.title2.bold()).foregroundStyle(.secondary)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                                .accessibilityLabel("Golem is working")
                                .id("working")
                        }
                        #endif
                        if !isConversation && summary.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working\u{2026}").font(.callout).foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    } else if error == nil && history.problem == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let error = error ?? history.problem { MobileProblemCard(error) }
                    // Include the bottom margin in the target, so scrolling reaches the true end.
                    Color.clear.frame(height: 1).padding(.bottom, 16).id("bottom")
                        // Before iOS 18 there's no scroll geometry: row appearance stands in for it
                        // (lazy rows, so it can mean prefetched rather than visible).
                        .onAppear { if !Self.measuresScroll { atBottom = true } }
                        .onDisappear { if !Self.measuresScroll { atBottom = false } }
                }
                .padding(.horizontal, 16).padding(.top, 16)
                // A readable width on iPad, centered.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("chatTranscript")
            .modifier(NearBottom(report: { near in
                atBottom = near
            }, settled: { near in
                guard scrollWork.dragging else { return }
                scrollWork.dragging = false
                atBottom = near
                // A drag toward older messages means "let me read", even if it ends inside
                // the bottom tolerance. Resume only when the reader deliberately returns.
                followingNewest = near && scrollWork.towardNewest
            }))
            // Reading takes over until the reader returns to the end or explicitly jumps there.
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { drag in
                scrollWork.generation += 1
                scrollWork.dragging = true
                scrollWork.towardNewest = drag.translation.height < 0
                followingNewest = false
                #if GOLEM_APP
                if anchoredMessage != nil { anchoredMessage = nil }
                #endif
            }.onEnded { _ in
                // On modern iOS use the actual settled geometry, after deceleration. The
                // last Boolean delivered during a drag can still describe the old viewport.
                if !Self.measuresScroll {
                    scrollWork.dragging = false
                    followingNewest = atBottom && scrollWork.towardNewest
                }
            })
            .modifier(TranscriptAnchors(following: followingNewest))
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await refresh(force: true) }
            // New messages follow only if you're at the end (or it's just opened), so scrolling
            // up to read isn't undone by the next update.
            .onChange(of: detail?.revision) {
                if !pinnedLoaded, detail != nil {
                    pinnedLoaded = true
                    pin(proxy, for: 1.5)
                } else if followingNewest {
                    pin(proxy, for: 1.0)
                }
            }
            .onAppear {
                if opened {
                    if followingNewest { pin(proxy, for: 1.5) }
                    return
                }
                opened = true
                // A prefetched or cached detail is already covered by this opening pin.
                // Otherwise its first subsequent update (often a send) looks like first load.
                pinnedLoaded = detail != nil
                #if GOLEM_APP
                anchoredMessage = nil
                #endif
                pin(proxy, for: 1.5)
            }
            .onDisappear { scrollWork.generation += 1; scrollWork.dragging = false }
            // Above the newest messages: a button back down, above the message box.
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if !atBottom || !followingNewest, detail != nil {
                        Button {
                            #if GOLEM_APP
                            anchoredMessage = nil
                            #endif
                            pin(proxy, for: 0.8)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityLabel("Scroll to newest message")
                        .accessibilityHint("Jumps to the end of the session")
                    }
                }
                .animation(.easeOut(duration: 0.18), value: atBottom)
            }
            .onChange(of: pinRequests) { pin(proxy, for: 1.5) }
            // The tab bar coming or going resizes the list: keep a reader at the end there, not one above it.
            .onChange(of: layoutRequests) { if followingNewest { pin(proxy, for: 1.5) } }
            .onChange(of: composing) { if followingNewest { pin(proxy, for: 1.5) } }
            #if GOLEM_APP
            // "Read new replies aloud": each reply that arrives while this chat is open, read
            // sentence by sentence as it streams in (the chat refreshes about every second meanwhile).
            .onChange(of: voiceFollowKey) {
                followReplyAloud()
            }
            // He starts working on what you said: a falling chime, in a voice conversation.
            .onChange(of: summary.isRunning) { _, running in
                if running, voiceConversation { GolemCues.play(.thinking) }
            }
            .onDisappear { endVoiceConversation() }
            #endif
            .onChange(of: scenePhase) { _, phase in
                #if GOLEM_APP
                if phase == .background { endVoiceConversation() }
                #endif
                guard phase == .active else { return }
                // App/overlay return must not take a reader away from older messages.
                // First-load handling remains with the revision observer above.
                if followingNewest { pin(proxy, for: 1.5) }
            }
            #if DEBUG
            // Simulator tests: scroll to the top, then tap the button.
            .task(id: detail != nil) {
                guard detail != nil, ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SCROLL_BUTTON"] != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                proxy.scrollTo(detail?.items.first?.id, anchor: .top)
                try? await Task.sleep(for: .seconds(6))
                pin(proxy, for: 0.8)
            }
            #endif
        }
    }

    #if GOLEM_APP
    private var noticeDismissed: Bool {
        guard let reply = latestFinishedReply else { return false }
        return dismissedNotice == reply.id.uuidString && !summary.isRunning && !voiceConversation && !dictation.isListening
    }

    private func dismissGolemNotice() {
        guard let reply = latestFinishedReply else { return }
        endVoiceConversation()
        dismissedNotice = reply.id.uuidString
    }

    /// Golem at the top left: tap for the quick prompts (Settings → Quick Prompts) and Jump to Newest.
    private var toolbarGolem: some View {
        // The animation redraws many times a second, and a menu whose label keeps changing closes
        // as soon as it opens. So he's drawn behind, and the menu's own label is still.
        ZStack {
            Group {
                if MobileGolem.shared.hasAnimations {
                    MobileGolemAnimated(mood: MobileGolem.mood(summary))
                } else {
                    Image(systemName: "sparkles").font(.title2)
                }
            }
            .frame(width: 44, height: 44)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            Menu {
                let prompts = GolemQuickPrompts.decode(quickPromptData)
                if !prompts.isEmpty {
                    Section(summary.isRunning ? "Golem is replying\u{2026}" : "Ask Golem") {
                        ForEach(prompts) { prompt in
                            Button(prompt.label) { sendQuickPrompt(prompt) }.disabled(summary.isRunning)
                        }
                    }
                }
                Button { pinRequests += 1 } label: { Label("Jump to Newest", systemImage: "arrow.down.to.line") }
                Button { showingCapabilities = true } label: { Label("What Golem Can Do", systemImage: "sparkles") }
            } label: {
                Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Golem")
            .accessibilityHint("Quick prompts, and jump to the newest message")
        }
        // Dismissing his reply quiets him, but his menu stays in reach.
        .opacity(noticeDismissed ? 0.4 : 1)
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.3), value: noticeDismissed)
    }

    /// "Claude · Haiku" or "Codex · GPT-6 Luna": which model Golem is running on.
    private var golemModelLabel: String? {
        guard let options = detail?.options else { return nil }
        let codex = options.backend == "codex"
        let name = (codex ? options.codexModels : options.claudeModels).first { $0.id == options.model }?.name
            ?? (options.model.isEmpty ? "default model" : options.model)
        return "\(codex ? "Codex" : "Claude") \u{00B7} \(name)"
    }

    /// Golem's model at the top of his conversation; tap to change it.
    private func golemModelPill(_ label: String) -> some View {
        Button { showingSettings = true } label: {
            HStack(spacing: 4) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(label)")
        .accessibilityHint("Opens Golem's model settings")
    }

    /// Sends a quick prompt as its own message; whatever is in the message box stays there.
    private func sendQuickPrompt(_ prompt: GolemQuickPrompt) {
        pinRequests += 1
        Task {
            do {
                let result = try await store.send(GolemQuickPrompts.expand(prompt.text), to: chat.id)
                history.apply(result)
                anchoredMessage = result.items.last { $0.kind == .user }?.id
                pinRequests += 1
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    #endif

    /// Golem large and centered under the latest messages; tapping him starts a message.
    #if GOLEM_APP
    private var idleGolem: some View {
        VStack(spacing: 6) {
            if summary.isRunning {
                Text("Replying\u{2026}")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }
            Button { setGolemComposing(true) } label: {
                Group {
                    if MobileGolem.shared.hasAnimations {
                        MobileGolemAnimated(mood: MobileGolem.mood(summary))
                    } else {
                        Image(systemName: "bubble.left.fill").font(.system(size: 64)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 190, height: 190)
                .modifier(GolemMatch(enabled: !reduceMotion, namespace: golemSpace))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message \(summary.title)")
            .accessibilityHint("Shows the message box")
            if dictation.isListening {
                Button { endVoiceConversation() } label: {
                    Label(draft.isEmpty ? "Listening\u{2026}" : draft, systemImage: "mic.fill")
                        .lineLimit(3)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Listening. Pause to send, or tap to stop.")
                Text("Pause to send \u{00B7} tap to stop").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Tap to chat").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    #else
    private var idleGolem:some View {EmptyView()}
    #endif

    private func setGolemComposing(_ on: Bool) {
        guard let golemComposing, golemComposing.wrappedValue != on else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82)) {
            golemComposing.wrappedValue = on
        }
        // The tab bar coming or going resizes the list, which loses its place: back to the end,
        // if that's where the reader was.
        layoutRequests += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { layoutRequests += 1 }
    }

    private static let measuresScroll: Bool = { if #available(iOS 18, *) { true } else { false } }()

    /// Scrolls to the newest message, again a few times while lazy rows get measured. Only the
    /// newest request can run; a reader drag cancels the whole batch.
    private func pin(_ proxy: ScrollViewProxy, for seconds: Double) {
        followingNewest = true
        scrollWork.request += 1
        let work = scrollWork, generation = work.generation
        let request = work.request
        for delay in [0, 0.05, 0.15, 0.35, 0.7, 1.1] where delay <= seconds + 0.05 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard work.generation == generation, work.request == request else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    #if GOLEM_APP
                    // After you send: your message at the top (or the end, if everything fits).
                    if let anchoredMessage { proxy.scrollTo(anchoredMessage, anchor: .top); return }
                    #endif
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
            if isConversation {
                #if GOLEM_APP
                ToolbarItem(placement: .topBarLeading) { toolbarGolem }
                if let label = golemModelLabel {
                    ToolbarItem(placement: .principal) { golemModelPill(label) }
                }
                #else
                ToolbarItem(placement: .principal) {
                    Text(summary.title).font(.headline).lineLimit(1)
                }
                #endif
                #if !GOLEM_APP
                ToolbarItem(placement: .topBarTrailing) { FeedbackButton() }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Session Settings")
                        .disabled(detail?.options == nil)
                }
            } else if let settings = detail?.settings {
                ToolbarItem(placement: .principal) {
                    // Tap the title for the model, effort, and mode.
                    Button { showingSettings = true } label: {
                        VStack(spacing: 0) {
                            Text(summary.project ?? summary.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                            HStack(spacing: 3) {
                                Text(settings).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(detail?.options == nil)
                }
            }
            #if !GOLEM_APP
            ToolbarItem(placement: .topBarTrailing) { FeedbackButton() }
            #endif
            ToolbarItem(placement: .topBarTrailing) { chatMenu }
    }

    private var chatMenu: some View {
        Menu {
            Button { Task { await refresh(force: true) } } label: {
                Label("Refresh Session", systemImage: "arrow.clockwise")
            }
            .disabled(history.refreshing)
            Button { controlSession(restart: false) } label: { Label("Stop Reply", systemImage: "stop.circle") }
                .disabled(!summary.isRunning || controllingSession)
            Button { confirmingRestart = true } label: { Label("Restart Thread", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(detail == nil || controllingSession)
            if let sessionControlStatus { Text(sessionControlStatus) }
            Button { showingSettings = true } label: { Label("Session Settings", systemImage: "slider.horizontal.3") }
                .disabled(detail?.options == nil)
            if !isConversation, summary.worktreeBranch == nil, summary.sidechatOf == nil {
                Button {
                    let pin = summary.pinnedRank == nil
                    Task { try? await store.setPinned(chat.id, pin); history.refresh(in: store, force: true) }
                } label: {
                    Label(summary.pinnedRank == nil ? "Pin to Top" : "Unpin", systemImage: summary.pinnedRank == nil ? "pin" : "pin.slash")
                }
            }
            Button { newTitle = summary.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            if !isConversation {
                Button { briefText = summary.brief ?? ""; editingBrief = true } label: {
                    Label((summary.brief ?? "").isEmpty ? "Brief…" : "Edit Brief…", systemImage: "doc.text")
                }
            }
            if !isConversation, !summary.isSidequest, detail?.isArchived != true {
                Button { sidequestTask = ""; askingSidequest = true } label: {
                    Label("Sidequest to \(summary.otherAgentLabel)…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
            if summary.canPromote == true, detail?.isArchived != true {
                Button { promoting = .init(chat: summary, kind: .studio) } label: { Label("Move to Studio…", systemImage: "paintpalette") }
                    .disabled(summary.isRunning || controllingSession)
                Button { promoting = .init(chat: summary, kind: .project) } label: { Label("Make Project…", systemImage: "folder.badge.plus") }
                    .disabled(summary.isRunning || controllingSession)
            }
            if detail?.canFork == true {
                Button { forkChat() } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
            }
            Divider()
            if detail?.isArchived == true {
                Button { perform { try await store.setArchived(false, chat: chat.id) } } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button(role: .destructive) {
                    Task {
                        do { _ = try await store.setArchived(true, chat: chat.id); closeChat(); await store.loadChats() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Session Menu")
    }

    private func forkChat() {
        Task {
            do {
                open(try await store.fork(chat.id).summary)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Actions

    private var actions: ItemActions {
        ItemActions(
            decide: { item, decision in perform { try await store.decide(decision, item: item, in: chat.id) } },
            answer: { item, answers in perform { try await store.answer(answers, item: item, in: chat.id) } },
            sendQueuedNow: { item in perform { try await store.sendQueuedNow(item, in: chat.id) } },
            markUp: { image in sketch = SketchRequest(background: image) }
        )
    }

    /// Runs a call to the Mac and shows the chat as it comes back.
    private func controlSession(restart: Bool) {
        guard !controllingSession else { return }
        controllingSession = true
        sessionControlStatus = restart ? "Restarting…" : "Stopping…"
        Task {
            defer { controllingSession = false }
            do {
                let result = restart ? try await store.restart(chat.id) : try await store.stop(chat.id)
                history.apply(result)
                sessionControlStatus = restart ? "Thread restarted. History kept." : "Stop requested."
                error = nil
            } catch {
                sessionControlStatus = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func perform(_ call: @escaping () async throws -> Companion.ChatDetail) {
        Task {
            do {
                history.apply(try await call())
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func refresh(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        await history.refresh(in: store, force: force).value
    }

    private var canSend: Bool {
        !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    /// `now`: stop the agent and send this right away, instead of adding it to the reply.
    private func send(now: Bool = false) async {
        // A voice conversation keeps its microphone running across the send.
        if dictation.isListening, !dictation.conversationActive { dictation.stop() }
        let state = composerState
        guard let submission = state.beginSend() else { return }
        let generation = scrollWork.generation
        do {
            let result = try await store.send(submission.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                              images: submission.images.map(\.upload), now: now, to: chat.id)
            state.finish(submission)
            history.apply(result)
            // Follow the actual message, after it exists. A reader who dragged while the send
            // was in flight keeps their chosen position instead.
            if scrollWork.generation == generation {
            #if GOLEM_APP
                anchoredMessage = result.items.last { $0.kind == .user }?.id
            #endif
                pinRequests += 1
            }
            error = nil
        } catch {
            state.finish(submission, failed: true)
            self.error = error.localizedDescription
        }
    }

    /// Photos from the library, as JPEGs no bigger than the agents use.
    private func addPhotos(_ picks: [PhotosPickerItem]) async {
        for pick in picks {
            if let data = try? await pick.loadTransferable(type: Data.self) { addImage(data, name: "Photo") }
        }
        photoPicks = []
    }

    /// Any image (photo, file, or drop), sized down to what the agents use and sent as JPEG.
    /// The name goes without an extension; the Mac adds the right one.
    private func addImage(_ data: Data, name: String) {
        guard let image = UIImage(data: data) else { return }
        let scaled = image.scaledDown(toEdge: 2576)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return }
        let base = (name as NSString).deletingPathExtension
        pendingImages.append(PendingImage(preview: scaled, upload: .init(name: base.isEmpty ? "Image" : base, data: jpeg)))
    }

    // MARK: - Message box

    /// Next Steps (a Chatterbox plugin, Settings → Plugins on the Mac): tap one to put it in
    /// the box as a draft you can edit. Nothing is sent on its own.
    private func nextStepsChips(_ steps: [String]) -> some View {
        // Folded to one line until you open it, so suggestions don't take over the screen;
        // open, one per line, in full, so each can be read before tapping.
        let expanded = expandedSteps == steps
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expandedSteps = expanded ? nil : steps }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Next steps · \(steps.count)").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide suggested next steps" : "Show \(steps.count) suggested next steps")
                Button { dismissedSteps = steps } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestions")
            }
            if expanded { ForEach(steps, id: \.self) { step in
                Button { draft = step } label: {
                    Text(step).font(.footnote)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Puts it in the message box to edit")
            } }
        }
        .padding(.horizontal, 4)
    }


    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detail, detail.turnStartedAt != nil || !(detail.backgroundTasks ?? []).isEmpty || detail.contextFraction != nil {
                ChatStatusBar(detail: detail).padding(.horizontal, 4)
            }
            if !pendingImages.isEmpty { pendingTray }
            if let steps = detail?.nextSteps, !steps.isEmpty, !summary.isRunning, dismissedSteps != steps { nextStepsChips(steps) }
            if dictation.isListening {
                Label(listeningHint, systemImage: "waveform")
                    .font(.caption).foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            } else if let problem = dictation.problem {
                Label(problem, systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
            }
            if draft.hasPrefix("!") {
                Label("Runs in your shell on the Mac\(detail?.folder.map { " in " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""). The output goes to the agent with your next message.",
                      systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !commandMatches.isEmpty { commandMenu }
            composerRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 784)
        .frame(maxWidth: .infinity)
        .background(.bar)
        // Line wrapping, attachments and clearing a draft all change the transcript's viewport.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in layoutRequests += 1 }
    }

    /// Tap to talk, tap again to stop. Words land after whatever's already typed.
    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        let state = composerState
        let before = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = state.inputGeneration
        Task {
            await dictation.start { spoken in
                state.applyTranscription(spoken, prefix: before, generation: generation)
            }
        }
    }

    #if GOLEM_APP
    private func startVoiceConversation(once: Bool = false) {
        guard !summary.isRunning, !sending, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingImages.isEmpty else { return }
        voiceGeneration = UUID()
        voiceOnce = once
        voiceEnded = false
        voiceConversation = true
        composing = false
        GolemVoice.shared.stop()
        listenForReply()
    }

    private func endVoiceConversation() {
        voiceGeneration = UUID()
        voiceOnce = false
        voiceConversation = false
        voiceEnded = true
        voiceReplies = []
        voiceInput = nil
        listeningTask?.cancel()
        listeningTask = nil
        dictation.stop()
        GolemVoice.shared.stop()
    }

    /// Reads the newest reply as it streams in, with the microphone warm so your turn starts the
    /// moment he's done. He always finishes unless you press stop or mute. Replies already here
    /// when the chat opened stay quiet.
    /// His messages and whether each is still being written: anything that changes what's read aloud.
    private var voiceMessages: [Companion.Item] {
        detail?.items.filter { $0.kind == .assistant && !$0.text.isEmpty } ?? []
    }
    private var voiceFollowKey: String {
        voiceMessages.suffix(6).map { "\($0.id)\($0.text.count)\($0.isStreaming)" }.joined(separator: "|") + "|\(summary.isRunning)"
    }

    /// Reads each new message aloud, whole and in order: one that arrives while another is being
    /// read waits its turn, and one already read (or that was here when the chat opened) isn't read
    /// again, even when its status changes after it's finished (narration, say).
    private func followReplyAloud() {
        // A saved copy from the last visit isn't what's new: wait for the Mac's.
        guard scenePhase == .active, !history.isCached else { return }
        let messages = voiceMessages
        guard var known = knownReplies else { knownReplies = Set(messages.map(\.id)); return }
        for message in messages where !known.contains(message.id) {
            known.insert(message.id)
            let quiet = quietAfterReply
            quietAfterReply = false
            // Ending a conversation (or dismissing his notice) silences the reply it was on, not
            // the ones after it.
            voiceEnded = false
            guard voiceConversation || GolemVoice.shared.autoRead else { continue }
            voiceReplies.append(message.id)
            if !quiet, voiceConversation || GolemVoice.shared.listensAfter { listenForReply() }
        }
        knownReplies = known
        guard !voiceEnded else { return }
        let session = voiceGeneration
        for id in voiceReplies {
            guard let message = messages.first(where: { $0.id == id }) else { continue }
            // Complete once it's no longer being written (narration ends mid-turn), or his turn ended.
            GolemVoice.shared.update(reply: id, text: message.text, final: !message.isStreaming || !summary.isRunning) {
                guard session == voiceGeneration, !voiceEnded else { return }
                finishedSpeaking()
            }
        }
    }

    /// He finished reading: the ears are already open; start the silence clock over for your turn.
    private func finishedSpeaking() {
        voiceReplies = []
        if dictation.conversationActive {
            dictation.cancelUtterance()
            GolemCues.play(.listening)   // your turn
        }
        else if voiceConversation || GolemVoice.shared.listensAfter { listenForReply() }
    }

    /// One finished utterance: send it and keep listening on the same microphone. Silence while he
    /// talks just keeps listening; silence on your turn ends the conversation.
    private func heardUtterance(_ spoken: String) {
        // Heard while he was talking: not yours to send (and possibly his own voice).
        if GolemVoice.shared.speakingID != nil, dictation.conversationActive { dictation.nextUtterance(); return }
        if spoken.isEmpty {
            if GolemVoice.shared.speakingID != nil, dictation.conversationActive { dictation.nextUtterance(); return }
            endVoiceConversation()
            return
        }
        // Typed text is yours; the voice loop never sends over it.
        guard composerState.inputGeneration == voiceInput else { endVoiceConversation(); return }
        let session = voiceGeneration
        Task {
            await send()
            guard session == voiceGeneration, voiceConversation else { return }
            if error != nil { endVoiceConversation(); return }
            GolemCues.play(.sent)
            // One message from the widget: sent, so the microphone stops; his reply stays quiet-eared.
            if voiceOnce { quietAfterReply = true; endVoiceConversation(); return }
            voiceInput = composerState.inputGeneration
            dictation.nextUtterance()
        }
    }

    /// Opens the microphone for the conversation: it stays on across turns and while he speaks.
    private func listenForReply() {
        guard isConversation, scenePhase == .active, !voiceEnded, !dictation.conversationActive, listeningTask == nil else { return }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingImages.isEmpty else {
            if voiceConversation { endVoiceConversation() }
            return
        }
        voiceConversation = true
        setGolemComposing(true)
        if knownReplies == nil { knownReplies = Set(voiceMessages.map(\.id)) }
        let session = voiceGeneration
        voiceInput = composerState.inputGeneration
        listeningTask = Task {
            // Speech while he talks doesn't stop him (only stop and mute do), and isn't typed or sent.
            let started = await dictation.startConversation(giveUp: 30, onSpeechDetected: {}, onUtterance: { spoken in
                guard session == voiceGeneration else { return }
                heardUtterance(spoken)
            }, onText: { spoken in
                guard session == voiceGeneration, let input = voiceInput, GolemVoice.shared.speakingID == nil else { return }
                composerState.applyTranscription(spoken, prefix: "", generation: input)
            })
            guard session == voiceGeneration else { return }
            listeningTask = nil
            if !started { endVoiceConversation(); return }
            // Listening for you now (not while he's still reading): a soft rising chime.
            if GolemVoice.shared.speakingID == nil { GolemCues.play(.listening) }
        }
    }
    #endif

    /// From the + menu. iOS may ask "Allow Paste?" first.
    private func pasteImages() {
        for image in UIPasteboard.general.images ?? [] {
            if let data = image.pngData() { addImage(data, name: "Pasted image") }
        }
    }

    /// While the draft is "/" and part of a name: matching commands and skills.
    private var commandMatches: [Companion.Command] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let typed = draft.dropFirst().lowercased()
        let commands = detail?.commands ?? []
        let starts = commands.filter { $0.name.lowercased().hasPrefix(typed) }
        let contains = commands.filter { !$0.name.lowercased().hasPrefix(typed) && $0.name.lowercased().contains(typed) }
        return Array((starts + contains).prefix(6))
    }

    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commandMatches) { command in
                Button { draft = "/\(command.name) " } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/" + command.name).font(.callout.weight(.semibold)).lineLimit(1)
                        if let hint = command.argumentHint { Text(hint).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                        Text(command.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if command.id != commandMatches.last?.id { Divider() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
    }

    /// Images waiting to be sent; tap × to drop one.
    private var pendingTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { pending in
                    Image(uiImage: pending.preview)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button { pendingImages.removeAll { $0.id == pending.id } } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .accessibilityLabel("Remove \(pending.upload.name) image")
                            .padding(3)
                        }
                }
            }
        }
    }

    private var listeningHint: String {
        #if GOLEM_APP
        if isConversation { return "Listening… pause to send, or tap stop to end." }
        #endif
        return "Listening… tap the mic to stop."
    }

    private var dictationButton: some View {
        Button { toggleDictation() } label: {
            Image(systemName: dictation.isListening ? "mic.circle.fill" : "mic.circle")
                .font(.system(size: 30))
                .foregroundStyle(dictation.isListening ? Color.red : Color.secondary)
        }
        .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // The pickers open from the chat, not from inside the menu, where iOS doesn't
            // reliably show them.
            Menu {
                Button { choosingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                Button { choosingFiles = true } label: { Label("Files", systemImage: "folder") }
                Button { pasteImages() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                Button { sketch = SketchRequest(background: nil) } label: { Label("Sketch", systemImage: "pencil.tip.crop.circle") }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 30))
            }
            .tint(.secondary)
            .accessibilityLabel("Add a photo, file, or sketch")

            TextField(isConversation ? "Message \(summary.title)" : (summary.isRunning ? "Add something while it works\u{2026}" : "Message"), text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("messageComposer")
                .lineLimit(1...6)
                .focused($composing)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(
                    isConversation ? Color.primary.opacity(0.12) : agentAccent.opacity(0.35), lineWidth: 1))

            #if GOLEM_APP
            if isConversation {
                Button {
                    if voiceConversation { endVoiceConversation() } else { startVoiceConversation() }
                } label: {
                    Image(systemName: voiceConversation ? "stop.fill" : "waveform")
                        .font(.system(size: voiceConversation ? 15 : 19, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(.white, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voiceConversation ? "End Conversation" : "Conversation")
                .accessibilityIdentifier("golem-voice-conversation")
                .help(voiceConversation ? "End Conversation" : "Conversation")
                .disabled(!voiceConversation && (detail == nil || summary.isRunning || sending || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty))
            } else {
                dictationButton
            }
            #endif

            if summary.isRunning {
                Button { controlSession(restart: false) } label: {
                    Image(systemName: "stop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(.secondary)
                }
                .disabled(controllingSession)
                .accessibilityLabel("Stop")
            }

            // Golem uses one trailing action slot; ordinary chats retain queued sending.
            if !isConversation || !summary.isRunning {

            // While the agent works, the send button adds to the reply; hold it to Send Now.
            Button { Task { await send() } } label: {
                Image(systemName: sending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .tint(agentAccent)
            .disabled(!canSend)
            .contextMenu {
                if summary.isRunning {
                    Button { Task { await send(now: true) } } label: {
                        Label("Send Now (stop and send)", systemImage: "bolt.fill")
                    }
                    .disabled(!canSend)
                }
            }
            .accessibilityLabel("Send")
            }
        }
    }
}

private extension UIImage {
    func scaledDown(toEdge maxEdge: CGFloat) -> UIImage {
        let edge = max(size.width, size.height)
        guard edge > maxEdge else { return self }
        let ratio = maxEdge / edge
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// Isolates transcript layout from the screen's navigation and attachment presentation.
private struct MobileTranscriptRows: View {
    let items: [Companion.Item]
    let chat: UUID
    let backend: String
    let conversation: Bool
    let actions: ItemActions

    var body: some View {
        ForEach(MobileConversationStyle.groups(items, conversation: conversation)) { group in
            if group.isSteps {
                DisclosureGroup {
                    ForEach(group.items) { item in
                        ItemRow(item: item, chat: chat, backend: backend,
                                conversation: false, actions: actions).id(item.id)
                    }
                } label: {
                    Text("\(group.items.count) \(group.items.count == 1 ? "step" : "steps")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tint(.secondary)
            } else {
                ForEach(group.items) { item in
                    ItemRow(item: item, chat: chat, backend: backend,
                            conversation: conversation, actions: actions).id(item.id)
                }
            }
        }
    }
}

/// One row of the transcript, styled like the Mac's.
private struct ItemRow: View {
    let item: Companion.Item
    let chat: UUID
    let backend: String
    let conversation: Bool
    let actions: ItemActions

    #if GOLEM_APP
    @AppStorage(GolemBubbleColor.key, store: AppPreferences.defaults) private var bubbleRGB = GolemBubbleColor.standard
    #endif
    private var outgoingFill: Color {
        #if GOLEM_APP
        if conversation { return GolemBubbleColor.color(bubbleRGB) }
        #endif
        return MobileConversationStyle.bubble(for: backend)
    }
    private var outgoingText: Color {
        #if GOLEM_APP
        if conversation { return GolemBubbleColor.text(bubbleRGB) }
        #endif
        return .white
    }

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !item.text.isEmpty {
                    Text(item.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(outgoingText)
                        .background(RoundedRectangle(cornerRadius: 20).fill(outgoingFill))
                }
                images
                if item.isQueued {
                    HStack(spacing: 8) {
                        Text("Queued").font(.caption2).foregroundStyle(.secondary)
                        Button("Send Now") { actions.sendQueuedNow(item.id) }
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)

        case .assistant:
            if item.isCommentary {
                if conversation {
                    MobileReplyBubbles(text: item.text, messageID: item.id).font(.callout)
                } else {
                    MarkdownText(text: item.text).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if conversation {
                        MobileReplyBubbles(text: item.text, messageID: item.id)
                    } else {
                        MarkdownText(text: item.text)
                    }
                    // Animations the reply points to, playing.
                    ForEach(item.attachments.filter { !$0.isImage && RemoteMedia.isMedia($0) }) { file in
                        RemoteMedia(file: file, chat: chat)
                    }
                    // Screenshots and renders it points to, to view and save.
                    images
                    HStack(spacing: 14) {
                        if !conversation, let seconds = item.workedSeconds {
                            Label("Worked for \(durationText(seconds))", systemImage: "clock")
                        }
                        // Selecting stops at each paragraph; this copies the whole reply.
                        Button { UIPasteboard.general.string = item.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderless)
                        #if GOLEM_APP
                        // Golem reads it aloud (ElevenLabs with a key, else the phone's voice).
                        Button { GolemVoice.shared.toggle(item.id, text: item.text) } label: {
                            Label(GolemVoice.shared.speakingID == item.id ? "Stop" : "Listen",
                                  systemImage: GolemVoice.shared.speakingID == item.id ? "stop.fill" : "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
                        #endif
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .thought:
            if !item.text.isEmpty { ThoughtRow(text: item.text) }

        case .tool:
            ToolRow(item: item)

        case .plan:
            if let steps = item.planSteps, !steps.isEmpty { PlanCard(steps: steps) }

        case .shell:
            ShellRow(item: item)

        case .image:
            VStack(alignment: .leading, spacing: 6) {
                images
                ForEach(item.attachments.filter(RemotePreview.isPreviewable)) { file in
                    RemotePreview(file: file, chat: chat)
                }
                ForEach(item.attachments.filter { !$0.isImage && RemoteMedia.isMedia($0) }) { file in
                    RemoteMedia(file: file, chat: chat)
                }
                if !item.text.isEmpty { Text(item.text).font(.caption).foregroundStyle(.secondary) }
            }

        case .approval:
            if let approval = item.approval {
                ApprovalCard(item: item, approval: approval) { actions.decide(item.id, $0) }
            }

        case .questions:
            if let questions = item.questions, !questions.isEmpty {
                QuestionsCard(item: item, questions: questions) { actions.answer(item.id, $0) }
            }

        case .notice:
            if item.text.hasPrefix("Email for you") {
                // Golem's email reports, as on the Mac: the Gmail mark beside the email, in a card.
                HStack(alignment: .top, spacing: 9) {
                    Image("Gmail").resizable().scaledToFit().frame(width: 20, height: 20).accessibilityLabel("Gmail")
                    Text(item.text.replacingOccurrences(of: "Email for you \u{00B7} ", with: ""))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.4)))
                .padding(.trailing, 40)
            } else {
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var images: some View {
        ForEach(item.attachments.filter { $0.mediaType == "application/pdf" || ($0.name as NSString).pathExtension.lowercased() == "pdf" }) { file in
            MobilePDFButton(file: file, chat: chat)
        }
        // A GIF plays; other images are pictures to view and mark up.
        ForEach(item.attachments.filter(\.isImage)) { file in
            if (file.name as NSString).pathExtension.lowercased() == "gif" {
                RemoteMedia(file: file, chat: chat)
            } else {
                RemoteImage(file: file, chat: chat, onMarkUp: actions.markUp)
            }
        }
        // Videos you sent from the Mac.
        if item.kind == .user {
            ForEach(item.attachments.filter { !$0.isImage && RemoteMedia.isMedia($0) }) { file in
                RemoteMedia(file: file, chat: chat)
            }
        }
    }
}

/// Visibility rather than lazy-row creation controls image downloads on iOS 18+.
private struct ImageVisibility: ViewModifier {
    let report: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            // Lazy rows may exist before they enter the viewport. Start at the first sliver.
            content.onScrollVisibilityChange(threshold: 0.01, report)
                .onDisappear { report(false) }
        } else {
            content.onAppear { report(true) }.onDisappear { report(false) }
        }
    }
}

/// An image from the chat, fetched from the Mac at the size it shows here (and kept on this
/// phone); viewing, marking up or copying it gets the original. Hold it for those.
private struct RemoteImage: View {
    let file: Companion.File
    let chat: UUID
    let onMarkUp: (UIImage) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var original: UIImage?
    @State private var viewing = false
    @State private var failed = false
    @State private var visible = false
    @State private var retry = 0
    @State private var loadedKey: String?
    private struct LoadRequest: Hashable {
        let key: String
        let visible: Bool
        let retry: Int
    }
    /// 320 points wide on a 3x screen, with room to zoom a little.
    static let displayPixels = 1200

    /// The original, fetched the first time it's needed; the shown copy until then.
    private func full() async -> UIImage? {
        if let original { return original }
        original = try? await store.image(file, in: chat, maxPixels: nil)
        return original ?? image
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityLabel(file.name)
                    .accessibilityIdentifier("chat-image-\(file.id.uuidString.lowercased())")
                    .onTapGesture { viewing = true }
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 160)
                    .overlay {
                        if failed {
                            Button("Couldn't load \(file.name). Tap to retry.") { retry += 1 }
                                .font(.caption).foregroundStyle(.secondary).padding(8)
                                .accessibilityIdentifier("retry-image-\(file.id.uuidString.lowercased())")
                        } else { ProgressView() }
                    }
            }
        }
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .fullScreenCover(isPresented: $viewing) {
            if let shown = original ?? image { ImageViewer(image: shown, onMarkUp: onMarkUp) }
        }
        .contextMenu {
            if image != nil {
                Button { viewing = true } label: { Label("View", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { Task { if let full = await full() { onMarkUp(full) } } } label: { Label("Mark Up", systemImage: "pencil.tip.crop.circle") }
                Button { Task { if let full = await full() { UIPasteboard.general.image = full } } } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
        // The viewer opens on the shown copy and sharpens to the original when it arrives.
        .onChange(of: viewing) { _, open in if open { Task { _ = await full() } } }
        .modifier(ImageVisibility(report: { visible = $0 }))
        .task(id: LoadRequest(key: imageKey, visible: visible && scenePhase == .active, retry: retry)) {
            await load()
        }
    }

    private var imageKey: String {
        MobileImageCache.key(chat: chat, file: file, size: String(Self.displayPixels))
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        if loadedKey != imageKey {
            image = nil
            original = nil
            failed = false
            loadedKey = imageKey
        }
        guard visible, scenePhase == .active else { return }
        guard image == nil else { return }
        failed = false
        // One attempt on entering view, then two short retries for transient failures.
        // The view task cancels both the request and the backoff on leaving/backgrounding.
        for delay in [0.0, 0.75, 2.0] {
            do {
                try await Task.sleep(for: .seconds(delay))
                let fetched = try await store.image(file, in: chat, maxPixels: Self.displayPixels)
                try Task.checkCancellation()
                if let fetched { image = fetched; return }
            } catch {
                // Lazy-row cancellation is ordinary scrolling, not a broken image.
                if Task.isCancelled { return }
            }
        }
        failed = true
    }
}

/// Golem's centered and tucked-in spots, linked so he glides between them (skipped with
/// Reduce Motion, where he simply fades).
private struct GolemMatch: ViewModifier {
    let enabled: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if enabled { content.matchedGeometryEffect(id: "golem", in: namespace, properties: .frame) } else { content }
    }
}

/// The session's Brief, as on the Mac: the assignment, the tools to use, the key files.
private struct MobileBriefEditor: View {
    @Binding var text: String
    let isSet: Bool
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier("brief-text")
                } footer: {
                    Text("Claude and Codex both get it, and keep it across an agent switch. It reaches the agent with your next message.")
                }
                if isSet {
                    Section { Button("Clear Brief", role: .destructive) { save(""); dismiss() } }
                }
            }
            .navigationTitle("Session Brief").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(text); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

