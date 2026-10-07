import SwiftUI

/// The Mac's chats on three pages, like the Mac's Home: Projects, Studios, and other Chats.
/// On iPad the open chat sits beside them; on iPhone it opens over them.
struct ChatListView: View {
    enum Page: String, CaseIterable, Identifiable {
        case projects, studios, chats
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String { self == .projects ? "folder" : self == .studios ? "paintpalette" : "bubble.left.and.bubble.right" }
        var kind: Companion.ChatGroup.Kind { self == .projects ? .projects : self == .studios ? .studio : .chats }
    }
    /// On iPhone Golem has his own tab, so the list leaves him out.
    var hidesAssistant = true
    /// Tells the iPhone's home whether a chat is open (its edge swipe yields to Back then).
    var onShowingChat: (Bool) -> Void = { _ in }
    /// Set when the list is one of the home's bottom tabs: only that page, no page switcher.
    var fixedPage: Page? = nil
    @Environment(MobileStore.self) private var store
    /// List rows, or cards two to a row.
    @AppStorage("mobileChatListCards") private var showsCards = false
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
    @State private var savedPDFs = false
    @State private var appearance = false
    @State private var notificationSettings = false
    @State private var selection: UUID?
    /// The chat that's open, kept if it drops out of the list (archived on the Mac).
    @State private var opened: Companion.ChatSummary?
    /// Requests outlive transient detail views during split-view navigation.
    @State private var history: MobileChatHistory?
    /// On iPad, the chat list stays beside the chat, in portrait too.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var search = ""
    /// The Studio whose instructions are open.
    @State private var editingStudio: Companion.ChatGroup?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            sidebar
                .safeAreaInset(edge: .top, spacing: 0) { if fixedPage == nil { pagePicker } }
                .navigationTitle(fixedPage?.title ?? store.connection?.macName ?? "Chatterbox")
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await store.loadChats() }
                .searchable(text: $search, prompt: fixedPage.map { "Search \($0.title)" } ?? "Search chats")
                .sheet(item: $editingStudio) { group in
                    if let id = group.studioID {
                        StudioInstructionsEditor(title: group.title, studio: id, initial: group.instructions ?? "")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { connectionMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { notificationSettings = true } label: { Image(systemName: "bell") }.accessibilityLabel("Notifications")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort", selection: Binding(get: { sort }, set: { new in withAnimation(.easeOut(duration: 0.2)) { sortName = new.rawValue } })) {
                                ForEach(Sort.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                            }
                        } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel("Sort, \(sort.title)")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { withAnimation(.easeOut(duration: 0.2)) { showsCards.toggle() } } label: {
                            Image(systemName: showsCards ? "list.bullet" : "square.grid.2x2")
                        }
                        .accessibilityLabel(showsCards ? "Show as List" : "Show as Cards")
                    }
                    ToolbarItem(placement: .topBarTrailing) { newChatMenu }
                }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: compactColumn, initial: true) { _, column in onShowingChat(sizeClass != .regular && column == .detail) }
        .sheet(isPresented: $notificationSettings) {
            NavigationStack {
                MobileNotificationSettings().environment(store)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { notificationSettings = false } } }
            }
        }
        .task(id: "\(MobilePushNotifications.shared.pendingChat?.uuidString ?? "")|\(scenePhase)") {
            guard let id = MobilePushNotifications.shared.pendingChat else { return }
            await store.loadChats()
            if let fixedPage {
                let kind = store.chatList?.groups.first { $0.chats.contains { $0.id == id } }?.kind
                guard kind == fixedPage.kind || (kind == nil && fixedPage == .chats) else { return }
            }
            if let chat = allChats.first(where: { $0.id == id }) {
                open(chat); MobilePushNotifications.shared.pendingChat = nil
            } else if let result = try? await store.detail(id, since: nil), case .detail(let detail) = result {
                open(detail.summary); MobilePushNotifications.shared.pendingChat = nil
            }
        }
        .sheet(isPresented: $savedPDFs) { SavedPDFsView() }
        .sheet(isPresented: $appearance) { MobileAppearanceSettings() }
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
            // The assistant's animations, kept in step with the Mac's.
            #if GOLEM_APP
            Task { await MobileGolem.shared.load(from: store) }
            #endif
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

    /// iPad's sidebar style beside the chat; the iPhone's grouped list on its own.
    @ViewBuilder
    private var sidebar: some View {
        if showsCards {
            chatCards
        } else if sizeClass == .regular {
            chatList.listStyle(.sidebar)
        } else {
            chatList.listStyle(.insetGrouped)
        }
    }

    /// The page's groups; a search looks through every page. Golem is never listed here.
    private var groups: [Companion.ChatGroup] {
        let all = (store.chatList?.groups ?? []).filter { $0.kind != .dot || !hidesAssistant }
        // A tab searches its own page; the switcher's search looks through every page.
        return sorted(filtered(search.isEmpty || fixedPage != nil ? all.filter { $0.kind == page.kind } : all.filter { $0.kind != .dot }))
    }

    /// The groups in the chosen order. A project's worktrees and sidechats, listed right after
    /// it, move with it. By Tag regroups projects under each of their tags, untagged last.
    private func sorted(_ groups: [Companion.ChatGroup]) -> [Companion.ChatGroup] {
        guard sort != .recent else { return groups }
        func families(_ chats: [Companion.ChatSummary]) -> [[Companion.ChatSummary]] {
            var result: [[Companion.ChatSummary]] = []
            for chat in chats {
                if (chat.worktreeBranch != nil || chat.sidechatOf != nil), !result.isEmpty { result[result.count - 1].append(chat) }
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
        group.kind != .dot && (group.kind == .studio || sort == .tag || (!search.isEmpty && fixedPage == nil))
    }

    private func waiting(on page: Page) -> Int {
        (store.chatList?.groups ?? []).filter { $0.kind == page.kind }.flatMap(\.chats).filter(\.isWaitingOnYou).count
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

    /// Nothing on this page (or nothing found).
    @ViewBuilder
    private var emptyPage: some View {
        if store.chatList != nil, groups.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No \(page.title)", systemImage: page.icon,
                                       description: Text(page == .studios ? "Studios you make on the Mac show up here." :
                                                         page == .projects ? "Projects you open on the Mac show up here." :
                                                         "Chats outside a project or Studio show up here."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    /// The same chats as the list, as cards two to a row under the same headings.
    private var chatCards: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let problem = store.problem {
                    Label(problem, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.orange)
                }
                if let list = store.chatList {
                    if search.isEmpty { MobileNewReplies(activity: list.activity ?? [], summary: summary(for:), open: open) }
                    if search.isEmpty, let pins = list.pins, !pins.isEmpty { MobilePinPills(pins: pins) }
                    emptyPage
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if showsHeader(group) { header(group).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(group.chats) { chat in
                                    ChatCard(chat: chat, selected: sizeClass == .regular && selection == chat.id, activity: sort == .active ? Self.activityLine(chat) : nil) { open(chat) }
                                        .contextMenu {
                                            Button(role: .destructive) { archive(chat) } label: { Label("Archive", systemImage: "archivebox") }
                                        }
                                }
                            }
                        }
                    }
                } else if store.problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func header(_ group: Companion.ChatGroup) -> some View {
        HStack {
            Label(group.title, systemImage: group.id.contains("-tag-") ? "tag" : group.kind == .studio ? "paintpalette" : group.kind == .projects ? "folder" : "bubble.left.and.bubble.right")
            Spacer()
            if group.kind == .studio, group.studioID != nil {
                Button { editingStudio = group } label: { Image(systemName: "text.book.closed") }
                    .accessibilityLabel("\(group.title) instructions")
            }
        }
    }

    private var chatList: some View {
        List {
            if let problem = store.problem {
                Section {
                    Label(problem, systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            if let list = store.chatList {
                if search.isEmpty {
                    MobileNewReplies(activity: list.activity ?? [], summary: summary(for:), open: open)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if search.isEmpty, let pins = list.pins, !pins.isEmpty {
                    Section("Pins") { MobilePinPills(pins: pins) }
                }
                emptyPage.listRowBackground(Color.clear)
                ForEach(groups) { group in
                    Section {
                        if search.isEmpty, let pins = group.pins, !pins.isEmpty {
                            MobilePinPills(pins: pins)
                        }
                        ForEach(group.chats) { chat in
                            ChatRow(chat: chat, activity: sort == .active ? Self.activityLine(chat) : nil) { open(chat) }
                                .listRowBackground(sizeClass == .regular && selection == chat.id ? Color.primary.opacity(0.08) : nil)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { archive(chat) } label: { Label("Archive", systemImage: "archivebox") }
                                }
                        }
                    } header: {
                        if showsHeader(group) {
                            HStack {
                                Label(group.title, systemImage: group.kind == .studio ? "paintpalette" : group.kind == .projects ? "folder" : "bubble.left.and.bubble.right")
                                Spacer()
                                if group.kind == .studio {
                                    Button { editingStudio = group } label: { Image(systemName: "text.book.closed") }
                                        .accessibilityLabel("\(group.title) instructions")
                                }
                            }
                        }
                    }
                }
            } else if store.problem == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    private var connectionMenu: some View {
        Menu {
            if let connection = store.connection {
                Section("Connected to \(connection.macName)") {
                    ForEach(connection.hosts, id: \.self) { Text($0) }
                }
            }
            Button { appearance = true } label: { Label("Appearance", systemImage: "paintbrush") }
            Button { savedPDFs = true } label: { Label("Saved PDFs", systemImage: "doc.richtext") }
            Button("Unpair This \(UIDevice.current.model)", role: .destructive) { store.forget() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }.accessibilityLabel("Connection")
    }

    @ViewBuilder
    private var detail: some View {
        if let chat = selectedChat, let history, history.id == chat.id {
            // NavigationSplitView supplies the detail navigation container. A nested
            // stack can retain the old detail or reset compact-column navigation.
            ChatDetailView(chat: chat, open: open, history: history)
                .id(chat.id)
                .onAppear { MobilePushNotifications.shared.readingChat = chat.id }
                .onDisappear {
                    if MobilePushNotifications.shared.readingChat == chat.id { MobilePushNotifications.shared.readingChat = nil }
                }
        } else {
            ContentUnavailableView("Choose a Chat", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Your chats from \(store.connection?.macName ?? "your Mac") are in the sidebar."))
        }
    }

    /// New chats: on their own, or in a Studio.
    private var newChatMenu: some View {
        Menu {
            Button { newChat(studio: nil, backend: "claude") } label: { Label("New Claude Chat", systemImage: "sparkle") }
            Button { newChat(studio: nil, backend: "codex") } label: { Label("New Codex Chat", systemImage: "terminal") }
            let studios = (store.chatList?.groups ?? []).filter { $0.kind == .studio }
            if !studios.isEmpty {
                Section("In a Studio") {
                    ForEach(studios) { group in
                        Button { newChat(studio: UUID(uuidString: String(group.id.dropFirst("studio-".count))), backend: nil) } label: {
                            Label(group.title, systemImage: "paintpalette")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("New Chat")
    }

    private func newChat(studio: UUID?, backend: String?) {
        Task {
            if let detail = try? await store.newChat(in: studio, backend: backend) { open(detail.summary) }
            await store.loadChats()
        }
    }

    private func archive(_ chat: Companion.ChatSummary) {
        Task {
            _ = try? await store.setArchived(true, chat: chat.id)
            if selection == chat.id { selection = nil }
            await store.loadChats()
        }
    }

    /// Opens a chat, even one the list doesn't show yet (a new, empty chat).
    /// The chat with this id in the current list (any page).
    private func summary(for id: UUID) -> Companion.ChatSummary? {
        store.chatList?.groups.lazy.flatMap(\.chats).first { $0.id == id }
    }

    private func open(_ chat: Companion.ChatSummary) {
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

private struct ChatRow: View {
    let chat: Companion.ChatSummary
    var activity: String? = nil
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if chat.worktreeBranch != nil {
                            Image(systemName: "arrow.triangle.branch").frame(width: 16, height: 16)
                        } else if chat.isDot == true { Image(systemName:"sparkles").frame(width:16,height:16) }
                        else {
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
                                .foregroundStyle(chat.isWaitingOnYou ? .yellow : .secondary)
                                .lineLimit(2)
                        }
                        if let activity { Label(activity, systemImage: "flame").font(.caption2).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 0)
                    if chat.isWaitingOnYou {
                        Circle().fill(.yellow).frame(width: 8, height: 8)
                    } else if chat.isRunning {
                        ProgressView().controlSize(.small)
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
        }
        .padding(.vertical, 2)
        // A worktree sits indented under its project.
        .padding(.leading, chat.worktreeBranch != nil ? 22 : 0)
    }
}

/// A chat as a card: its agent, name, latest line and state, sized to sit two to a row.
private struct ChatCard: View {
    let chat: Companion.ChatSummary
    var selected = false
    var activity: String? = nil
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if chat.worktreeBranch != nil {
                        Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image((Backend(rawValue: chat.backend) ?? .claude).iconName)
                            .resizable().scaledToFit().frame(width: 13, height: 13)
                            .foregroundStyle(MobileConversationStyle.accent(for: chat.backend))
                    }
                    Spacer(minLength: 0)
                    if chat.isWaitingOnYou {
                        Circle().fill(.yellow).frame(width: 8, height: 8).accessibilityLabel("Waiting on you")
                    } else if chat.isRunning {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(chat.worktreeBranch ?? chat.project ?? chat.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let line = chat.subtitle ?? (chat.project != nil ? chat.title : nil) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(chat.isWaitingOnYou ? .yellow : .secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if let activity { Label(activity, systemImage: "flame").font(.caption2).foregroundStyle(.orange) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(chat.isWaitingOnYou ? Color.yellow.opacity(0.6) : selected ? Color.accentColor : Color.primary.opacity(0.06),
                              lineWidth: chat.isWaitingOnYou || selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-\(chat.id.uuidString)")
    }
}
