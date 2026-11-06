import SwiftUI

// The Desk on the phone and iPad: a board of what's to do, working, needing you, ready to mark
// complete, and done. plans/front-desk.md, plans/desk-board.md
// Tasks linked to threads (plans/work-threads.md): Working, Ready and Done are tasks by their
// thread's state; Needs you marks threads that aren't tasks (Make this a task); To do cards Link
// a thread; task cards Unlink from their menu.

/// The board's columns, left to right.
enum MobileDeskColumn: String, CaseIterable, Identifiable {
    case todo, working, needsYou = "needs-you", ready, done
    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: "To do"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .ready: "Review"
        case .done: "Done"
        }
    }
    /// On the phone's tabs.
    var short: String { title }
    /// A column with nothing in it: one quiet line.
    var empty: String {
        switch self {
        case .todo: "Nothing waiting to start."
        case .working: "Nothing running."
        case .needsYou: "Nothing needs you."
        case .ready: "Nothing finished to mark complete."
        case .done: "Nothing completed this week."
        }
    }
}

/// The home's first tab: the Desk as a board. To do: requests waiting to be placed (start where
/// the Desk proposes, or choose another place). Working: sessions mid-reply. Needs you: approve
/// or deny in place, open, or swipe left (or long-press) to silence. Review:
/// sessions that finished and ask nothing; swipe left (or Mark Complete) archives one into Done,
/// where Reopen brings it back. The Desk never does work itself: starting a request (a step to
/// pick the model, or a session already there to continue) runs it in its Studio or project in
/// the background, with a note to open it. On a phone, one column at a time under tabs with
/// counts; wide (an iPad, an open iPhone Duo), the columns side by side, scrolling sideways.
struct MobileDeskView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var ask = ""
    @State private var adding = false
    @FocusState private var asking: Bool
    /// Waiting items and requests acted on here, hidden until the Desk stops listing them.
    @State private var settled = Set<UUID>()
    /// Waiting things being silenced (silenceKey), hidden until the Mac answers.
    @State private var silencing = Set<String>()
    /// Silenced things being put back (silenceKey), off the silenced list until the Mac answers.
    @State private var unsilencing = Set<String>()
    /// The last thing silenced here: a few seconds to Undo it.
    @State private var silencedNote: Companion.DeskWaiting?
    /// Sessions being marked complete or reopened here, hidden until the Mac answers.
    @State private var completing = Set<UUID>()
    @State private var reopening = Set<UUID>()
    /// The Desk's width: the columns side by side when there's room.
    @State private var width: CGFloat = 0
    /// The phone's column; nil until the Desk first answers (then Needs you if anything does).
    @State private var column: MobileDeskColumn?
    /// Wide, the board has been scrolled to Needs you once.
    @State private var showedNeedsYou = false
    @State private var busy = Set<UUID>()
    /// Places picked from the place chip, per request; Start uses them.
    @State private var chosen: [UUID: Companion.DeskPlace] = [:]
    @State private var choosing: Companion.DeskRequest?
    /// Start was tapped with no place: once one is picked, its step opens.
    @State private var startAfterChoosing: Companion.DeskRequest?
    /// The request in Start's step (MobileDeskStartSheet).
    @State private var starting: Companion.DeskRequest?
    /// The request whose Link a thread sheet is open.
    @State private var linking: Companion.DeskRequest?
    /// Why the Desk couldn't be read, shown until it can.
    @State private var loadProblem: String?
    /// An action that didn't go through.
    @State private var actionProblem: String?
    /// The last request started (or continued) from here: it runs in the background, with a note to open it.
    @State private var started: (name: String, chat: UUID, continued: Bool)?
    @State private var showingAutomations = false
    /// A run's session picked in Automations: opened once the sheet has closed.
    @State private var automationPick: UUID?

    /// What the Desk's tab counts, as of its last answer: what needs you and requests
    /// waiting to be placed (not what's ready to mark complete: nothing waits on that).
    static func waiting(_ desk: Companion.Desk) -> Int { desk.needsYou.count + desk.incoming.count }

    /// Wider than this, the columns go side by side.
    static let boardWidth: CGFloat = 560
    static func isWide(_ width: CGFloat) -> Bool { width - 32 > boardWidth }
    /// A column's width, side by side.
    static let columnWidth: CGFloat = 320

    /// What silencing hides: the item, or for a reply (its id is the session's) the question it asks.
    static func silenceKey(_ item: Companion.DeskWaiting) -> String {
        "\(item.chatID.uuidString)|\(item.id.uuidString)|\(item.kind == "reply" ? item.text : "")"
    }
    static func silenceKey(_ item: Companion.DeskReady) -> String { "ready|\(item.id.uuidString)|\(item.text)" }

    /// "6 min. ago", short enough for a card's top line beside its place in a column.
    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private var desk: Companion.Desk? { store.latestDesk }
    private var needsYou: [Companion.DeskWaiting] {
        (desk?.needsYou ?? []).filter { !settled.contains($0.id) && !silencing.contains(Self.silenceKey($0)) }
    }
    private var incoming: [Companion.DeskRequest] { (desk?.incoming ?? []).filter { !settled.contains($0.id) } }
    private var working: [Companion.DeskWorking] { desk?.working ?? [] }
    private var ready: [Companion.DeskReady] {
        (desk?.ready ?? []).filter { !completing.contains($0.id) && !silencing.contains(Self.silenceKey($0)) }
    }
    private var done: [Companion.DeskDone] { (desk?.done ?? []).filter { !reopening.contains($0.id) } }
    /// Silenced, still waiting in their sessions: the quiet row at the foot of Needs you.
    private var silenced: [Companion.DeskWaiting] { (desk?.silenced ?? []).filter { !unsilencing.contains(Self.silenceKey($0)) } }

    private func count(_ column: MobileDeskColumn) -> Int {
        switch column {
        case .todo: incoming.count
        case .working: working.count
        case .needsYou: needsYou.count
        case .ready: ready.count
        case .done: done.count
        }
    }

    private var wide: Bool { Self.isWide(width) }
    private var shown: MobileDeskColumn { column ?? (needsYou.isEmpty ? .todo : .needsYou) }

    var body: some View {
        NavigationStack {
            Group {
                if wide { board } else { tabbed }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Desk")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Every project's routines, to change or run (MobileAutomations.swift).
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAutomations = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Automations")
                        .accessibilityIdentifier("desk-automations")
                }
                ToolbarItem(placement: .topBarTrailing) { FeedbackButton() }
            }
        }
        .sheet(isPresented: $showingAutomations, onDismiss: {
            if let id = automationPick { automationPick = nil; open(id) }
        }) { MobileAutomationsView { automationPick = $0 }.environment(store) }
        .sheet(item: $choosing, onDismiss: {
            if let request = startAfterChoosing { startAfterChoosing = nil; if place(for: request) != nil { start(request) } }
        }) { request in
            MobileDeskPlacePicker(current: place(for: request)) { chosen[request.id] = $0 }
                .environment(store)
        }
        .sheet(item: $linking) { request in
            if let place = place(for: request) {
                MobileDeskLinkSheet(request: request, place: place) { actionProblem = $0 }
                    .environment(store)
            }
        }
        .sheet(item: $starting) { request in
            if let place = place(for: request) {
                MobileDeskStartSheet(request: request, place: place, changed: { chosen[request.id] = $0 }) { body, name in
                    begin(request, body, name: name)
                }
                .environment(store)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                // Silenced: a few seconds to take it back.
                if let note = silencedNote {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash.fill").foregroundStyle(.indigo)
                        Text("Silenced \(deskContext(title: note.title, place: note.place, subtitle: note.subtitle))").font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Undo") { unsilence(note) }.font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("desk-undo-silence")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("desk-silenced-note")
                    .task(id: Self.silenceKey(note)) {
                        try? await Task.sleep(for: .seconds(6))
                        withAnimation { if silencedNote.map(Self.silenceKey) == Self.silenceKey(note) { silencedNote = nil } }
                    }
                }
                if let started {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(started.continued ? "Continued" : "Started") in \(started.name)").font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Open") { open(started.chat); self.started = nil }.font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("desk-started")
                    .task(id: started.chat) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { self.started = nil }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .alert("Couldn't update the Desk", isPresented: Binding(get: { actionProblem != nil }, set: { if !$0 { actionProblem = nil } })) {
            Button("OK", role: .cancel) { actionProblem = nil }
        } message: { Text(actionProblem ?? "") }
        // The phone opens on Needs you when something does, else To do; then stays where it's put.
        .onChange(of: desk != nil, initial: true) { _, loaded in
            if loaded, column == nil { column = needsYou.isEmpty ? .todo : .needsYou }
        }
        // On screen: kept current, like the chat list.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Layouts

    /// What's above the board: a problem reaching the Mac, the ask box, or that it's loading.
    @ViewBuilder private var top: some View {
        if let problem = store.problem ?? loadProblem {
            MobileProblemCard(problem, updated: store.chatsUpdatedAt) { await refresh() }
        }
        // Nothing to ask of a Mac without the Desk, or one not reached yet.
        if desk != nil || (loadProblem == nil && store.problem == nil) { askBox }
        if desk == nil, loadProblem == nil, store.problem == nil { loading }
    }

    /// A phone: the ask box, then the column tabs (they stay at the top as the cards scroll),
    /// then one column's cards.
    private var tabbed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 16) { top }
                    .padding(.bottom, 10)
                Section {
                    VStack(alignment: .leading, spacing: 10) { cards(shown) }
                        .padding(.top, 4)
                        .animation(.easeOut(duration: 0.2), value: ids(shown))
                } header: {
                    tabs
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await refresh() }
    }

    /// The columns as tabs, each with its count; the one shown is raised.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(MobileDeskColumn.allCases) { column in
                let on = shown == column
                let count = count(column)
                Button { withAnimation(.snappy(duration: 0.2)) { self.column = column } } label: {
                    VStack(spacing: 1) {
                        Text("\(count)").font(.headline.monospacedDigit())
                            .foregroundStyle(column == .needsYou && count > 0 ? Color.attention : on ? Color.primary : Color.metadata)
                        Text(column.short).font(.caption2.weight(on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(on ? Color.primary : Color.metadata)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .systemGray4))
                                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(column.title), \(count)")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("desk-tab-\(column.id)")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)))
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// Wide: the ask box, then the columns side by side, each scrolling on its own, the board
    /// sideways when they don't all fit (shown at Needs you when something does).
    private var board: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) { top }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(MobileDeskColumn.allCases) { column in
                            lane(column).id(column)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .onChange(of: needsYou.isEmpty, initial: true) { _, empty in
                    guard !empty, !showedNeedsYou else { return }
                    showedNeedsYou = true
                    proxy.scrollTo(MobileDeskColumn.needsYou, anchor: .center)
                }
            }
        }
        .padding(.top, 4)
    }

    /// One column, side by side with the others: its name and count, then its cards.
    private func lane(_ column: MobileDeskColumn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(column.title).font(.subheadline.weight(.semibold))
                Text("\(count(column))").font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(column == .needsYou && count(column) > 0 ? Color(uiColor: .systemBackground) : Color.metadata)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(column == .needsYou && count(column) > 0 ? Color.attention : Color.primary.opacity(0.08)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(column.title), \(count(column))")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("desk-section-\(column.id)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) { cards(column) }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                    .animation(.easeOut(duration: 0.2), value: ids(column))
            }
            .refreshable { await refresh() }
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Cards

    @ViewBuilder private func cards(_ column: MobileDeskColumn) -> some View {
        if desk != nil, count(column) == 0 {
            empty(column)
        }
        switch column {
        case .todo:
            ForEach(incoming) { request in
                DeskRequestCard(request: request, place: place(for: request), changed: chosen[request.id] != nil,
                                busy: busy.contains(request.id), swipes: !wide,
                                start: { start(request) },
                                change: { choosing = request },
                                ignore: { ignore(request) },
                                markDone: { markDone(request) },
                                link: hasTasks && place(for: request) != nil ? { linking = request } : nil,
                                writeBack: { writeBack(request.id) })
            }
        case .working:
            ForEach(working) { item in
                DeskWorkingCard(item: item, open: { open(item.id) }, stale: store.isStale || loadProblem != nil,
                                unlink: item.task.map { task in { unlink(task) } },
                                writeBack: item.task.map { task in { writeBack(task) } })
            }
        case .needsYou:
            ForEach(needsYou) { item in
                DeskWaitingCard(item: item, busy: busy.contains(item.id), swipes: !wide,
                                open: { open(item.chatID) },
                                decide: { decide($0, item) },
                                silence: { silence(item) },
                                hasTasks: hasTasks,
                                makeTask: { makeTask(item.chatID) },
                                unlink: item.task.map { task in { unlink(task) } },
                                writeBack: item.task.map { task in { writeBack(task) } },
                                completeChat: { completeChat(item.chatID) })
            }
            if !silenced.isEmpty {
                DeskSilencedList(items: silenced, busy: unsilencing) { unsilence($0) }
            }
        case .ready:
            ForEach(ready) { item in
                DeskReadyCard(item: item, swipes: !wide, open: { open(item.id) }, complete: { complete(item) }, silence: { silence(item) },
                              unlink: item.task.map { task in { unlink(task) } },
                              writeBack: item.task.map { task in { writeBack(task) } })
            }
        case .done:
            ForEach(done) { item in
                DeskDoneCard(item: item, busy: reopening.contains(item.id), reopen: { reopen(item) },
                             writeBack: item.task.map { task in { writeBack(task) } })
            }
        }
    }

    private func ids(_ column: MobileDeskColumn) -> [UUID] {
        switch column {
        case .todo: incoming.map(\.id)
        case .working: working.map(\.id)
        case .needsYou: needsYou.map(\.id)
        case .ready: ready.map(\.id)
        case .done: done.map(\.id)
        }
    }

    /// A column with nothing in it.
    private func empty(_ column: MobileDeskColumn) -> some View {
        Text(column.empty)
            .font(.subheadline).foregroundStyle(Color.metadata)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.vertical, 10)
            .accessibilityIdentifier("desk-empty-\(column.id)")
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the Desk…").font(.footnote).foregroundStyle(Color.metadata)
        }
        .accessibilityElement(children: .combine)
    }

    private var trimmedAsk: String { ask.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Type what needs doing; the Desk proposes where it goes before anything starts.
    private var askBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("What needs doing?", text: $ask, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($asking)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("desk-ask")
                Button(action: add) {
                    Group {
                        if adding { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }
                    .frame(width: 32, height: 32)
                }
                .disabled(trimmedAsk.isEmpty || adding)
                .accessibilityLabel("Add to Desk")
                .accessibilityIdentifier("desk-ask-send")
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(asking ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: asking ? 1.5 : 1))
            Text("The Desk suggests a place before anything starts.")
                .font(.caption).foregroundStyle(Color.metadata).padding(.horizontal, 6)
        }
    }

    // MARK: Actions

    private func refresh() async {
        async let chats: Void = store.loadChats()
        do {
            let fresh = try await store.desk()
            loadProblem = nil
            // What the Desk no longer lists needn't stay hidden.
            settled = settled.filter { id in fresh.needsYou.contains { $0.id == id } || fresh.incoming.contains { $0.id == id } }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { loadProblem = Self.describe(error) }
        }
        await chats
    }

    /// Opens a session in its own tab, as a tapped notification does: on iPhone over that
    /// tab's list, on iPad beside it.
    private func open(_ chat: UUID) {
        Task {
            // The tab is chosen from the chat list; a new session may not be in it yet.
            if store.chatList?.groups.contains(where: { $0.chats.contains { $0.id == chat } }) != true { await store.loadChats() }
            MobilePushNotifications.shared.pendingChat = chat
        }
    }

    private func add() {
        let text = trimmedAsk
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                _ = try await store.addToDesk(text)
                ask = ""
                asking = false
                // On a phone, the new request shows in To do.
                withAnimation { column = .todo }
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Approve or deny in place, with the same call the session's own card makes.
    private func decide(_ decision: String, _ item: Companion.DeskWaiting) {
        guard busy.insert(item.id).inserted else { return }
        Task {
            defer { busy.remove(item.id) }
            do {
                _ = try await store.decide(decision, item: item.id, in: item.chatID)
                settled.insert(item.id)
                _ = try? await store.desk()
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Silence: off the Desk on every device, without answering it; it stays waiting in its
    /// session, and something new from it shows again.
    private func silence(_ item: Companion.DeskWaiting) {
        let key = Self.silenceKey(item)
        guard silencing.insert(key).inserted else { return }
        Task {
            defer { silencing.remove(key) }
            do {
                _ = try await store.silenceDesk(item)
                // A few seconds to take it back; it's also listed under "silenced".
                withAnimation { silencedNote = item }
            } catch let error as MobileError where error.status == 404 {
                actionProblem = "Silencing needs the newest Chatterbox on the Mac. Update it there to use it."
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Unsilence (Undo, or the silenced list): back on the Desk on every device.
    private func unsilence(_ item: Companion.DeskWaiting) {
        let key = Self.silenceKey(item)
        guard unsilencing.insert(key).inserted else { return }
        if silencedNote.map(Self.silenceKey) == key { withAnimation { silencedNote = nil } }
        Task {
            defer { unsilencing.remove(key) }
            do {
                _ = try await store.unsilenceDesk(item)
                withAnimation { column = .needsYou }
            } catch let error as MobileError where error.status == 404 {
                actionProblem = "Unsilencing needs the newest Chatterbox on the Mac. Update it there to use it."
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Silence a session ready to mark complete: off the board until something new happens in it.
    private func silence(_ item: Companion.DeskReady) {
        let key = Self.silenceKey(item)
        guard silencing.insert(key).inserted else { return }
        Task {
            defer { silencing.remove(key) }
            do { _ = try await store.silenceDesk(item) } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Mark complete: the Mac archives it, and it moves to Done.
    private func complete(_ item: Companion.DeskReady) {
        guard completing.insert(item.id).inserted else { return }
        Task {
            defer { completing.remove(item.id) }
            do {
                _ = try await store.completeDesk(item.id)
            } catch let error as MobileError where error.status == 404 {
                actionProblem = "Mark Complete needs the newest Chatterbox on the Mac. Update it there to use it."
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Write-back: the Mac asks an agent to make the change in the task's source; that session opens.
    private func writeBack(_ task: UUID) {
        guard busy.insert(task).inserted else { return }
        Task {
            defer { busy.remove(task) }
            do {
                let detail = try await store.writeBackDesk(task)
                open(detail.summary.id)
            } catch let error as MobileError where error.status == 404 {
                actionProblem = "That needs the newest Chatterbox on the Mac. Update it there to use it."
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Move to match: its source is finished, so its thread is marked complete.
    private func completeChat(_ chat: UUID) {
        guard completing.insert(chat).inserted else { return }
        Task {
            defer { completing.remove(chat) }
            do { _ = try await store.completeDesk(chat) } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Reopen: unarchived, it leaves Done.
    private func reopen(_ item: Companion.DeskDone) {
        guard reopening.insert(item.id).inserted else { return }
        Task {
            defer { reopening.remove(item.id) }
            do { _ = try await store.reopenDesk(item.id) } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Start: first its step (the place, a session already there to continue, the model); with
    /// no place yet, the places first.
    private func start(_ request: Companion.DeskRequest) {
        guard place(for: request) != nil else { startAfterChoosing = request; choosing = request; return }
        guard !busy.contains(request.id) else { return }
        starting = request
    }

    /// Sends what the start step chose; `name` is where it went, for the note.
    private func begin(_ request: Companion.DeskRequest, _ body: Companion.DeskStartRequest, name: String) {
        guard busy.insert(request.id).inserted else { return }
        Task {
            defer { busy.remove(request.id) }
            do {
                let detail = try await store.startDesk(request.id, body)
                settled.insert(request.id)
                chosen[request.id] = nil
                // It runs in the background; the Desk stays, with a note to open it.
                withAnimation { started = (name, detail.summary.id, body.continueChat != nil) }
                _ = try? await store.desk()
            } catch { actionProblem = Self.describe(error) }
        }
    }

    private func markDone(_ request: Companion.DeskRequest) {
        guard busy.insert(request.id).inserted else { return }
        Task {
            defer { busy.remove(request.id) }
            do {
                _ = try await store.markDeskDone(request.id)
                settled.insert(request.id)
                chosen[request.id] = nil
            } catch { actionProblem = Self.describe(error) }
        }
    }

    private func ignore(_ request: Companion.DeskRequest) {
        guard busy.insert(request.id).inserted else { return }
        Task {
            defer { busy.remove(request.id) }
            do {
                _ = try await store.ignoreDesk(request.id)
                settled.insert(request.id)
                chosen[request.id] = nil
            } catch { actionProblem = Self.describe(error) }
        }
    }

    private func place(for request: Companion.DeskRequest) -> Companion.DeskPlace? {
        chosen[request.id] ?? request.proposed
    }

    /// Whether the Mac keeps tasks (an older one sends no `linked`).
    private var hasTasks: Bool { desk?.linked != nil }

    /// Make this a task: the thread goes on the board as a task, already linked.
    private func makeTask(_ chat: UUID) {
        guard busy.insert(chat).inserted else { return }
        Task {
            defer { busy.remove(chat) }
            do { _ = try await store.makeTask(chat) } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Unlink: the task goes back to To do; its thread carries on.
    private func unlink(_ task: UUID) {
        guard busy.insert(task).inserted else { return }
        Task {
            defer { busy.remove(task) }
            do { _ = try await store.unlinkDesk(task); withAnimation { column = .todo } } catch { actionProblem = Self.describe(error) }
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? MobileError, error.status == 404 {
            return "The Desk isn't on this Mac yet. Update Chatterbox on the Mac to use it."
        }
        return error.localizedDescription
    }
}

// MARK: - Places

enum MobileDeskPlaces {
    static func icon(_ place: Companion.DeskPlace?) -> String {
        switch place?.kind {
        case "studio": "paintpalette"
        case "project": "folder"
        case "loose": "bubble.left"
        case nil: "questionmark.circle"
        default: "tray"
        }
    }

    /// The same place, whether or not each copy carries its detail line.
    static func same(_ a: Companion.DeskPlace?, _ b: Companion.DeskPlace) -> Bool {
        guard let a else { return false }
        return a.kind == b.kind && a.id == b.id && (a.id != nil || a.name == b.name)
    }
}

/// A Studio or project's name, small, with its kind's symbol.
private struct DeskPlaceTag: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption.weight(.medium)).foregroundStyle(Color.metadata).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// A card's surface: the grouped background's raised fill, with a hairline (or `stroke`).
private extension View {
    func deskCard(stroke: Color = Color.primary.opacity(0.06), width: CGFloat = 1) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(stroke, lineWidth: width))
    }
}

/// Where a waiting session is, as its approval card says it everywhere: "USA Archery › Deploy
/// the site", or "SDHQ › Cache rules" for a project's session.
func deskContext(title: String, place: String?, subtitle: String?) -> String {
    [place.flatMap { $0 == title ? nil : $0 }, title, subtitle].compactMap { $0 }.joined(separator: " \u{203A} ")
}

/// A session waiting on you. An approval or plan is the one approval card (ApprovalPanel): Allow,
/// Allow for Session or Deny in place. Questions and a reply that asks: Open. The top of the
/// card opens the session; swipe it left (then tap Silence) or long-press it to silence it.
private struct DeskWaitingCard: View {
    let item: Companion.DeskWaiting
    let busy: Bool
    /// Side by side, a sideways drag scrolls the board instead: no swipe.
    var swipes = true
    let open: () -> Void
    let decide: (String) -> Void
    let silence: () -> Void
    /// The Mac keeps tasks: a thread that isn't one says so, with Make this a task.
    var hasTasks = false
    var makeTask: () -> Void = {}
    var unlink: (() -> Void)? = nil
    var writeBack: (() -> Void)? = nil
    var completeChat: () -> Void = {}

    private var decides: Bool { item.kind == "approval" || item.kind == "plan" }
    private var context: String { deskContext(title: item.title, place: item.place, subtitle: item.subtitle) }

    var body: some View {
        DeskSwipe(action: .silence, id: item.id.uuidString, enabled: swipes, fullSwipe: false, perform: silence) { taps in card(taps) }
    }

    /// The card; its buttons go through `taps`, so letting go of a swipe doesn't press them.
    private func card(_ taps: DeskSwipeTaps) -> some View {
        let id = item.id.uuidString
        return VStack(alignment: .leading, spacing: 12) {
            if decides {
                ApprovalPanel(context: context, ask: item.text, command: item.detail, isPlan: item.kind == "plan", busy: busy,
                              identifier: { $0 == "open-card" ? "desk-waiting-\(id)" : "desk-\($0)-\(id)" },
                              decide: decide, taps: { taps($0) }, open: open)
                    .accessibilityAction(named: "Silence", silence)
            } else {
                Button(action: taps(open)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(WaitingKind.title(item.kind), systemImage: WaitingKind.icon(item.kind))
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.attention)
                        Text(context).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                            .accessibilityIdentifier("desk-context-\(id)")
                        Text(item.text).font(.callout).lineLimit(4).multilineTextAlignment(.leading)
                        if let questions = item.questions, questions.count > 1 {
                            Text("\(questions.count) questions").font(.caption).foregroundStyle(Color.metadata)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the session")
                .accessibilityAction(named: "Silence", silence)
                .accessibilityIdentifier("desk-waiting-\(id)")
                Button("Open", action: taps(open))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("desk-open-\(id)")
            }
            if item.autoStarted == true { MobileDeskAutoStartedTag() }
            MobileDeskSourceLine(id: (item.task ?? item.chatID).uuidString, origin: item.origin, check: item.check,
                                 matchLabel: "Mark Complete", match: completeChat, writeBack: writeBack, taps: { taps($0) })
            if let task = item.taskText, item.task != nil {
                DeskTaskLine(text: task)
            } else if hasTasks {
                HStack(spacing: 8) {
                    Text("Not a task").font(.caption).foregroundStyle(Color.metadata)
                    Button("Make this a task", action: taps(makeTask))
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("desk-make-task-\(item.chatID.uuidString)")
                    Spacer(minLength: 0)
                }
            }
        }
        // Visible in both modes: the amber that reads on white, yellow on dark.
        .deskCard(stroke: Color.attention.opacity(0.8), width: 1.5)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square", action: open)
            if let unlink { Button("Unlink Task", systemImage: "link", action: unlink) }
            else if hasTasks { Button("Make This a Task", systemImage: "checklist", action: makeTask) }
            Button("Silence", systemImage: "bell.slash", action: silence)
        }
    }
}

/// The foot of Needs you: what was silenced, folded into one quiet row ("2 silenced"); opened,
/// each with Unsilence, which puts it back on the Desk on every device.
private struct DeskSilencedList: View {
    let items: [Companion.DeskWaiting]
    let busy: Set<String>
    let unsilence: (Companion.DeskWaiting) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                    Text("\(items.count) silenced")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.metadata)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(items.count) silenced")
            .accessibilityValue(open ? "Shown" : "Hidden")
            .accessibilityHint("Things taken off the Desk that still wait in their sessions")
            .accessibilityIdentifier("desk-silenced-row")
            if open {
                ForEach(items) { item in
                    Divider().padding(.leading, 14)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deskContext(title: item.title, place: item.place, subtitle: item.subtitle)).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(WaitingKind.title(item.kind)): \(item.text)").font(.caption).foregroundStyle(Color.metadata).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        Button("Unsilence") { unsilence(item) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(busy.contains(MobileDeskView.silenceKey(item)))
                            .accessibilityIdentifier("desk-unsilence-\(item.id.uuidString)")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.top, 6)
    }
}

/// A session working now: its name, place and what it's doing; a tap (or Open) opens it.
private struct DeskWorkingCard: View {
    let item: Companion.DeskWorking
    let open: () -> Void
    /// The Mac can't be reached: as last seen, not spinning.
    var stale = false
    var unlink: (() -> Void)? = nil
    var writeBack: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if stale {
                            Label("Last seen working", systemImage: "clock")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.metadata).lineLimit(1)
                        } else {
                            ProgressView().controlSize(.mini)
                            Text(item.since.map { "Working · \(MobileDeskView.ago($0))" } ?? "Working")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.metadata).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let place = item.place, place != item.title { DeskPlaceTag(name: place) }
                    }
                    Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let task = item.taskText, ![item.title, item.subtitle].contains(task) { DeskTaskLine(text: task) }
                    if let activity = item.activity, !activity.isEmpty {
                        Text(activity).font(.subheadline).foregroundStyle(Color.metadata).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title)\(item.subtitle.map { ", " + $0 } ?? ""), \(stale ? "last seen working" : "working")\(item.place.flatMap { $0 != item.title ? ", in \($0)" : nil } ?? "")\(item.activity.map { ": " + $0 } ?? "")")
            .accessibilityHint("Opens the session")
            .accessibilityIdentifier("desk-working-\(item.id.uuidString)")
            if item.autoStarted == true { MobileDeskAutoStartedTag() }
            MobileDeskSourceLine(id: (item.task ?? item.id).uuidString, origin: item.origin, check: item.check, writeBack: writeBack)
            Button("Open", action: open)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("desk-working-open-\(item.id.uuidString)")
        }
        .deskCard()
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square", action: open)
            if let unlink { Button("Unlink Task", systemImage: "link", action: unlink) }
        }
    }
}

/// A session that finished and asks nothing: Mark Complete (or swipe it left) archives it into
/// Done; long-press for Open, Mark Complete and Silence (hidden until something new happens).
private struct DeskReadyCard: View {
    let item: Companion.DeskReady
    /// Side by side, a sideways drag scrolls the board instead: no swipe.
    var swipes = true
    let open: () -> Void
    let complete: () -> Void
    let silence: () -> Void
    var unlink: (() -> Void)? = nil
    var writeBack: (() -> Void)? = nil

    var body: some View {
        DeskSwipe(action: .complete, id: item.id.uuidString, enabled: swipes, perform: complete) { taps in card(taps) }
    }

    private func card(_ taps: DeskSwipeTaps) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: taps(open)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // The icon carries the color; the words stay readable in light mode.
                        Label { Text("Finished \(MobileDeskView.ago(item.finishedAt))").foregroundStyle(Color.metadata) } icon: {
                            Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        }
                        .font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let place = item.place, place != item.title { DeskPlaceTag(name: place) }
                    }
                    Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let task = item.taskText, ![item.title, item.subtitle].contains(task) { DeskTaskLine(text: task) }
                    Text(item.text).font(.subheadline).foregroundStyle(Color.metadata).lineLimit(3).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the session")
            .accessibilityAction(named: "Mark Complete", complete)
            .accessibilityAction(named: "Silence", silence)
            .accessibilityIdentifier("desk-ready-\(item.id.uuidString)")
            // What it made: links open in Safari; files and images are in the session.
            if let assets = item.assets, !assets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(assets, id: \.self) { asset in
                        Button(action: taps {
                            if let link = asset.url.flatMap(URL.init(string:)) { UIApplication.shared.open(link) } else { open() }
                        }) {
                            Label(asset.title, systemImage: asset.kind == "image" ? "photo" : asset.kind == "link" ? "link" : "doc")
                                .font(.subheadline).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .accessibilityIdentifier("desk-ready-assets-\(item.id.uuidString)")
            }
            if item.autoStarted == true { MobileDeskAutoStartedTag() }
            MobileDeskSourceLine(id: (item.task ?? item.id).uuidString, origin: item.origin, check: item.check,
                                 writeBack: writeBack, taps: { taps($0) })
            HStack(spacing: 8) {
                Button("Mark Complete", action: taps(complete))
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .accessibilityIdentifier("desk-complete-\(item.id.uuidString)")
                Button("Open", action: taps(open))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("desk-ready-open-\(item.id.uuidString)")
                Spacer(minLength: 0)
            }
        }
        .deskCard()
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square", action: open)
            Button("Mark Complete", systemImage: "checkmark.circle", action: complete)
            if let unlink { Button("Unlink Task", systemImage: "link", action: unlink) }
            Button("Silence", systemImage: "bell.slash", action: silence)
        }
    }
}

/// A session marked complete this week (archived): Reopen brings it back.
private struct DeskDoneCard: View {
    let item: Companion.DeskDone
    let busy: Bool
    let reopen: () -> Void
    var writeBack: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Completed \(MobileDeskView.ago(item.completedAt))", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.metadata).lineLimit(1)
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.metadata).lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(Color.metadata).lineLimit(1)
                }
                if let task = item.taskText, ![item.title, item.subtitle].contains(task) { DeskTaskLine(text: task) }
                if let place = item.place, place != item.title { DeskPlaceTag(name: place).padding(.top, 2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("desk-done-\(item.id.uuidString)")
            Button("Reopen", action: reopen)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityIdentifier("desk-reopen-\(item.id.uuidString)")
        }
        MobileDeskSourceLine(id: (item.task ?? item.id).uuidString, origin: item.origin, check: item.check, writeBack: writeBack)
        }
        .deskCard()
    }
}

/// Whether a card's button may act: not while it's swiped, nor as the swipe lets go (a
/// button under the finger would otherwise take the release as a tap).
final class DeskSwipeTaps {
    fileprivate var swiping = false
    fileprivate var open = false
    fileprivate var endedAt = Date.distantPast
    var allowed: Bool { !swiping && !open && Date().timeIntervalSince(endedAt) > 0.35 }
    /// The action, when a tap is a tap.
    func callAsFunction(_ action: @escaping () -> Void) -> () -> Void {
        { [weak self] in if self?.allowed ?? true { action() } }
    }
}

/// Swipe a card left to show its main action (Remove on To do, Silence on Needs you, Mark
/// Complete on Ready); a tap on it does it. Mark Complete also goes all the way across to do it,
/// as a list row's swipe actions do (the Desk is a scroll view of cards, not a list); Remove and
/// Silence never do. A tap on an
/// open card closes it. Only one column at a time (a phone): side by side, sideways drags
/// scroll the board.
private struct DeskSwipe<Content: View>: View {
    enum Action {
        case silence, complete, remove
        var title: String {
            switch self { case .silence: "Silence"; case .complete: "Complete"; case .remove: "Remove" }
        }
        var icon: String {
            switch self { case .silence: "bell.slash.fill"; case .complete: "checkmark.circle.fill"; case .remove: "trash.fill" }
        }
        var tint: Color {
            switch self { case .silence: .indigo; case .complete: .green; case .remove: .red }
        }
        /// The revealed button's identifier, before the card's id.
        var identifier: String {
            switch self { case .silence: "desk-silence-"; case .complete: "desk-swipe-complete-"; case .remove: "desk-swipe-remove-" }
        }
    }
    let action: Action
    let id: String
    /// Off: just the card (the long-press menu still has the action).
    var enabled = true
    /// All the way across does it, without a tap. Off for Silence: it takes something waiting off
    /// the Desk, so it needs the tap (and has Undo).
    var fullSwipe = true
    let perform: () -> Void
    @ViewBuilder let content: (DeskSwipeTaps) -> Content
    @State private var taps = DeskSwipeTaps()
    /// How far the card is moved left (negative), and where it rests (0 or open).
    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    /// Decided once per drag: sideways swipes the card, up and down scrolls.
    @State private var sideways: Bool?
    @State private var width: CGFloat = 0
    /// Past the point where letting go does it.
    @State private var armed = false
    /// How far an open card moves, and the space between it and the button.
    private let reveal: CGFloat = 96
    private let gap: CGFloat = 8
    private var commit: CGFloat { max(reveal + 70, width * 0.5) }

    @ViewBuilder var body: some View {
        if enabled { swipeable } else { content(taps) }
    }

    private var swipeable: some View {
        content(taps)
            .overlay {
                if resting < 0 { Color.clear.contentShape(Rectangle()).onTapGesture(perform: close) }
            }
            .offset(x: offset)
            .background(alignment: .trailing) { if offset < 0 { button } }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(drag)
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
    }

    private var button: some View {
        Button(action: now) {
            VStack(spacing: 4) {
                Image(systemName: action.icon).font(.title3)
                Text(action.title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: reveal - gap)
            .frame(width: max(reveal, -offset) - gap, alignment: armed ? .leading : .center)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(action.tint))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(action.identifier + id)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if sideways == nil { sideways = abs(value.translation.width) > abs(value.translation.height) * 1.2 }
                guard sideways == true else { return }
                taps.swiping = true
                // Without a full swipe, it stops a little past the button.
                let x = max(fullSwipe ? -.infinity : -(reveal + 36), min(0, resting + value.translation.width))
                offset = x
                armed = fullSwipe && -x > commit
            }
            .onEnded { value in
                defer { sideways = nil }
                guard sideways == true else { return }
                taps.swiping = false
                taps.endedAt = Date()
                let x = resting + value.translation.width
                if fullSwipe, -x > commit {
                    now()
                } else if -x > reveal / 2 || -(resting + value.predictedEndTranslation.width) > reveal {
                    withAnimation(.spring(duration: 0.25)) { offset = -reveal; resting = -reveal }
                    taps.open = true
                    armed = false
                } else {
                    close()
                }
            }
    }

    private func close() {
        withAnimation(.spring(duration: 0.25)) { offset = 0; resting = 0 }
        taps.open = false
        armed = false
    }

    /// Slides off, then goes; back in place if it's still here (it didn't go through).
    private func now() {
        withAnimation(.easeOut(duration: 0.2)) { offset = -(width + 40) }
        resting = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            perform()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { close() }
        }
    }
}

/// Work waiting to be placed: where the Desk proposes it goes, and why.
private struct DeskRequestCard: View {
    let request: Companion.DeskRequest
    let place: Companion.DeskPlace?
    /// Picked here from the place chip, instead of the Desk's proposal.
    let changed: Bool
    let busy: Bool
    /// Side by side, a sideways drag scrolls the board instead: no swipe.
    var swipes = true
    let start: () -> Void
    let change: () -> Void
    /// Takes it off the Desk (the service's ignore).
    let ignore: () -> Void
    /// Done outside Chatterbox: straight to Done, no thread.
    var markDone: (() -> Void)? = nil
    /// Link a thread already in its place; nil from a Mac older than tasks, or with no place.
    var link: (() -> Void)? = nil
    /// The card's offer to change its ClickUp task or draft the email reply.
    var writeBack: (() -> Void)? = nil

    private var source: String {
        switch request.source {
        case "you": "From you"
        case "claude": "From Claude"
        default: "From \(request.source.capitalized)"
        }
    }

    var body: some View {
        DeskSwipe(action: .remove, id: request.id.uuidString, enabled: swipes && !busy, fullSwipe: false, perform: ignore) { taps in card(taps) }
    }

    /// The card; its buttons go through `taps`, so letting go of a swipe doesn't press them.
    private func card(_ taps: DeskSwipeTaps) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.text)
                .font(.body).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(source) · \(request.createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(Color.metadata)
            if let confidence = request.confidence {
                MobileDeskConfidenceLine(confidence: confidence)
                    .accessibilityIdentifier("desk-confidence-\(request.id.uuidString)")
            }
            Button(action: taps(change)) {
                HStack(spacing: 6) {
                    Image(systemName: MobileDeskPlaces.icon(place))
                    Text(place?.name ?? "Choose a place").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(place == nil ? Color.metadata : Color.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(place == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(place.map { "Place: \($0.name)\(changed ? ", changed" : "")" } ?? "Choose a place")
            .accessibilityHint("Shows the Studios and projects it could go to")
            .accessibilityIdentifier("desk-place-\(request.id.uuidString)")
            if let note = request.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(Color.metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MobileDeskSourceLine(id: request.id.uuidString, origin: request.origin, check: request.check,
                                 writeBack: writeBack, taps: { taps($0) })
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working on it…").font(.footnote).foregroundStyle(Color.metadata)
                }
            } else {
                HStack(spacing: 8) {
                    startButton(taps)
                    if let link {
                        Button("Link\u{2026}", action: taps(link))
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Link a thread")
                            .accessibilityIdentifier("desk-link-\(request.id.uuidString)")
                    }
                    Spacer(minLength: 0)
                    if let markDone {
                        Button(action: taps(markDone)) { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Mark done")
                            .accessibilityHint("Done outside Chatterbox: moves it to Done without starting a thread")
                            .accessibilityIdentifier("desk-done-\(request.id.uuidString)")
                    }
                    removeButton(taps)
                }
            }
        }
        .deskCard()
    }

    // The place chip above changes the place; with none yet, Start asks for one first.
    private func startButton(_ taps: DeskSwipeTaps) -> some View {
        Button("Start", action: taps(start))
            .buttonStyle(.borderedProminent)
            .accessibilityHint(place == nil ? "Choose a place, then start" : "Choose the model, or continue a session already there")
            .accessibilityIdentifier("desk-start-\(request.id.uuidString)")
    }

    private func removeButton(_ taps: DeskSwipeTaps) -> some View {
        Button("Remove", action: taps(ignore))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.metadata)
            .accessibilityHint("Takes it off the Desk")
            .accessibilityIdentifier("desk-ignore-\(request.id.uuidString)")
    }
}

/// Start's step: where it goes (with Change), the model it runs on, and a session already
/// there doing the same work to continue instead (a clear match is chosen). The model shows
/// the chosen session's own (or a new session's there, as New Chat would start it) until one
/// is picked here; continuing on another switches that session to it. Start sends the
/// choice; nothing opens.
private struct MobileDeskStartSheet: View {
    let request: Companion.DeskRequest
    @State var place: Companion.DeskPlace
    /// A place picked here, for the card too.
    let changed: (Companion.DeskPlace) -> Void
    let start: (Companion.DeskStartRequest, String) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Sessions in the place like this work; nil while they load.
    @State private var threads: [Companion.DeskThread]?
    /// The session to continue; nil: a new one.
    @State private var continuing: UUID?
    /// The model shown: the choice's own, or with the picks made here.
    @State private var options: Companion.ChatOptions?
    /// The chosen session's own model (or a new session's), to tell a switch.
    @State private var base: Companion.ChatOptions?
    /// Picked here by hand; then choosing another session keeps them.
    @State private var picks = Companion.SettingsRequest()
    @State private var browsing: String?
    @State private var problem: String?
    @State private var changingPlace = false

    private var placeKey: String { "\(place.kind)|\(place.id?.uuidString ?? place.name)" }
    private var continued: Companion.DeskThread? { threads?.first { $0.id == continuing } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.text).lineLimit(4)
                    if let note = request.note, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Section("Place") {
                    HStack(spacing: 10) {
                        Image(systemName: MobileDeskPlaces.icon(place)).foregroundStyle(.secondary).frame(width: 22)
                        Text(place.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Change") { changingPlace = true }
                            .accessibilityIdentifier("desk-start-change-place")
                    }
                    .accessibilityIdentifier("desk-start-place")
                }
                modelSection
                threadSection
            }
            .tint(.blue)
            .navigationTitle("Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(continuing == nil ? "Start" : "Continue", action: begin)
                        .fontWeight(.semibold)
                        .disabled(threads == nil || blocked)
                        .accessibilityIdentifier("desk-start-confirm")
                }
            }
            .task(id: placeKey) { await load() }
            .onChange(of: continuing) { _, _ in Task { await follow() } }
            .sheet(isPresented: $changingPlace) {
                MobileDeskPlacePicker(current: place) { picked in
                    guard !MobileDeskPlaces.same(place, picked) else { return }
                    place = picked
                    changed(picked)
                }
                .environment(store)
            }
        }
        // Tall enough for the sessions to continue and the model, without scrolling.
        .presentationDetents([.large])
    }

    /// "Continue in" each session like this one, then a new session; nothing when there are none.
    @ViewBuilder private var threadSection: some View {
        if threads == nil {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for this work in \(place.name)\u{2026}").foregroundStyle(.secondary)
                }
            }
        } else if let threads, !threads.isEmpty {
            Section {
                ForEach(threads) { thread in
                    choice("Continue in \(thread.title)", detail: [thread.task.map { "Its task \u{201C}\($0)\u{201D} goes back to To do" },
                                                                    thread.isRunning ? "Working now; it goes next" : nil, thread.detail].compactMap { $0 }.joined(separator: " \u{00B7} "),
                           isOn: continuing == thread.id, id: "desk-thread-\(thread.id.uuidString)") { continuing = thread.id }
                }
                choice(newTitle, detail: newDetail, isOn: continuing == nil, id: "desk-thread-new") { continuing = nil }
            } header: {
                Text("Already in \(place.name)")
            } footer: {
                if let continued { Text(continueNote(continued)).accessibilityIdentifier("desk-start-continue-note") }
            }
        } else if place.kind == "project" {
            Section { Text(newDetail).font(.footnote).foregroundStyle(.secondary) }
                .accessibilityIdentifier("desk-start-work-thread")
        }
    }

    /// Starting new: in a project, a work thread of its session (plans/work-threads.md).
    private var newTitle: String { place.kind == "project" ? "New work thread for \(place.name)" : "New session" }
    private var newDetail: String {
        place.kind == "project" ? "A fresh thread in \(place.name); its result goes back to the project's session." : "In \(place.name)"
    }

    /// Picked here, and not what the chosen session (or a new one) runs on already.
    private var switching: Bool {
        guard !picks.isEmpty, let options, let base else { return false }
        return !options.sameModel(as: base)
    }

    /// What Continue does: the session's next message, on its model or switched to the one picked.
    private func continueNote(_ thread: Companion.DeskThread) -> String {
        let said = "It goes to that session as its next message"
        guard switching, let options else { return "\(said), on its own model (\(ChatSettingsLabels.chip(base) ?? thread.settings ?? "as it is"))." }
        if thread.isRunning, options.backend != base?.backend {
            return "\(said). It's working now, so its agent can change only once it's done."
        }
        return "\(said), switching it to \(ChatSettingsLabels.chip(options) ?? "the model picked")."
    }

    /// Continuing on another agent waits until the session's reply is done.
    private var blocked: Bool {
        guard let continued, continued.isRunning, switching, let options else { return false }
        return options.backend != base?.backend
    }

    private var modelSection: some View {
        Section {
            if let options {
                CompactModelPicker(options: options, browsing: $browsing) { change in
                    Task { await pick(change) }
                }
                // Effort in one row too, so the sessions below stay in view.
                if options.openModel == nil, let model = options.currentModel, !model.efforts.isEmpty {
                    Picker(selection: Binding(get: { options.effort.isEmpty ? model.defaultEffort ?? "" : options.effort }, set: { effort in
                        Task { await pick(.init(effort: effort)) }
                    })) {
                        ForEach(model.efforts, id: \.self) { Text(ChatSettingsLabels.effort($0)).tag($0) }
                    } label: {
                        Label("Effort", systemImage: "gauge.with.dots.needle.50percent")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("desk-start-effort")
                }
            } else if let problem {
                Text(problem).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading models\u{2026}").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Model")
        } footer: {
            if options?.openModel != nil { Text("Runs on the PC's graphics card, at medium effort.") }
        }
    }

    private func choice(_ title: String, detail: String, isOn: Bool, id: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(2)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if isOn { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }

    /// The place's sessions like this work, and the model; picks start over.
    private func load() async {
        picks = .init(); browsing = nil; options = nil; base = nil; threads = nil; continuing = nil
        // A new session's model while the sessions load; choosing a session follows it.
        async let models: Void = follow()
        // An older Mac offers none: a new session, as before.
        let found = (try? await store.deskThreads(request.id, place: place)) ?? []
        threads = found
        continuing = found.first { $0.match == "clear" }?.id
        await models
    }

    /// The chosen session's own model (or a new session's there): shown, unless one was picked here.
    private func follow() async {
        let target = continuing
        do {
            let own = try await fetch(.init(), chat: target)
            // Chosen again meanwhile: that one's answer counts.
            guard target == continuing else { return }
            base = own
            if picks.isEmpty { options = own }
            problem = nil
        } catch { if target == continuing { problem = error.localizedDescription } }
    }

    /// One change, as New Chat takes it, to what the choice would run on.
    private func pick(_ change: Companion.SettingsRequest) async {
        picks.add(change, backend: options?.backend)
        do { options = try await fetch(picks, chat: continuing); problem = nil } catch { problem = error.localizedDescription }
    }

    private func fetch(_ picks: Companion.SettingsRequest, chat: UUID?) async throws -> Companion.ChatOptions {
        let id = place.id
        return try await store.newChatOptions(picks, studio: place.kind == "studio" ? id : nil, project: place.kind == "project" ? id : nil, chat: chat)
    }

    private func begin() {
        var body = Companion.DeskStartRequest()
        // The place shown goes along when it isn't where the Desk proposed.
        if !MobileDeskPlaces.same(request.proposed, place) { body.place = place }
        if let continued {
            body.continueChat = continued.id
            // Its row said so: the task it carries goes back to To do.
            if continued.task != nil { body.replace = true }
        }
        // Only what was picked: otherwise it starts as a new session there would, or the
        // session continues on its own model. Continuing, the session switches to it.
        if !picks.isEmpty, let options {
            body.agent = options.backend
            if let open = options.openModel { body.openModel = open } else {
                body.model = options.model
                body.effort = options.effort.isEmpty ? nil : options.effort
            }
        }
        dismiss()
        start(body, continued?.title ?? place.name)
    }
}

/// The place chip's list: every Studio and project, with what belongs there.
private struct MobileDeskPlacePicker: View {
    let current: Companion.DeskPlace?
    let pick: (Companion.DeskPlace) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var places: [Companion.DeskPlace]?
    @State private var problem: String?
    @State private var search = ""

    private var groups: [(title: String, places: [Companion.DeskPlace])] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = (places ?? []).filter { place in
            words.allSatisfy { "\(place.name) \(place.detail ?? "")".localizedStandardContains($0) }
        }
        return [("Studios", "studio"), ("Projects", "project"), ("Other", nil)].compactMap { title, kind in
            let matching = shown.filter { place in kind.map { place.kind == $0 } ?? !["studio", "project"].contains(place.kind) }
            return matching.isEmpty ? nil : (title, matching)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if places == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading places…").foregroundStyle(.secondary) }
                } else if groups.isEmpty {
                    Text(search.isEmpty ? "No Studios or projects on the Mac yet." : "No places match.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.places, id: \.self) { place in row(place) }
                    }
                }
            }
            .navigationTitle("Choose a Place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search places")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { places = try await store.deskPlaces() }
                catch { problem = MobileDeskView.describe(error) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ place: Companion.DeskPlace) -> some View {
        Button { pick(place); dismiss() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: MobileDeskPlaces.icon(place)).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    if let detail = place.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                if MobileDeskPlaces.same(current, place) {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Current")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desk-place-option-\(place.name)")
    }
}

// MARK: - Tasks (plans/work-threads.md)

/// The task a card's thread carries, quietly.
private struct DeskTaskLine: View {
    let text: String
    var body: some View {
        Label { Text(text).lineLimit(2) } icon: { Image(systemName: "checklist") }
            .font(.footnote).foregroundStyle(Color.metadata)
    }
}

/// Link a thread (from a To do card): every thread already in the task's place, best matches
/// first; picking one links the task to it. One carrying another task asks first, since that
/// task goes back to To do.
private struct MobileDeskLinkSheet: View {
    let request: Companion.DeskRequest
    let place: Companion.DeskPlace
    let failed: (String) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var threads: [Companion.DeskThread]?
    @State private var confirming: Companion.DeskThread?
    @State private var linking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.text).lineLimit(3)
                } footer: {
                    Text("Pick the thread doing this. The task moves across the board with it.")
                }
                if let threads {
                    Section("In \(place.name)") {
                        if threads.isEmpty { Text("No threads there yet.").foregroundStyle(.secondary) }
                        ForEach(threads) { thread in
                            Button { pick(thread) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title).foregroundStyle(.primary).lineLimit(2)
                                    let detail = [thread.match == "clear" ? "Best match" : thread.match == "possible" ? "Similar work" : nil,
                                                  thread.task.map { "Has a task: \($0)" }, thread.isRunning ? "Working now" : nil].compactMap { $0 }
                                    if !detail.isEmpty { Text(detail.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(linking)
                            .accessibilityIdentifier("desk-link-thread-\(thread.id.uuidString)")
                        }
                    }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking in \(place.name)\u{2026}").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Link a Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { threads = (try? await store.deskAllThreads(request.id, place: place)) ?? [] }
            .alert("Link anyway?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { thread in
                Button("Link Anyway") { link(thread, replace: true) }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: { thread in
                Text("\u{201C}\(thread.title)\u{201D} already carries a task\(thread.task.map { ", \u{201C}\($0)\u{201D}" } ?? ""). Linking this one sends that back to To do.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ thread: Companion.DeskThread) {
        if thread.task != nil { confirming = thread } else { link(thread, replace: false) }
    }

    private func link(_ thread: Companion.DeskThread, replace: Bool) {
        linking = true
        Task {
            defer { linking = false }
            do {
                _ = try await store.linkDesk(request.id, to: thread.id, replace: replace)
                dismiss()
            } catch where error.localizedDescription.contains("already carries a task") {
                confirming = thread
            } catch {
                dismiss()
                failed(MobileDeskView.describe(error))
            }
        }
    }
}

/// Where a task came from (plans/source-linked-tasks.md): a ClickUp or email badge (a tap opens
/// the link), and in amber what disagrees with the board, with its offers: the change in the
/// source (an agent on the Mac makes it; nothing changes there without this tap) and moving
/// the task to match.
private struct MobileDeskSourceLine: View {
    let id: String
    let origin: Companion.DeskOrigin?
    let check: Companion.DeskOriginCheck?
    var matchLabel: String? = nil
    var match: (() -> Void)? = nil
    var writeBack: (() -> Void)? = nil
    var taps: (@escaping () -> Void) -> () -> Void = { $0 }

    var body: some View {
        if let origin {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: taps { origin.url.flatMap(URL.init(string:)).map { UIApplication.shared.open($0) } }) {
                    Label(Self.badge(origin), systemImage: origin.kind == "email" ? "envelope" : "checklist")
                        .font(.caption.weight(.medium)).foregroundStyle(Color.metadata)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .disabled(origin.url == nil)
                .accessibilityIdentifier("desk-source-\(id)")
                if let check {
                    Label(check.warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Color.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("desk-source-warning-\(id)")
                    HStack(spacing: 8) {
                        if let offer = check.writeBack, let writeBack {
                            Button(offer, action: taps(writeBack))
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityHint("Asks an agent on the Mac to do this. Nothing changes until it does; an email is only drafted.")
                                .accessibilityIdentifier("desk-write-back-\(id)")
                        }
                        if check.match == "done", let match, let matchLabel {
                            Button(matchLabel, action: taps(match))
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("desk-source-match-\(id)")
                        }
                    }
                }
            }
        }
    }

    /// "ClickUp · In progress · Camp schedule", "Email · New reply from Lauren".
    static func badge(_ origin: Companion.DeskOrigin) -> String {
        var parts = [origin.kind == "email" ? "Email" : "ClickUp"]
        if let status = origin.status, !status.isEmpty {
            let shown = status.prefix(1).uppercased() + status.dropFirst()
            parts.append(origin.kind == "email" && status.lowercased() == "new reply" ? shown + (origin.replyFrom.map { " from " + $0 } ?? "") : shown)
        }
        if let title = origin.title, !title.isEmpty { parts.append(title) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The rubric's answer on a To do card (plans/desk-confidence.md).
private struct MobileDeskConfidenceLine: View {
    let confidence: Companion.DeskConfidence

    var body: some View {
        Label {
            Text(confidence.canRunAlone ? "Can run without you" : "Needs you").fontWeight(.semibold)
                + Text(" \u{00B7} " + confidence.reason)
        } icon: {
            Image(systemName: confidence.canRunAlone ? "checkmark.seal.fill" : "person.fill.questionmark")
                .foregroundStyle(confidence.canRunAlone ? Color.green : Color.attention)
        }
        .font(.footnote)
        .foregroundStyle(Color.metadata)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// On a card whose task started by itself because it scored Yes.
private struct MobileDeskAutoStartedTag: View {
    var body: some View {
        Label("Started automatically", systemImage: "bolt.fill")
            .font(.caption.weight(.medium)).foregroundStyle(Color.metadata)
    }
}
