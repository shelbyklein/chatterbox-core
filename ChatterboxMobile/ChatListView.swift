import SwiftUI

/// The Mac's chats, grouped like its sidebar: projects, each Studio, then other chats. On
/// iPad the open chat sits beside them; on iPhone it opens over them.
struct ChatListView: View {
    /// On iPhone Golem has his own tab, so the list leaves him out.
    var hidesAssistant = true
    /// Tells the iPhone's home whether a chat is open (its edge swipe yields to Back then).
    var onShowingChat: (Bool) -> Void = { _ in }
    @Environment(MobileStore.self) private var store
    /// List rows, or cards two to a row.
    @AppStorage("mobileChatListCards") private var showsCards = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var savedPDFs = false
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
                .navigationTitle(store.connection?.macName ?? "Chatterbox")
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await store.loadChats() }
                .searchable(text: $search, prompt: "Search chats")
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
            if let chat = allChats.first(where: { $0.id == id }) {
                open(chat); MobilePushNotifications.shared.pendingChat = nil
            } else if let result = try? await store.detail(id, since: nil), case .detail(let detail) = result {
                open(detail.summary); MobilePushNotifications.shared.pendingChat = nil
            }
        }
        .sheet(isPresented: $savedPDFs) { SavedPDFsView() }
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

    private var groups: [Companion.ChatGroup] {
        filtered((store.chatList?.groups ?? []).filter { !hidesAssistant || $0.kind != .dot })
    }

    /// The same chats as the list, as cards two to a row under the same headings.
    private var chatCards: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let problem = store.problem {
                    Label(problem, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.orange)
                }
                if let list = store.chatList {
                    if search.isEmpty, let pins = list.pins, !pins.isEmpty { MobilePinPills(pins: pins) }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if group.kind != .dot { header(group).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(group.chats) { chat in
                                    ChatCard(chat: chat, selected: sizeClass == .regular && selection == chat.id) { open(chat) }
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
            Label(group.title, systemImage: group.kind == .studio ? "paintpalette" : group.kind == .projects ? "folder" : "bubble.left.and.bubble.right")
            Spacer()
            if group.kind == .studio {
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
                if search.isEmpty, let pins = list.pins, !pins.isEmpty {
                    Section("Pins") { MobilePinPills(pins: pins) }
                }
                ForEach(filtered(list.groups.filter { !hidesAssistant || $0.kind != .dot })) { group in
                    Section {
                        if search.isEmpty, let pins = group.pins, !pins.isEmpty {
                            MobilePinPills(pins: pins)
                        }
                        ForEach(group.chats) { chat in
                            ChatRow(chat: chat) { open(chat) }
                                .listRowBackground(sizeClass == .regular && selection == chat.id ? Color.primary.opacity(0.08) : nil)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { archive(chat) } label: { Label("Archive", systemImage: "archivebox") }
                                }
                        }
                    } header: {
                        if group.kind != .dot {
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
