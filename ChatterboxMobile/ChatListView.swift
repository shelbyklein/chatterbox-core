import SwiftUI

/// The Mac's chats on three pages, like the Mac's Home: Projects, Studios, and other Chats.
/// On iPad the open chat sits beside them; on iPhone it opens over them.
struct ChatListView: View {
    enum Page: String, CaseIterable, Identifiable {
        /// In this order in the tab bar. Activity: live sessions and unread replies. All:
        /// every session at once, newest first.
        case activity, projects, studios, chats, all
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .all: "tray.full"
            case .activity: "waveform.path"
            case .projects: "apps.iphone"
            case .studios: "paintpalette"
            case .chats: "bubble.left.and.bubble.right"
            }
        }
        /// The one kind of group the page lists (All and Activity list every kind).
        var kind: Companion.ChatGroup.Kind { self == .projects ? .projects : self == .studios ? .studio : .chats }
        func includes(_ kind: Companion.ChatGroup.Kind) -> Bool { self == .all || self == .activity || kind == self.kind }
        /// The tab a session of this kind lives on (Pinned and All list every kind).
        static func home(for kind: Companion.ChatGroup.Kind?) -> Page { kind == .projects ? .projects : kind == .studio ? .studios : .chats }
    }
    /// Set when the list is one of the home's bottom tabs: only that page, no page switcher.
    var fixedPage: Page? = nil
    /// Whether this tab is the one on screen: only that one opens a tapped notification's chat.
    var isSelected = true
    /// Pages this tab switches between (Chats and All), and the one shown.
    var scopes: [Page] = []
    var scope: Binding<String>? = nil
    @Environment(MobileStore.self) private var store
    /// List rows, or cards two to a row.
    @AppStorage("mobileChatListCards") private var showsCards = false
    @AppStorage("mobileStudioListMode") private var studioListMode = false
    /// How each page orders its threads. Recent is the Mac's order (latest first).
    enum Sort: String, CaseIterable, Identifiable {
        case recent, name, active, tag
        var id: String { rawValue }
        var title: String { switch self { case .recent: "Recent"; case .name: "Name"; case .active: "Most Active"; case .tag: "By Tag" } }
        var icon: String { switch self { case .recent: "clock"; case .name: "textformat"; case .active: "flame"; case .tag: "tag" } }
    }
    @AppStorage("mobileChatListSort") private var sortName = Sort.recent.rawValue
    private var sort: Sort { Sort(rawValue: sortName) ?? .recent }
    @AppStorage("mobileChatListPage") private var pageName = Page.projects.rawValue
    private var page: Page { fixedPage ?? Page(rawValue: pageName) ?? .projects }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Settings: Notifications, Appearance and Unpair, in one sheet.
    @State private var showingSettings = false
    @State private var showingAutomations = false
    /// A run's session picked in Automations: opened once the sheet has closed.
    @State private var automationPick: UUID?
    @State private var startingNewChat = false
    @State private var newChatStudio: UUID?
    @State private var selection: UUID?
    /// The chat that's open, kept if it drops out of the list (archived on the Mac).
    @State private var opened: Companion.ChatSummary?
    /// Requests outlive transient detail views during split-view navigation.
    @State private var history: MobileChatHistory?
    /// The active fold in this list's coordinates; nil while the device is flat.
    @State private var division: CGRect?
    /// Native collapse/navigation state is used only by the closed-phone layout.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var search = ""
    /// The Studio whose instructions are open.
    @State private var editingStudio: Companion.ChatGroup?
    @State private var selectedStudioID: String?
    @State private var renaming: Companion.ChatSummary?
    @State private var promoting: ChatPromotionTarget?
    @State private var newTitle = ""
    @State private var managementError: String?
    @State private var showingArchived = false
    /// The archived session picked in Archived, opened once its sheet closes.
    @State private var archivedPick: Companion.ChatSummary?
    /// Wide (an iPad, an open iPhone Duo): About this thread is a column on the right, beside the
    /// conversation, opened from the About button on the session's bar (or its title).
    @State private var aboutColumn = MobileAboutColumn()
    /// The thread peeked at in that column, kept current like the open one.
    @State private var peekHistory: MobileChatHistory?

    var body: some View {
        GeometryReader { geometry in
            let split = verticalDivision(in: geometry.size)
            if sizeClass == .regular || split != nil {
              // Upright with no fold between two panes (an open Duo in portrait): the list is
              // a shelf over the conversation, which gets the whole width.
              // The whole screen's shape, keyboard included: measured by the safe area alone, the
              // keyboard coming up made an upright screen look wide, the layout switched under
              // the message box, and the keyboard went away again.
              let insets = geometry.safeAreaInsets
              let shelf = split == nil && geometry.size.height + insets.top + insets.bottom > geometry.size.width + insets.leading + insets.trailing
              Group {
               if shelf {
                listShelf(geometry.size)
               } else {
                let listWidth = split?.minX ?? min(380, max(300, geometry.size.width * 0.38))
                HStack(spacing: 0) {
                    NavigationStack { configuredSidebar.background(SafeAreaToOwnFrame().allowsHitTesting(false)) }
                        .accessibilityIdentifier("session-sidebar-pane")
                        .frame(width: listWidth)
                    if let split {
                        Color(uiColor: .systemBackground).frame(width: split.width)
                            .accessibilityHidden(true)
                    } else {
                        Divider()
                    }
                    conversationAndAbout(width: geometry.size.width - listWidth - (split?.width ?? 1))
                }
                // Unlike NavigationSplitView, these panes never offer a collapse button
                // or hide the sidebar when the user opens a conversation.
               }
              }
              .onChange(of: shelf, initial: true) {
                  aboutColumn.listShelf = shelf
                  // With no session open the list starts out, so the screen isn't empty.
                  if shelf, selectedChat == nil { aboutColumn.listShown = true }
              }
            } else {
                NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
                    configuredSidebar
                        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .background { SessionDivisionProbe(division: $division).allowsHitTesting(false) }
        .sheet(isPresented: $showingAutomations, onDismiss: {
            if let id = automationPick { automationPick = nil; MobilePushNotifications.shared.pendingChat = id }
        }) { MobileAutomationsView { automationPick = $0 }.environment(store) }
        .sheet(isPresented: $startingNewChat) {
            MobileNewChatSheet(studios: newChatStudios, start: { open($0.summary) }, studio: newChatStudio).environment(store)
        }
        .sheet(isPresented: $showingSettings) { MobileSettingsSheet().environment(store) }
        .sheet(isPresented: $showingArchived, onDismiss: {
            if let chat = archivedPick { archivedPick = nil; open(chat) }
        }) { MobileArchivedSheet { archivedPick = $0 }.environment(store) }
        .task(id: "\(MobilePushNotifications.shared.pendingChat?.uuidString ?? "")|\(scenePhase)|\(fixedPage?.rawValue ?? "")|\(isSelected)") {
            guard let id = MobilePushNotifications.shared.pendingChat, fixedPage == nil || isSelected else { return }
            await store.loadChats()
            guard !Task.isCancelled, MobilePushNotifications.shared.pendingChat == id else { return }
            if let fixedPage {
                // The tab on screen opens it when it's the chat's own tab (ChatterboxTabs goes
                // there), or All, which lists every chat.
                let kind = store.chatList?.groups.first { $0.chats.contains { $0.id == id } }?.kind
                guard fixedPage == .all || fixedPage == .activity || fixedPage == Page.home(for: kind) else { return }
            }
            if let chat = allChats.first(where: { $0.id == id }) {
                open(chat); MobilePushNotifications.shared.pendingChat = nil
            } else if let result = try? await store.detail(id, since: nil), case .detail(let detail) = result {
                open(detail.summary); MobilePushNotifications.shared.pendingChat = nil
            }
        }
        .sheet(item: $promoting) { target in
            ChatPromotionSheet(target: target) { result in open(result.summary); history?.apply(result) }
        }
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { chat in
            TextField("Name", text: $newTitle)
            Button("Rename") { rename(chat, to: newTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Couldn't rename session", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("OK", role: .cancel) { managementError = nil }
        } message: { Text(managementError ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                history?.refresh(in: store, force: true)
                Task { await MobilePushNotifications.shared.refreshPermission() }
            }
        }
        // Keep request ownership in the stable navigation parent. A detail view can
        // appear without its lifecycle tasks restarting after Back or a column change.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if selection != nil { await history?.refresh(in: store).value }
                do { try await Task.sleep(for: .seconds(history?.detail?.summary.isRunning == true ? 1.2 : 4)) }
                catch { return }
            }
        }
        // Keeps the list current while it's on screen.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.loadChats()
                #if DEBUG
                // Simulator tests: open the first chat.
                if selection == nil, ProcessInfo.processInfo.environment["CHATTERBOX_TEST_OPEN"] != nil,
                   let first = allChats.first { open(first) }
                #endif
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Upright and wide: the conversation across the whole width, and the session list as a
    /// shelf that slides in from the left over it (the button at the chat's top left, or a
    /// swipe in from the left edge). Picking a session, a tap outside it or a swipe left there
    /// puts it away, with or without a session open.
    private func listShelf(_ size: CGSize) -> some View {
        let listWidth = min(380, max(300, size.width * 0.6))
        let shown = aboutColumn.listShown
        func close() { withAnimation(.snappy(duration: 0.25)) { aboutColumn.listShown = false } }
        return ZStack(alignment: .leading) {
            conversationAndAbout(width: size.width)
            // A swipe in from the left edge brings the list out.
            Color.clear.frame(width: 18).frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                    if drag.translation.width > 30 { withAnimation(.snappy(duration: 0.25)) { aboutColumn.listShown = true } }
                })
                .accessibilityHidden(true)
            if shown {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .gesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.width < -30 { close() } })
                    .transition(.opacity)
                    .accessibilityIdentifier("list-shelf-dismiss")
            }
            // Made when it comes out, not slid in from off screen: a list laid out off screen
            // (Activity's) came in blank. Its search is kept; its scroll starts at the top.
            // No SafeAreaToOwnFrame here: measured while sliding in from off screen, it trimmed
            // the list's insets to that position and pushed its content out of sight. The
            // shelf is always at the screen's left edge, where the window's insets fit as is.
            if shown {
                NavigationStack { configuredSidebar }
                    .accessibilityIdentifier("session-sidebar-pane")
                    .frame(width: listWidth)
                    .background(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.3), radius: 14)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.25), value: shown)
    }

    /// The open session, with About (or a peek) sliding in on its right: beside it when there's
    /// room for both, over its right side when not (one screen of an open Duo).
    private func conversationAndAbout(width: CGFloat) -> some View {
        let chat = aboutColumn.isOpen ? selectedChat : nil
        let columnWidth: CGFloat = aboutColumn.peek == nil ? 340 : 420
        let docked = width - columnWidth - 1 >= 360
        return HStack(spacing: 0) {
            NavigationStack { detail.environment(aboutColumn) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("session-detail-pane")
            if let chat, docked {
                Divider()
                rightColumn(chat).frame(width: columnWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .trailing) {
            if let chat, !docked {
                // Under the conversation's bar, so its buttons (About, Session Settings, •••)
                // stay in reach while About covers the rest.
                rightColumn(chat).frame(width: min(columnWidth, width - 24))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14))
                    .shadow(color: .black.opacity(0.25), radius: 12)
                    .padding(.top, Self.conversationBarHeight)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.25), value: aboutColumn.isOpen)
        .animation(.snappy(duration: 0.25), value: aboutColumn.peek?.id)
        .onChange(of: selection) { aboutColumn.peek = nil }
        .onChange(of: aboutColumn.peek?.id) { _, id in
            if let id { if peekHistory?.id != id { peekHistory?.cancel(); peekHistory = MobileChatHistory(id: id) }; peekHistory?.refresh(in: store, force: true) }
            else { peekHistory?.cancel(); peekHistory = nil }
        }
        // A peek stays live while it's shown.
        .task(id: "\(aboutColumn.peek?.id.uuidString ?? "")|\(scenePhase)") {
            guard aboutColumn.peek != nil, scenePhase == .active else { return }
            while !Task.isCancelled {
                await peekHistory?.refresh(in: store).value
                do { try await Task.sleep(for: .seconds(peekHistory?.detail?.summary.isRunning == true ? 1.2 : 4)) } catch { return }
            }
        }
    }

    /// The height of a session's navigation bar, which a slid-over column leaves uncovered.
    static let conversationBarHeight: CGFloat = 54

    /// The right-hand column: a peeked thread, or About.
    @ViewBuilder private func rightColumn(_ chat: Companion.ChatSummary) -> some View {
        Group {
            if let peek = aboutColumn.peek, let peekHistory, peekHistory.id == peek.id {
                NavigationStack {
                    ChatDetailView(chat: peek, open: open, history: peekHistory, closeChat: { aboutColumn.peek = nil })
                        .id(peek.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { aboutColumn.peek = nil } label: { Label("About", systemImage: "chevron.backward") }
                                    .accessibilityIdentifier("peek-back")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { let full = peek; aboutColumn.peek = nil; open(full) } label: {
                                    Label("Open in Full", systemImage: "arrow.up.left.and.arrow.down.right")
                                }
                                .accessibilityIdentifier("peek-open-full")
                            }
                        }
                }
                .accessibilityIdentifier("peekColumn")
            } else {
                NavigationStack { aboutColumnContent(chat) }
                    .accessibilityIdentifier("aboutColumn")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .background(SafeAreaToOwnFrame().allowsHitTesting(false))
    }

    /// Shared list controls; only the surrounding navigation changes on a closed phone. The bar
    /// holds the list's tools (•••, Feedback, New Chat); an open session's bar holds its own.
    private var configuredSidebar: some View {
        sidebar
            .safeAreaInset(edge: .top, spacing: 0) {
                if fixedPage == nil { pagePicker } else if scopes.count > 1, scope != nil { scopePicker }
            }
            .navigationTitle(fixedPage?.title ?? store.connection?.macName ?? "Chatterbox")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.loadChats() }
            // Wide, the sidebar's own search spans the column; the bar's drawer stopped short of it.
            .searchable(text: $search, placement: sizeClass == .regular ? .sidebar : .navigationBarDrawer(displayMode: .always), prompt: fixedPage.map { "Search \($0.title)" } ?? "Search sessions")
            .sheet(item: $editingStudio) { group in
                if let id = group.studioID {
                    StudioInstructionsEditor(title: group.title, studio: id, initial: group.instructions ?? "")
                }
            }
            .toolbar {
                if page == .studios {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            connectionItems
                            Picker("Sort", selection: $sortName) {
                                ForEach(Sort.allCases.filter { $0 != .tag }) { Text($0.title).tag($0.rawValue) }
                            }
                            Button { withAnimation { studioListMode.toggle() } } label: {
                                Label(studioListMode ? "Show as Cards" : "Show as List", systemImage: studioListMode ? "square.grid.2x2" : "list.bullet")
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("Studio options")
                    }
                } else {
                    // Sort and layout live in the menu, so the bar keeps to three buttons:
                    // on a closed iPhone Duo it runs down the side, and more would push
                    // New Chat into an overflow menu.
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            connectionItems
                            if page != .activity {
                            Picker("Sort", selection: Binding(get: { sort }, set: { new in withAnimation(.easeOut(duration: 0.2)) { sortName = new.rawValue } })) {
                                ForEach(Sort.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                            }
                            }
                            Button { withAnimation(.easeOut(duration: 0.2)) { showsCards.toggle() } } label: {
                                Label(showsCards ? "Show as List" : "Show as Cards", systemImage: showsCards ? "list.bullet" : "square.grid.2x2")
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("Connection")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { FeedbackButton() }
                // New Chat beside the title, in the title's own place: on a closed iPhone Duo
                // every bar button (leading or trailing) runs down the side rail, leaving the
                // title row empty; this one stays up top, by the page's name.
                // The name is a control of its own that does nothing: with New Chat the only
                // control in the item, iOS made the whole item New Chat, name included.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Button {} label: {
                            Text(fixedPage?.title ?? store.connection?.macName ?? "Chatterbox").font(.headline).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityRemoveTraits(.isButton).accessibilityAddTraits(.isHeader)
                        newChatMenu
                    }
                }
            }
    }

    /// The reserved division is expressed in the probe's coordinates, matching this view.
    /// Horizontal laptop folds keep the ordinary side-by-side session layout.
    private func verticalDivision(in size: CGSize) -> CGRect? {
        guard let division, division.height > division.width,
              division.minX > 0, division.maxX < size.width else { return nil }
        return division
    }

    /// iPad's sidebar style beside the chat; the iPhone's grouped list on its own.
    @ViewBuilder
    private var sidebar: some View {
        if page == .activity {
            activityPage
        } else if page == .studios {
            studioWorkspace
        } else if showsCards {
            chatCards
        } else if sizeClass == .regular {
            // Each family is a section of its own: compact spacing keeps them close.
            chatList.listStyle(.sidebar).listSectionSpacing(.compact)
        } else {
            // As the card view: each family a 14 pt rounded block, 16 pt from the edges and 10 pt
            // apart. A plain list with the blocks drawn per row (rowShape), since a grouped
            // list clips them to iOS's own, larger rounding.
            chatList.listStyle(.plain).scrollContentBackground(.hidden).background(Color(uiColor: .systemGroupedBackground))
        }
    }

    /// Activity is a destination of its own; opening a row uses this page's same detail pane.
    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            loadingStatus.padding(.horizontal, 16)
            if let problem = store.problem {
                MobileProblemCard(problem, updated: store.chatsUpdatedAt) { await store.loadChats() }
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let list = store.chatList {
                MobileNewReplies(activity: list.activity ?? [], chats: allChats, summary: summary(for:), open: open,
                                 rename: beginRename, dedicated: true, query: search, cards: showsCards)
            } else { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("activity-page")
    }

    /// The page's groups; a search looks through every page.
    private var groups: [Companion.ChatGroup] {
        let all = store.chatList?.groups ?? []
        // A tab searches its own page; the switcher's search looks through every page.
        let everyChat = all.flatMap(\.chats)
        // Sidequests are shown with the chat that started them, not as chats of their own.
        let lists = all.map { group in
            var group = group
            group.chats = group.chats.filter { !MobileSidequests.listedWithParent($0, in: everyChat) }
            return group
        }
        let shown = filtered(search.isEmpty || fixedPage != nil ? lists.filter { page.includes($0.kind) } : lists)
                return sorted(page == .all ? Self.mixed(shown) : shown)
    }

    /// Pinned's one list: the Mac's pinned sessions, in the Mac's order.
    static func pinned(_ groups: [Companion.ChatGroup]) -> [Companion.ChatGroup] {
        let chats = groups.flatMap(\.chats).filter { $0.pinnedRank != nil }.sorted { ($0.pinnedRank ?? 0) < ($1.pinnedRank ?? 0) }
        return chats.isEmpty ? [] : [Companion.ChatGroup(id: "pinned", kind: .chats, title: "Pinned", chats: chats)]
    }

    /// All's one list: every page's sessions together, newest first, each project's or chat's
    /// worktrees and sidechats still right after it.
    static func mixed(_ groups: [Companion.ChatGroup]) -> [Companion.ChatGroup] {
        var families: [[Companion.ChatSummary]] = []
        for group in groups {
            for chat in group.chats {
                if (chat.worktreeBranch != nil || chat.sidechatOf != nil || chat.workOf != nil), group.chats.first?.id != chat.id, !families.isEmpty { families[families.count - 1].append(chat) }
                else { families.append([chat]) }
            }
        }
        let chats = families.sorted { a, b in a.map(\.updatedAt).max()! > b.map(\.updatedAt).max()! }.flatMap { $0 }
        return chats.isEmpty ? [] : [Companion.ChatGroup(id: "all", kind: .chats, title: "All Sessions", chats: chats)]
    }

    /// Studio sessions keep their picture on the All page's cards.
    private var studioChatIDs: Set<UUID> {
        Set((store.chatList?.groups ?? []).filter { $0.kind == .studio }.flatMap(\.chats).map(\.id))
    }

    /// The groups in the chosen order. A project's worktrees and sidechats, listed right after
    /// it, move with it. By Tag regroups projects under each of their tags, untagged last.
    private func sorted(_ groups: [Companion.ChatGroup]) -> [Companion.ChatGroup] {
        guard sort != .recent else { return groups }
        func families(_ chats: [Companion.ChatSummary]) -> [[Companion.ChatSummary]] {
            var result: [[Companion.ChatSummary]] = []
            for chat in chats {
                if (chat.worktreeBranch != nil || chat.sidechatOf != nil || chat.workOf != nil), !result.isEmpty { result[result.count - 1].append(chat) }
                else { result.append([chat]) }
            }
            return result
        }
        func ordered(_ chats: [Companion.ChatSummary]) -> [Companion.ChatSummary] {
            families(chats).sorted { a, b in
                let x = a[0], y = b[0]
                switch sort {
                case .active:
                    let ka = (x.turnsToday ?? 0, x.turnsThisWeek ?? 0, x.turnsPerDay ?? 0)
                    let kb = (y.turnsToday ?? 0, y.turnsThisWeek ?? 0, y.turnsPerDay ?? 0)
                    if ka != kb { return ka > kb }
                    return x.updatedAt > y.updatedAt
                default:
                    return (x.project ?? x.title).localizedStandardCompare(y.project ?? y.title) == .orderedAscending
                }
            }.flatMap { $0 }
        }
        guard sort == .tag else {
            return groups.map { var group = $0; group.chats = ordered(group.chats); return group }
        }
        return groups.flatMap { group -> [Companion.ChatGroup] in
            let all = families(group.chats)
            let tags = Set(all.flatMap { $0[0].tags ?? [] }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !tags.isEmpty else { var plain = group; plain.chats = ordered(group.chats); return [plain] }
            var result = tags.map { tag in
                Companion.ChatGroup(id: "\(group.id)-tag-\(tag)", kind: group.kind, title: tag,
                                    chats: ordered(all.filter { $0[0].tags?.contains(tag) == true }.flatMap { $0 }))
            }
            let untagged = all.filter { ($0[0].tags ?? []).isEmpty }.flatMap { $0 }
            if !untagged.isEmpty { result.append(Companion.ChatGroup(id: "\(group.id)-untagged", kind: group.kind, title: "No Tag", chats: ordered(untagged))) }
            return result
        }
    }

    /// "12 turns today", shown on each thread while sorting by activity.
    static func activityLine(_ chat: Companion.ChatSummary) -> String? {
        if let day = chat.turnsToday, day > 0 { return "\(day) turn\(day == 1 ? "" : "s") today" }
        if let week = chat.turnsThisWeek, week > 0 { return "\(week) this week" }
        if let rate = chat.turnsPerDay, rate > 0 { return rate >= 1 ? "about \(Int(rate.rounded())) a day" : "less than 1 a day" }
        return nil
    }

    /// Each Studio is named; the Projects and Chats pages are their own heading, except in a search.
    private func showsHeader(_ group: Companion.ChatGroup) -> Bool {
        group.id != "all" && (group.kind == .studio || page == .all || sort == .tag || (!search.isEmpty && fixedPage == nil))
    }

    private func waiting(on page: Page) -> Int {
        (store.chatList?.groups ?? []).filter { page.includes($0.kind) }.flatMap(\.chats).filter(\.isWaitingOnYou).count
    }

    /// Projects · Studios · Chats, with a count of chats waiting on you on each.
    private var pagePicker: some View {
        Picker("Page", selection: Binding(get: { page }, set: { new in withAnimation(.easeOut(duration: 0.2)) { pageName = new.rawValue } })) {
            ForEach(Page.allCases) { page in
                let count = waiting(on: page)
                Text(count > 0 ? "\(page.title) \(count)" : page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("home-pages")
    }

    /// Chats · All, on the Chats tab (the Desk took All's place in the tab bar).
    private var scopePicker: some View {
        Picker("Show", selection: Binding(get: { page }, set: { new in withAnimation(.easeOut(duration: 0.2)) { scope?.wrappedValue = new.rawValue } })) {
            ForEach(scopes) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("tab-scopes")
    }

    /// Nothing on this page (or nothing found).
    @ViewBuilder
    private var emptyPage: some View {
        if store.chatList != nil, groups.isEmpty {
            if search.isEmpty {
                ContentUnavailableView(page == .all ? "No Sessions" : "No \(page.title)", systemImage: page.icon,
                                       description: Text(page == .all ? "Projects, Studios and sessions from the Mac show up here." : page == .studios ? "Studios you make on the Mac show up here." :
                                                         page == .projects ? "Projects you open on the Mac show up here." :
                                                         "Chats outside a project or Studio show up here."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    /// The same chats as the list, as cards two to a row under the same headings.
    /// A narrow iPad sidebar uses one readable card rather than squeezing two phone cards.
    /// Two to a row: the list is a phone's width, or a sidebar beside the session (about
    /// 330 points on a flat iPhone Duo, too narrow for 160-point cards to pair up).
    private var cardColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    @ViewBuilder
    private var loadingStatus: some View {
        if !store.hasRefreshedChats, store.problem == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(store.chatList == nil ? "Connecting to \(store.connection?.macName ?? "your Mac")…" : "Updating saved sessions…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("session-load-status")
        }
    }

    private var chatCards: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                loadingStatus
                if let problem = store.problem { MobileProblemCard(problem, updated: store.chatsUpdatedAt) { await store.loadChats() } }
                if let list = store.chatList {
                    if search.isEmpty, let pins = list.pins, !pins.isEmpty { MobilePinPills(pins: pins) }
                    emptyPage
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if showsHeader(group) { header(group).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
                            ForEach(Self.cardSegments(group.chats)) { segment in
                                switch segment {
                                case .grid(let chats):
                                    LazyVGrid(columns: cardColumns, spacing: 10) {
                                        ForEach(chats) { chat in card(chat) }
                                    }
                                case .family(let parent, let children):
                                    familyCard(parent, children)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func card(_ chat: Companion.ChatSummary, embedded: Bool = false) -> some View {
        ChatCard(chat: chat, showsThumbnail: page == .studios || (page == .all && studioChatIDs.contains(chat.id)), selected: sizeClass == .regular && selection == chat.id,
                 activity: sort == .active ? Self.activityLine(chat) : nil, embedded: embedded) { open(chat) }
            .contextMenu { chatActions(chat) }
    }

    /// A session with its Sidechats and work threads: one card the width of the page, the
    /// session on top and each of them a row inside it.
    private func familyCard(_ parent: Companion.ChatSummary, _ children: [Companion.ChatSummary]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let selected = sizeClass == .regular && selection == parent.id
        let visible = MobileFamilyExpansion.shared.visible(children, of: parent.id)
        return VStack(alignment: .leading, spacing: 0) {
            card(parent, embedded: true)
            ForEach(visible.shown) { child in
                Divider().padding(.leading, 12)
                NestedChatRow(chat: child, parent: parent, selected: sizeClass == .regular && selection == child.id) { open(child) }
                    .contextMenu { chatActions(child) }
            }
            if let toggle = familyToggle(parent, hidden: visible.hidden) {
                Divider().padding(.leading, 12)
                toggle.padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
        .background(shape.fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(shape.strokeBorder(parent.isWaitingOnYou ? Color.yellow.opacity(0.6) : selected ? Color.accentColor : Color.primary.opacity(0.06),
                                    lineWidth: parent.isWaitingOnYou || selected ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("family-\(parent.id.uuidString)")
    }

    /// "Show N more" under a family's first children, "Show less" once it's open.
    private func familyToggle(_ parent: Companion.ChatSummary, hidden: Int) -> AnyView? {
        let expansion = MobileFamilyExpansion.shared
        let open = expansion.ids.contains(parent.id)
        guard hidden > 0 || open else { return nil }
        return AnyView(Button {
            withAnimation(.easeOut(duration: 0.2)) { expansion.toggle(parent.id) }
        } label: {
            Text(open ? "Show less" : "Show \(hidden) more").font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("family-toggle-\(parent.id.uuidString)"))
    }

    /// A group's chats as families: each top-level chat with the Sidechats and work threads
    /// listed under it (list mode puts each family in a card of its own).
    struct Family: Identifiable {
        let parent: Companion.ChatSummary
        let children: [Companion.ChatSummary]
        var first = false
        var id: UUID { parent.id }
    }
    static func families(_ chats: [Companion.ChatSummary]) -> [Family] {
        let ids = Set(chats.map(\.id))
        var children: [UUID: [Companion.ChatSummary]] = [:]
        for chat in chats { if let parent = nestingParent(chat, in: ids) { children[parent, default: []].append(chat) } }
        return chats.filter { nestingParent($0, in: ids) == nil }.enumerated().map { Family(parent: $1, children: children[$1.id] ?? [], first: $0 == 0) }
    }

    /// Cards in a group's order: a run of plain cards goes two to a row; a session whose
    /// Sidechats or work threads are listed in the group becomes one card holding them.
    enum CardSegment: Identifiable {
        case grid([Companion.ChatSummary])
        case family(Companion.ChatSummary, [Companion.ChatSummary])
        var id: UUID {
            switch self {
            case .grid(let chats): chats[0].id
            case .family(let parent, _): parent.id
            }
        }
    }

    /// The parent a chat sits inside, when that parent is in `chats`: Sidechats and work
    /// threads (worktrees keep cards of their own).
    static func nestingParent(_ chat: Companion.ChatSummary, in ids: Set<UUID>) -> UUID? {
        guard chat.worktreeBranch == nil, let parent = chat.workOf ?? chat.sidechatOf, parent != chat.id, ids.contains(parent) else { return nil }
        return parent
    }

    static func cardSegments(_ chats: [Companion.ChatSummary]) -> [CardSegment] {
        let ids = Set(chats.map(\.id))
        var children: [UUID: [Companion.ChatSummary]] = [:]
        for chat in chats { if let parent = nestingParent(chat, in: ids) { children[parent, default: []].append(chat) } }
        var segments: [CardSegment] = [], run: [Companion.ChatSummary] = []
        for chat in chats where nestingParent(chat, in: ids) == nil {
            if let nested = children[chat.id] {
                if !run.isEmpty { segments.append(.grid(run)); run = [] }
                segments.append(.family(chat, nested))
            } else { run.append(chat) }
        }
        if !run.isEmpty { segments.append(.grid(run)) }
        return segments
    }

    /// Studios keep their own workspace selected; search can still find any Studio chat.
    private var studioGroups: [Companion.ChatGroup] {
        let all = (store.chatList?.groups ?? []).filter { $0.kind == .studio }
        // Tag sorting belongs to Projects; keep Studio identity and instructions intact.
        return sort == .tag ? filtered(all) : sorted(filtered(all))
    }

    /// A search shows every Studio's matches; otherwise the Studio you opened, or none (the
    /// Studios themselves show first).
    private var visibleStudios: [Companion.ChatGroup] {
        if !search.isEmpty { return studioGroups }
        return studioGroups.first { $0.id == selectedStudioID }.map { [$0] } ?? []
    }

    /// Every Studio as a card, to open one.
    private var studioIndex: some View {
        LazyVGrid(columns: cardColumns, spacing: 12) {
            ForEach(studioGroups) { group in
                StudioIndexCard(group: group) { withAnimation(.easeOut(duration: 0.2)) { selectedStudioID = group.id } }
            }
        }
    }

    private var studioWorkspace: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                loadingStatus
                if let problem = store.problem { MobileProblemCard(problem, updated: store.chatsUpdatedAt) { await store.loadChats() } }
                if let list = store.chatList {
                    if search.isEmpty {
                        if visibleStudios.isEmpty { studioIndex }
                        else {
                            Button { withAnimation(.easeOut(duration: 0.2)) { selectedStudioID = nil } } label: {
                                Label("All Studios", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("studios-index")
                        }
                    }
                    emptyPage
                    ForEach(visibleStudios) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.title).font(.title3.weight(.bold))
                                    Text("\(group.chats.count) session\(group.chats.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if group.studioID != nil {
                                    Button { editingStudio = group } label: { Image(systemName: "text.book.closed").frame(width: 44, height: 44) }
                                        .accessibilityLabel("\(group.title) instructions")
                                }
                            }
                            if search.isEmpty, let pins = group.pins, !pins.isEmpty { MobilePinPills(pins: pins) }
                            if studioListMode {
                                LazyVStack(spacing: 0) {
                                    ForEach(group.chats) { chat in
                                        ChatRow(chat: chat) { open(chat) }.padding(12)
                                            .contextMenu { chatActions(chat) }
                                        if chat.id != group.chats.last?.id { Divider().padding(.leading, 38) }
                                    }
                                }
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            } else {
                                LazyVGrid(columns: cardColumns, spacing: 10) {
                                    ForEach(group.chats) { chat in
                                        ChatCard(chat: chat, showsThumbnail: true, selected: sizeClass == .regular && selection == chat.id,
                                                 isNew: isNewReply(chat)) { open(chat) }
                                            .contextMenu { chatActions(chat) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func isNewReply(_ chat: Companion.ChatSummary) -> Bool {
        (store.chatList?.activity ?? []).contains { $0.chatID == chat.id && MobileSeenReplies.shared.isNew($0) }
    }

    private func header(_ group: Companion.ChatGroup) -> some View {
        HStack {
            Label(group.title, systemImage: group.id.contains("-tag-") ? "tag" : group.kind == .studio ? "paintpalette" : group.kind == .projects ? "apps.iphone" : "bubble.left.and.bubble.right")
            Spacer()
            if group.kind == .studio, group.studioID != nil {
                Button { editingStudio = group } label: { Image(systemName: "text.book.closed") }
                    .accessibilityLabel("\(group.title) instructions")
            }
        }
    }

    private var chatList: some View {
        List {
            loadingStatus.listRowBackground(Color.clear)
            if let problem = store.problem {
                MobileProblemCard(problem, updated: store.chatsUpdatedAt) { await store.loadChats() }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let list = store.chatList {
                if search.isEmpty, let pins = list.pins, !pins.isEmpty {
                    Section("Pins") { MobilePinPills(pins: pins) }
                }
                emptyPage.listRowBackground(Color.clear)
                ForEach(groups) { group in
                    // Each family a card of its own: the session, then its Sidechats and work threads.
                    ForEach(Self.families(group.chats)) { family in
                    Section {
                        if family.first, search.isEmpty, let pins = group.pins, !pins.isEmpty {
                            MobilePinPills(pins: pins)
                        }
                        let visible = MobileFamilyExpansion.shared.visible(family.children, of: family.parent.id)
                        let toggle = familyToggle(family.parent, hidden: visible.hidden)
                        let lastChild = visible.shown.last?.id
                        listRow(ChatRow(chat: family.parent, activity: sort == .active ? Self.activityLine(family.parent) : nil) { open(family.parent) }, family.parent,
                                top: true, bottom: lastChild == nil && toggle == nil)
                            .listRowInsets(sizeClass == .regular ? nil : compactInsets(leading: 0, top: true, bottom: lastChild == nil && toggle == nil))
                        ForEach(visible.shown) { child in
                            listRow(NestedChatRow(chat: child, parent: family.parent, compact: true) { open(child) }, child,
                                    top: false, bottom: child.id == lastChild && toggle == nil)
                                .listRowInsets(sizeClass == .regular ? EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8)
                                               : compactInsets(leading: 20, top: false, bottom: child.id == lastChild && toggle == nil))
                        }
                        if let toggle {
                            toggle.listRowInsets(sizeClass == .regular ? EdgeInsets(top: 0, leading: 48, bottom: 0, trailing: 8)
                                                 : compactInsets(leading: 36, top: false, bottom: true))
                                .listRowBackground(sizeClass == .regular ? nil : rowShape(top: false, bottom: true, selected: false))
                                .listRowSeparator(sizeClass == .regular ? .automatic : .hidden)
                        }
                    } header: {
                        if family.first, showsHeader(group) {
                            HStack {
                                Label(group.title, systemImage: group.kind == .studio ? "paintpalette" : group.kind == .projects ? "apps.iphone" : "bubble.left.and.bubble.right")
                                Spacer()
                                if group.kind == .studio {
                                    Button { editingStudio = group } label: { Image(systemName: "text.book.closed") }
                                        .accessibilityLabel("\(group.title) instructions")
                                }
                            }
                        }
                    }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionItems: some View {
        if let connection = store.connection { Text("Connected to \(connection.macName)") }
        Button { showingAutomations = true } label: { Label("Automations", systemImage: "clock.arrow.circlepath") }
        Button { showingArchived = true } label: { Label("Archived", systemImage: "archivebox") }
        Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
    }

    /// About the open session, as a column on its right: its sections, and Close.
    private func aboutColumnContent(_ chat: Companion.ChatSummary) -> some View {
        let shown = history?.id == chat.id ? history?.detail : nil
        return ScrollView {
            MobileAboutPanel(summary: shown?.summary ?? chat, detail: shown, chats: store.chatList?.groups.flatMap(\.chats) ?? [],
                             perform: { aboutColumn.send($0) }, sessionActions: true)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(.snappy(duration: 0.25)) { aboutColumn.isOpen = false } } label: {
                    Label("Close", systemImage: "xmark")
                }
                .accessibilityIdentifier("about-column-close")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let chat = selectedChat, let history, history.id == chat.id {
            // NavigationSplitView supplies the detail navigation container. A nested
            // stack can retain the old detail or reset compact-column navigation.
            ChatDetailView(chat: chat, open: open, history: history, closeChat: closeChat)
                .id(chat.id)
                .onAppear { MobilePushNotifications.shared.readingChat = chat.id }
                .onDisappear {
                    if MobilePushNotifications.shared.readingChat == chat.id { MobilePushNotifications.shared.readingChat = nil }
                }
        } else {
            ContentUnavailableView {
                Label("Choose a Session", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Your sessions from \(store.connection?.macName ?? "your Mac") are in the sidebar.")
            } actions: {
                // The list is a shelf here, and may be put away.
                if aboutColumn.listShelf, !aboutColumn.listShown {
                    Button("Show Sessions") { withAnimation(.snappy(duration: 0.25)) { aboutColumn.listShown = true } }
                        .accessibilityIdentifier("list-shelf-show")
                }
            }
        }
    }

    /// New chats: on their own, or in a Studio.
    /// Opens New Chat, where the agent, model, effort and permissions are picked first.
    /// On the Studios page it starts in the first Studio.
    private var newChatMenu: some View {
        Button { newChatStudio = page == .studios ? newChatStudios.first?.id : nil; startingNewChat = true } label: {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("New Chat")
    }

    private var newChatStudios: [MobileNewChatSheet.Studio] {
        (store.chatList?.groups ?? []).filter { $0.kind == .studio }.compactMap { group in
            (group.studioID ?? UUID(uuidString: String(group.id.dropFirst("studio-".count)))).map { .init(id: $0, name: group.title) }
        }
    }

    private func archive(_ chat: Companion.ChatSummary) {
        Task {
            _ = try? await store.setArchived(true, chat: chat.id)
            if selection == chat.id { closeChat() }
            await store.loadChats()
        }
    }

    /// Nothing open beside the list (on iPhone, back to the list), on the same page.
    private func closeChat() {
        selection = nil
        opened = nil
        history?.cancel()
        history = nil
        compactColumn = .sidebar
    }

    private func beginRename(_ chat: Companion.ChatSummary) {
        newTitle = chat.title
        renaming = chat
    }

    private func rename(_ chat: Companion.ChatSummary, to title: String) {
        guard !title.isEmpty else { return }
        Task {
            do {
                let result = try await store.rename(chat.id, to: title)
                if selection == chat.id { opened = result.summary; history?.refresh(in: store, force: true) }
                await store.loadChats()
            } catch { managementError = error.localizedDescription }
        }
    }

    private func pin(_ chat: Companion.ChatSummary, _ pinned: Bool) {
        Task {
            do { try await store.setPinned(chat.id, pinned) } catch { managementError = error.localizedDescription }
        }
    }

    /// A row in list mode, with the open session's tint, its menu and Archive on a swipe.
    private func listRow(_ content: some View, _ chat: Companion.ChatSummary, top: Bool = true, bottom: Bool = true) -> some View {
        let regular = sizeClass == .regular
        return content
            .listRowBackground(regular ? (selection == chat.id ? AnyView(Color.primary.opacity(0.08)) : nil)
                               : AnyView(rowShape(top: top, bottom: bottom, selected: false)))
            .listRowSeparator(regular ? .automatic : .hidden)
            .contextMenu { chatActions(chat) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { archive(chat) } label: { Label("Archive", systemImage: "archivebox") }
            }
    }

    /// A row's part of its family's card on iPhone: rounded at the family's top and bottom
    /// only, 14 pt as the card view's cards.
    private func rowShape(top: Bool, bottom: Bool, selected: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: top ? 14 : 0, bottomLeadingRadius: bottom ? 14 : 0,
                               bottomTrailingRadius: bottom ? 14 : 0, topTrailingRadius: top ? 14 : 0, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground))
            // 16 pt from the screen's edges, and 10 pt below a family's last row.
            .padding(.horizontal, 16)
            .padding(.bottom, bottom ? 10 : 0)
    }

    /// A row's insets inside its block on iPhone: the block's 16 pt margin plus 12 pt padding,
    /// and room for the 10 pt gap under a family's last row.
    private func compactInsets(leading: CGFloat, top: Bool, bottom: Bool) -> EdgeInsets {
        EdgeInsets(top: top ? 12 : 8, leading: 28 + leading, bottom: bottom ? 22 : 8, trailing: 28)
    }

    @ViewBuilder private func chatActions(_ chat: Companion.ChatSummary) -> some View {
        // Pins are the Mac's: worktrees, sidechats and work threads stay with their session there.
        if chat.worktreeBranch == nil, chat.sidechatOf == nil, chat.workOf == nil {
            Button { pin(chat, chat.pinnedRank == nil) } label: {
                Label(chat.pinnedRank == nil ? "Pin to Top" : "Unpin", systemImage: chat.pinnedRank == nil ? "pin" : "pin.slash")
            }
        }
        Button { beginRename(chat) } label: { Label("Rename", systemImage: "pencil") }
        if chat.canPromote == true {
            Button { promoting = .init(chat: chat, kind: .studio) } label: { Label("Move to Studio…", systemImage: "paintpalette") }
                .disabled(chat.isRunning)
            Button { promoting = .init(chat: chat, kind: .project) } label: { Label("Make Project…", systemImage: "folder.badge.plus") }
                .disabled(chat.isRunning)
        }
        Button(role: .destructive) { archive(chat) } label: { Label("Archive", systemImage: "archivebox") }
    }

    /// Opens a chat, even one the list doesn't show yet (a new, empty chat).
    /// The chat with this id in the current list (any page).
    private func summary(for id: UUID) -> Companion.ChatSummary? {
        store.chatList?.groups.lazy.flatMap(\.chats).first { $0.id == id }
    }

    private func open(_ chat: Companion.ChatSummary) {
        if aboutColumn.listShown { withAnimation(.snappy(duration: 0.25)) { aboutColumn.listShown = false } }
        opened = chat
        selection = chat.id
        if history?.id != chat.id {
            history?.cancel()
            history = MobileChatHistory(id: chat.id)
        }
        history?.refresh(in: store, force: true)
        compactColumn = .detail
    }

    /// Chats whose title, project, Studio, or latest line has every word searched for.
    private func filtered(_ groups: [Companion.ChatGroup]) -> [Companion.ChatGroup] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            var group = group
            group.chats = group.chats.filter { chat in
                let text = [chat.title, chat.project ?? "", chat.subtitle ?? "", group.title].joined(separator: " ")
                return words.allSatisfy { text.localizedStandardContains($0) }
            }
            return group.chats.isEmpty ? nil : group
        }
    }

    private var allChats: [Companion.ChatSummary] { store.chatList?.groups.flatMap(\.chats) ?? [] }

    private var selectedChat: Companion.ChatSummary? {
        guard let selection else { return nil }
        return allChats.first { $0.id == selection } ?? (opened?.id == selection ? opened : nil)
    }
}

struct ChatRow: View {
    @Environment(MobileStore.self) private var store
    let chat: Companion.ChatSummary
    var activity: String? = nil
    var status: String? = nil
    var isNew = false
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if chat.worktreeBranch != nil {
                            Image(systemName: "arrow.triangle.branch").frame(width: 16, height: 16)
                        } else {
                            Image((Backend(rawValue: chat.backend) ?? .claude).iconName)
                                .resizable().scaledToFit().frame(width: 16, height: 16)
                                .foregroundStyle(MobileConversationStyle.accent(for: chat.backend))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(chat.backend == "codex" ? "Codex" : "Claude")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.worktreeBranch ?? chat.project ?? chat.title).lineLimit(1)
                        if let subtitle = chat.subtitle ?? (chat.project != nil ? chat.title : nil) {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(chat.isWaitingOnYou ? Color.attention : Color.secondary)
                                .lineLimit(2)
                        }
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        if let activity { ActivityLine(text: activity) }
                    }
                    Spacer(minLength: 0)
                    if chat.isWaitingOnYou {
                        Circle().fill(Color.attention).frame(width: 8, height: 8)
                    } else if chat.isRunning {
                        MobileWorkingMark()
                    } else if isNew {
                        Circle().fill(.blue).frame(width: 8, height: 8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-\(chat.id.uuidString)")
            .accessibilityHint(chat.worktreeBranch != nil ? "Worktree of the project above" : "")
            // Pins keep their own actions instead of being nested inside the chat button.
            if let pins = chat.pins, !pins.isEmpty {
                MobilePinPills(pins: pins).padding(.leading, 24)
            }
            if let line = MobileSidequests.line(MobileSidequests.of(chat.id, in: store.chatList?.groups.flatMap(\.chats) ?? [])) {
                Label(line, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
        // A worktree sits indented under its project.
        .padding(.leading, chat.worktreeBranch != nil ? 22 : 0)
    }
}

/// Which families show all their children (ThreadFamilyLimit), for as long as the app runs.
@MainActor @Observable final class MobileFamilyExpansion {
    static let shared = MobileFamilyExpansion()
    var ids: Set<UUID> = []
    func toggle(_ id: UUID) { if ids.contains(id) { ids.remove(id) } else { ids.insert(id) } }
    func visible(_ children: [Companion.ChatSummary], of parent: UUID) -> (shown: [Companion.ChatSummary], hidden: Int) {
        ThreadFamilyLimit.visible(children, expanded: ids.contains(parent), updatedAt: \.updatedAt) { $0.isWaitingOnYou || $0.isRunning }
    }
}

/// A Sidechat or work thread as a row inside its session's card: its name, latest line and state.
private struct NestedChatRow: View {
    let chat: Companion.ChatSummary
    let parent: Companion.ChatSummary
    var selected = false
    /// In a list row, which brings its own insets.
    var compact = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chat.workOf != nil ? "arrow.turn.down.right" : "bubble.left.and.bubble.right")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let subtitle = chat.subtitle {
                        Text(subtitle).font(.caption)
                            .foregroundStyle(chat.isWaitingOnYou ? Color.attention : Color.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if chat.isWaitingOnYou {
                    Circle().fill(Color.attention).frame(width: 8, height: 8).accessibilityLabel("Waiting on you")
                } else if chat.isRunning {
                    MobileWorkingMark(size: .mini)
                }
            }
            .padding(.horizontal, compact ? 0 : 12).padding(.vertical, compact ? 4 : 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-\(chat.id.uuidString)")
        .accessibilityHint(chat.workOf != nil ? "Work thread of \(parent.project ?? parent.title)" : "Sidechat of \(parent.project ?? parent.title)")
    }
}

/// A chat as a card: its agent, name, latest line and state, sized to sit two to a row.
struct ChatCard: View {
    @Environment(MobileStore.self) private var store
    @State private var thumbnail: UIImage?
    @State private var thumbnailShown: String?
    private var thumbnailKey: String { "\(showsThumbnail)|\(chat.thumbnail?.id.uuidString ?? "")|\(chat.thumbnail?.revision ?? "")" }
    let chat: Companion.ChatSummary
    var showsThumbnail = false
    var selected = false
    var isNew = false
    var activity: String? = nil
    var status: String? = nil
    /// Inside a family card (ChatListView.familyCard), which draws the card around it.
    var embedded = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            if showsThumbnail { studioCard } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(chat.worktreeBranch ?? chat.project ?? chat.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        if chat.isWaitingOnYou {
                            Circle().fill(Color.attention).frame(width: 8, height: 8).accessibilityLabel("Waiting on you")
                        } else if chat.isRunning {
                            MobileWorkingMark(size: .mini)
                        } else if isNew {
                            Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("New reply")
                        }
                        if chat.worktreeBranch != nil {
                            Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image((Backend(rawValue: chat.backend) ?? .claude).iconName)
                                .resizable().scaledToFit().frame(width: 13, height: 13)
                                .foregroundStyle(MobileConversationStyle.accent(for: chat.backend))
                        }
                    }
                    .padding(.top, 3)
                }
                if let line = chat.subtitle ?? (chat.project != nil ? chat.title : nil) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(chat.isWaitingOnYou ? Color.attention : Color.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                sidequestLine
                if showsThumbnail, let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Latest image in " + chat.title)
                }
                Spacer(minLength: 0)
                if let activity { ActivityLine(text: activity) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: embedded ? nil : 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(embedded ? Color.clear : Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(embedded ? Color.clear : chat.isWaitingOnYou ? Color.yellow.opacity(0.6) : selected ? Color.accentColor : Color.primary.opacity(0.06),
                              lineWidth: chat.isWaitingOnYou || selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-\(chat.id.uuidString)")
        // Restarts on another address too, as a chat's images do (RemoteImage); a picture
        // already showing stays.
        .task(id: "\(thumbnailKey)|\(store.connection?.hosts.first ?? "")") {
            let key = thumbnailKey
            if thumbnail != nil, thumbnailShown == key { return }
            thumbnail = nil
            if showsThumbnail, let file = chat.thumbnail {
                thumbnail = try? await store.thumbnail(file, in: chat.id)
                thumbnailShown = thumbnail == nil ? nil : key
            }
        }
    }
    /// The sidequests this chat started, in one line; open the chat to open one.
    @ViewBuilder private var sidequestLine: some View {
        if let line = MobileSidequests.line(MobileSidequests.of(chat.id, in: store.chatList?.groups.flatMap(\.chats) ?? [])) {
            Label(line, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var studioCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .accessibilityLabel("Latest image in " + chat.title)
                } else {
                    Image((Backend(rawValue: chat.backend) ?? .claude).iconName)
                        .resizable().scaledToFit().frame(width: 32, height: 32)
                        .foregroundStyle(MobileConversationStyle.accent(for: chat.backend).opacity(0.4))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 112)
            .background(Color.primary.opacity(0.04))
            .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image((Backend(rawValue: chat.backend) ?? .claude).iconName)
                        .resizable().scaledToFit().frame(width: 12, height: 12).padding(.top, 3)
                        .foregroundStyle(MobileConversationStyle.accent(for: chat.backend))
                    Text(chat.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                }
                Text(chat.isRunning ? "Reply in progress" : (chat.subtitle ?? "No replies yet"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                sidequestLine
                HStack(spacing: 5) {
                    if chat.isWaitingOnYou {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("Needs you").foregroundStyle(.orange)
                    } else if chat.isRunning {
                        MobileWorkingMark(size: .mini, tint: MobileConversationStyle.accent(for: chat.backend))
                        Text(store.isStale ? "Last seen working" : "Working").foregroundStyle(store.isStale ? Color.metadata : MobileConversationStyle.accent(for: chat.backend))
                    } else if isNew {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                        Text("New reply").foregroundStyle(.blue)
                    } else { Text(chat.updatedAt, style: .relative).foregroundStyle(.secondary) }
                }.font(.caption2).frame(height: 18, alignment: .leading)
            }.padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.accentColor : chat.isWaitingOnYou ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

}

/// A Studio on the Studios page: its newest picture, its name, how many sessions it has, and
/// how many need you or are working. Tap to see its sessions.
private struct StudioIndexCard: View {
    let group: Companion.ChatGroup
    let open: () -> Void
    @Environment(MobileStore.self) private var store
    @State private var cover: UIImage?
    private var coverChat: Companion.ChatSummary? { group.chats.first { $0.thumbnail != nil } }

    var body: some View {
        let waiting = group.chats.filter(\.isWaitingOnYou).count
        let working = group.chats.filter(\.isRunning).count
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Color(uiColor: .tertiarySystemFill)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                        else { Image(systemName: "paintpalette").font(.title).foregroundStyle(.secondary) }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).font(.headline).lineLimit(1)
                    Text("\(group.chats.count) session\(group.chats.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    if waiting > 0 || working > 0 {
                        HStack(spacing: 8) {
                            if waiting > 0 { Label("\(waiting) need\(waiting == 1 ? "s" : "") you", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                            if working > 0 { Label("\(working) working", systemImage: "circle.dotted").foregroundStyle(.secondary) }
                        }
                        .font(.caption2.weight(.medium)).labelStyle(.titleAndIcon).lineLimit(1)
                    }
                }
                .padding(10)
                // Room for the status line on every card, so a row of cards lines up.
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(waiting > 0 ? Color.orange : Color.primary.opacity(0.08), lineWidth: waiting > 0 ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio-select-" + group.id)
        .accessibilityLabel("\(group.title), \(group.chats.count) sessions\(waiting > 0 ? ", \(waiting) need you" : "")")
        .task(id: coverChat.map { "\($0.id)|\($0.thumbnail?.id.uuidString ?? "")|\($0.thumbnail?.revision ?? "")" } ?? "") {
            guard let chat = coverChat, let file = chat.thumbnail else { cover = nil; return }
            cover = try? await store.thumbnail(file, in: chat.id)
        }
    }
}

/// A session working, as of the Mac's last answer: a spinner; while the Mac can't be reached,
/// a still grey clock ("last seen working"), so nothing spins on old news.
struct MobileWorkingMark: View {
    @Environment(MobileStore.self) private var store
    var size: ControlSize = .small
    var tint: Color? = nil

    var body: some View {
        if store.isStale {
            Image(systemName: "clock").font(size == .mini ? .caption2 : .footnote).foregroundStyle(Color.metadata)
                .accessibilityLabel("Last seen working")
        } else {
            ProgressView().controlSize(size).tint(tint)
        }
    }
}

/// Trouble reaching the Mac, as a small card: its first sentence as the title, the rest under it,
/// when what's shown was last updated, and Retry.
struct MobileProblemCard: View {
    private let title: String
    private let detail: String
    private let updated: Date?
    private let retry: (() async -> Void)?
    @State private var retrying = false

    /// `updated`: when what's still shown came from the Mac. `retry`: tries again now.
    init(_ problem: String, updated: Date? = nil, retry: (() async -> Void)? = nil) {
        let parts = problem.split(separator: ". ", maxSplits: 1)
        title = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        detail = parts.count > 1 ? String(parts[1]) : ""
        self.updated = updated
        self.retry = retry
    }

    /// "Last updated 9:12", or with its day when it isn't today.
    static func lastUpdated(_ date: Date) -> String {
        "Last updated " + (Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                                                 : date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: title.hasPrefix("Can't reach") ? "wifi.exclamationmark" : "exclamationmark.triangle").foregroundStyle(.orange).font(.body.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(Color.metadata).fixedSize(horizontal: false, vertical: true) }
                if let updated {
                    Text(Self.lastUpdated(updated)).font(.footnote.weight(.medium)).foregroundStyle(Color.metadata)
                        .padding(.top, 2)
                        .accessibilityIdentifier("problem-updated")
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let retry {
                Button {
                    guard !retrying else { return }
                    retrying = true
                    Task { await retry(); retrying = false }
                } label: {
                    if retrying { ProgressView().controlSize(.small).frame(minWidth: 44) } else { Text("Retry").fontWeight(.semibold) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(retrying)
                .accessibilityLabel(retrying ? "Retrying" : "Retry")
                .accessibilityIdentifier("problem-retry")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The active fold in session-list coordinates. Observe layout and posture changes even
/// when the window's overall size stays unchanged (flat → partially folded).
private struct SessionDivisionProbe: UIViewRepresentable {
    @Binding var division: CGRect?

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { frame in if division != frame { division = frame } }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.report = { frame in if division != frame { division = frame } }
    }

    final class Probe: UIView {
        var report: (CGRect?) -> Void = { _ in }
        private var timer: Timer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }

        override func layoutSubviews() { super.layoutSubviews(); check() }

        private func check() {
            var frame: CGRect?
            var margins = UIEdgeInsets.zero
            if #available(iOS 27.1, *), let region = reservedRegions(kind: .division).first(where: \.isActive) {
                frame = region.frame
                margins = region.margins
            }
            #if DEBUG
            // Native iPad fixture: simulate the region the real Duo reports while bent.
            // Fractions are deliberately asymmetric in the regression to catch a fixed
            // half-width layout or the old 460-point sidebar cap.
            if let raw = ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SESSION_DIVISION"],
               let fraction = Double(raw), fraction > 0, fraction < 1 {
                let margin = Double(ProcessInfo.processInfo.environment["CHATTERBOX_TEST_SESSION_DIVISION_MARGIN"] ?? "") ?? 0
                frame = CGRect(x: bounds.width * fraction - 6 - margin, y: 0, width: 12 + 2 * margin, height: bounds.height)
                margins = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
            }
            #endif
            // UIKit includes touch-clearance margins in the region. They are not an
            // empty strip between screens; divide at the physical hinge instead.
            let value = frame.map { $0.inset(by: margins) }
            // Defer the binding write until UIKit has finished its layout callback.
            DispatchQueue.main.async { [weak self] in self?.report(value) }
        }
    }
}

/// UIKit hands the sidebar's navigation stack the window's whole right inset (the tab bar
/// column on a landscape iPhone Duo, 84 points) though the sidebar is nowhere near that edge,
/// leaving its search field and list short of its divider. This trims the sidebar hosting
/// controller's insets to the part of the window's insets it actually overlaps.
private struct SafeAreaToOwnFrame: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Trimmer { Trimmer() }
    func updateUIViewController(_ controller: Trimmer, context: Context) { controller.trim() }

    final class Trimmer: UIViewController {
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); trim() }
        override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); DispatchQueue.main.async { [weak self] in self?.trim() } }

        func trim() {
            // The sidebar's own hosting controller, inside the navigation controller.
            guard let host = parent, let window = host.view.window else { return }
            let frame = host.view.convert(host.view.bounds, to: window)
            let edges = window.safeAreaInsets
            // What the window's insets cover of this frame, on each side.
            let left = max(0, edges.left - frame.minX), right = max(0, edges.right - (window.bounds.width - frame.maxX))
            let added = host.additionalSafeAreaInsets
            let inherited = (left: host.view.safeAreaInsets.left - added.left, right: host.view.safeAreaInsets.right - added.right)
            let wanted = UIEdgeInsets(top: added.top, left: left - inherited.left, bottom: added.bottom, right: right - inherited.right)
            if abs(wanted.left - added.left) > 0.5 || abs(wanted.right - added.right) > 0.5 { host.additionalSafeAreaInsets = wanted }
        }
    }
}

/// Settings, from the ⋯ menu: Notifications, Appearance and Unpair in one place (Shelby,
/// 2026-11-09; Mac Screen, Activity History, Usage and Saved PDFs left the menu).
struct MobileSettingsSheet: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if let connection = store.connection {
                    Section { LabeledContent("Connected to", value: connection.macName) }
                }
                Section {
                    NavigationLink { MobileNotificationSettings().environment(store) } label: { Label("Notifications", systemImage: "bell") }
                    NavigationLink { MobileAppearanceSettings(embedded: true) } label: { Label("Appearance", systemImage: "paintbrush") }
                }
                Section {
                    NavigationLink {
                        ChangelogList().navigationTitle("What's New").navigationBarTitleDisplayMode(.inline)
                    } label: { Label("What's New", systemImage: "sparkles") }
                        .accessibilityIdentifier("settings-whats-new")
                }
                Section {
                    Button("Unpair This \(UIDevice.current.model)", role: .destructive) { confirmingUnpair = true }
                        .accessibilityIdentifier("settings-unpair")
                } footer: {
                    Text("Unpairing forgets this Mac on this \(UIDevice.current.model). Pair again with a new code from the Mac.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this \(UIDevice.current.model)?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { dismiss(); store.forget() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

/// "12 turns today", with the flame right beside it (a Label in a sidebar list puts the icon in
/// a wide column of its own).
struct ActivityLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame")
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
    }
}

/// Archived sessions, newest first, searchable: tap one to open it (its menu has Unarchive),
/// or swipe to unarchive it here.
struct MobileArchivedSheet: View {
    let pick: (Companion.ChatSummary) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var chats: [Companion.ChatSummary]?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                } else if let chats, chats.isEmpty {
                    Text(search.isEmpty ? "No archived sessions." : "No archived sessions match.").foregroundStyle(.secondary)
                }
                ForEach(chats ?? []) { chat in
                    ChatRow(chat: chat) { pick(chat); dismiss() }
                        .swipeActions(edge: .trailing) {
                            Button { unarchive(chat) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }.tint(.blue)
                        }
                }
            }
            .overlay { if chats == nil, problem == nil { ProgressView() } }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search archived")
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: search) {
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }
                do { chats = try await store.archivedChats(matching: search); problem = nil }
                catch { if !Task.isCancelled { problem = "Couldn't load archived sessions: \(error.localizedDescription)" } }
            }
        }
        .accessibilityIdentifier("archived-sheet")
    }

    private func unarchive(_ chat: Companion.ChatSummary) {
        Task {
            _ = try? await store.setArchived(false, chat: chat.id)
            chats?.removeAll { $0.id == chat.id }
            await store.loadChats()
        }
    }
}

