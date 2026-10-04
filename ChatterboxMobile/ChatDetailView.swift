import PhotosUI
import SwiftUI

/// An image waiting to go with the next message: a sketch, or a photo from the library.
struct PendingImage: Identifiable {
    let id = UUID()
    var preview: UIImage
    var upload: Companion.Upload
}

/// Counts the reader's drags; scroll work queued before one is dropped. Reference-typed so a drag
/// doesn't redraw the chat.
final class ScrollWork { var generation = 0 }

/// Reports whether the visible part of a scroll view is within a couple of lines of its end,
/// measured from the scroll geometry (iOS 18 and later).
private struct NearBottom: ViewModifier {
    var report: (Bool) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { $0.contentSize.height - $0.visibleRect.maxY < 40 } action: { _, near in
                report(near)
            }
        } else {
            content
        }
    }
}

/// One chat: its transcript, kept current while it's open, and a message box.
struct ChatDetailView: View {
    let chat: Companion.ChatSummary
    /// Opens another chat (a fork) in this one's place.
    var open: (Companion.ChatSummary) -> Void = { _ in }
    let history: MobileChatHistory
    /// On the iPhone's Golem tab: false shows him large and centered with no message box,
    /// true tucks him into his spot under the last message and brings the box back.
    var golemComposing: Binding<Bool>? = nil
    @Environment(MobileStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var golemSpace
    /// Next Steps suggestions you closed on this device, until new ones arrive.
    @State private var dismissedSteps: [String]?
    private var detail: Companion.ChatDetail? { history.detail }
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
    /// Whether the reader is at the end of the transcript (measured against the scroll view's
    /// visible area, not row appearance), and until when to keep them there.
    @State private var atBottom = true
    @State private var pinUntil = Date.distantPast
    /// Counts the reader's drags: scroll work queued before one is dropped.
    @State private var scrollWork = ScrollWork()
    @State private var pinRequests = 0
    @State private var layoutRequests = 0
    /// Whether the transcript has been scrolled to the end since it opened with messages in it.
    /// On a slow connection the messages come long after the view does.
    @State private var pinnedLoaded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var error: String?
    @FocusState private var composing: Bool
    /// The sketch canvas, when open.
    @State private var sketch: SketchRequest?
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var dictation = Dictation()
    @State private var reviewingPDF: Companion.File?
    @State private var showingSettings = false
    @State private var renaming = false
    @State private var newTitle = ""

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

    var body: some View {
        transcript
        .safeAreaInset(edge: .bottom) {
            if golemIdle { idleGolem.transition(.opacity) } else { composer.transition(.opacity) }
        }
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
        .navigationTitle(summary.project ?? summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .tint(isConversation ? Color.primary : agentAccent)
        .sheet(isPresented: $showingSettings) {
            if let options = detail?.options {
                ChatSettingsSheet(options: options) { change in perform { try await store.change(change, in: chat.id) } }
                    .tint(agentAccent)
                    .presentationDetents(Self.settingsDetents)
            }
        }
        .alert("Rename Chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { perform { try await store.rename(chat.id, to: title) } }
            }
            Button("Cancel", role: .cancel) {}
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
                        if isConversation && !golemIdle {
                            // The assistant, below his latest message: thinking while he works.
                            HStack(alignment: .bottom, spacing: 8) {
                                if MobileGolem.shared.hasAnimations {
                                    MobileGolemAnimated(mood: MobileGolem.mood(summary))
                                        .frame(width: 80, height: 80)
                                        .modifier(GolemMatch(enabled: golemComposing != nil && !reduceMotion, namespace: golemSpace))
                                        .contentShape(Rectangle())
                                        .onTapGesture { if golemComposing != nil { setGolemComposing(false) } }
                                        .accessibilityAddTraits(golemComposing != nil ? .isButton : [])
                                        .accessibilityHint(golemComposing != nil ? "Puts the message box away" : "")
                                }
                                if summary.isRunning {
                                    Text("Replying\u{2026}")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                                        .padding(.bottom, 12)
                                }
                            }
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
                    if let error = error ?? history.problem {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        // Before iOS 18 there's no scroll geometry: row appearance stands in for it
                        // (lazy rows, so it can mean prefetched rather than visible).
                        .onAppear { if !Self.measuresScroll { atBottom = true } }
                        .onDisappear { if !Self.measuresScroll { atBottom = false } }
                }
                .padding(16)
                // A readable width on iPad, centered.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .modifier(NearBottom { atBottom = $0 })
            // Reading: a drag takes over from any scroll still queued, and ends the follow window.
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
                scrollWork.generation += 1
                if pinUntil > .distantPast { pinUntil = .distantPast }
            })
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await refresh(force: true) }
            // New messages follow only if you're at the end (or it's just opened), so scrolling
            // up to read isn't undone by the next update.
            .onChange(of: detail?.revision) {
                if !pinnedLoaded, detail != nil {
                    pinnedLoaded = true
                    pin(proxy, for: 1.5)
                } else if atBottom || Date() < pinUntil {
                    pin(proxy, for: 1.0)
                }
            }
            .onAppear {
                pinnedLoaded = detail == nil ? false : pinnedLoaded
                pin(proxy, for: 1.5)
            }
            // Above the newest messages: a button back down, above the message box.
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, detail != nil {
                    Button {
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
                    .accessibilityHint("Jumps to the end of the chat")
                }
            }
            .animation(.easeOut(duration: 0.18), value: atBottom)
            .onChange(of: pinRequests) { pin(proxy, for: 1.5) }
            // The tab bar coming or going resizes the list: keep a reader at the end there, not one above it.
            .onChange(of: layoutRequests) { if atBottom || Date() < pinUntil { pin(proxy, for: 1.5) } }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // Already loaded: this pin covers it. Otherwise the first load will.
                pinnedLoaded = detail != nil
                pin(proxy, for: 1.5)
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
            Text("Tap to chat").font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
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

    /// Scrolls to the newest message, again a few times while rows load and get measured
    /// (a lazy list only estimates the height of rows it hasn't drawn). If the reader drags the
    /// transcript before the repeats run, they're dropped.
    private func pin(_ proxy: ScrollViewProxy, for seconds: Double) {
        pinUntil = max(pinUntil, Date().addingTimeInterval(seconds))
        let work = scrollWork, generation = work.generation
        for delay in [0, 0.05, 0.15, 0.35, 0.7, 1.1] where delay <= seconds + 0.05 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard work.generation == generation else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
            if isConversation {
                if golemComposing != nil && !golemIdle {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { setGolemComposing(false) }
                            .accessibilityHint("Puts the message box away and brings back the tabs")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(summary.title).font(.headline).lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Chat Settings")
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
            ToolbarItem(placement: .topBarTrailing) { chatMenu }
    }

    private var chatMenu: some View {
        Menu {
            Button { Task { await refresh(force: true) } } label: {
                Label("Refresh Chat", systemImage: "arrow.clockwise")
            }
            .disabled(history.refreshing)
            Button { showingSettings = true } label: { Label("Chat Settings", systemImage: "slider.horizontal.3") }
                .disabled(detail?.options == nil)
            Button { newTitle = summary.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            if detail?.canFork == true {
                Button { forkChat() } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
            }
            Divider()
            if detail?.isArchived == true {
                Button { perform { try await store.setArchived(false, chat: chat.id) } } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button(role: .destructive) { perform { try await store.setArchived(true, chat: chat.id) } } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Chat Menu")
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
        if dictation.isListening { dictation.stop() }
        pinRequests += 1   // Your own message: always go to the end.
        let state = composerState
        guard let submission = state.beginSend() else { return }
        do {
            let result = try await store.send(submission.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                              images: submission.images.map(\.upload), now: now, to: chat.id)
            state.finish(submission)
            history.apply(result)
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
        // One per line, in full, so each can be read before tapping.
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { dismissedSteps = steps } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestions")
            }
            ForEach(steps, id: \.self) { step in
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
            }
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
                Label("Listening\u{2026} tap the mic to stop.", systemImage: "waveform")
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
                            .padding(3)
                        }
                }
            }
        }
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

            Button { toggleDictation() } label: {
                Image(systemName: dictation.isListening ? "mic.circle.fill" : "mic.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(dictation.isListening ? Color.red : Color.secondary)
            }
            .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")

            if summary.isRunning {
                Button { perform { try await store.stop(chat.id) } } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Stop")
            }

            // While the agent works, the send button adds to the reply; hold it to Send Now.
            Button { Task { await send() } } label: {
                Image(systemName: sending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 34))
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

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !item.text.isEmpty {
                    Text(item.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 20).fill(MobileConversationStyle.bubble(for: backend)))
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

/// An image from the chat, fetched from the Mac. Hold it to mark it up or copy it.
private struct RemoteImage: View {
    let file: Companion.File
    let chat: UUID
    let onMarkUp: (UIImage) -> Void
    @Environment(MobileStore.self) private var store
    @State private var image: UIImage?
    @State private var viewing = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .onTapGesture { viewing = true }
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 160)
                    .overlay(ProgressView())
            }
        }
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .fullScreenCover(isPresented: $viewing) {
            if let image { ImageViewer(image: image, onMarkUp: onMarkUp) }
        }
        .contextMenu {
            if let image {
                Button { viewing = true } label: { Label("View", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { onMarkUp(image) } label: { Label("Mark Up", systemImage: "pencil.tip.crop.circle") }
                Button { UIPasteboard.general.image = image } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
        .task {
            if image == nil, let data = try? await store.file(file, in: chat) { image = UIImage(data: data) }
        }
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
