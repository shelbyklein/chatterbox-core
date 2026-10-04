import SwiftUI

/// Shared by the compact sidebar and full-window overview. Opening a card selects the
/// existing session; it never creates, copies or submits a conversation.
struct ThreadCard: View {
    let session: ChatSession
    var expanded = false
    var selected = false
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model

    private var title: String { session.isDot ? model.dotName : (session.record.projectFolder != nil ? session.projectName : session.title) }
    private var status: String {
        if session.record.archivedAt != nil { return "Archived" }
        if session.isWaitingOnYou { return "Needs you" }
        if session.isRunning { return "Working" }
        if session.hasBackgroundWork { return "Background work" }
        if Attention.shared.unread.contains(session.id) { return "New reply" }
        return "Ready"
    }
    private var messageCount: Int { session.items.filter { $0.kind == .user || $0.kind == .assistant }.count }
    private var tint: Color { session.isWaitingOnYou ? .orange : (session.record.backend == .codex ? .green : .orange) }
    private var preview: String {
        guard let text = session.items.last(where: { $0.kind == .assistant || $0.kind == .user })?.text else { return "No messages yet" }
        return ChatSession.firstSentence(of: text, limit: expanded ? 320 : 110) ?? "Open to view the conversation"
    }
    private var relation: String? {
        if session.record.sidechatOf != nil { return "Temporary" }
        if let branch = session.record.worktreeBranch { return branch }
        return nil
    }

    private var backendIcon: some View {
        Image(session.record.backend.iconName).resizable().scaledToFit()
            .frame(width: expanded ? 19 : 13, height: expanded ? 19 : 13)
            .foregroundStyle(tint)
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: expanded ? 12 : 7) {
                HStack(spacing: 6) {
                    #if GOLEM_APP
                    if session.isDot { GolemHead(size: expanded ? 26 : 18) }
                    else { backendIcon }
                    #else
                    backendIcon
                    #endif
                    Spacer(minLength: 0)
                    if expanded { Text(status).font(.caption.weight(.medium)).lineLimit(1) }
                    Circle().fill(session.isWaitingOnYou ? .orange : session.isRunning ? tint : Attention.shared.unread.contains(session.id) ? .blue : .secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
                Text(title).font(expanded ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let relation {
                    Label(relation, systemImage: session.record.sidechatOf != nil ? "bubble.left.and.bubble.right" : "arrow.triangle.branch")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if expanded, let parentID = session.record.sidechatOf {
                    ParentThreadLabel(parentID: parentID)
                }
                Text(preview).font(expanded ? .body : .caption).foregroundStyle(.secondary)
                    .lineLimit(expanded ? 4 : 2).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    if expanded {
                        Text("\(session.record.backend.label) · \(messageCount) \(messageCount == 1 ? "message" : "messages")").font(.caption).lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    Text(ShortAge.string(since: session.lastActivity)).font(.caption2).foregroundStyle(.secondary)
                    if !expanded { Spacer(minLength: 0) }
                }
            }
            .padding(expanded ? 18 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: expanded ? 250 : 144)
            .frame(height: expanded ? nil : 144)
            .background(selected && !session.isWaitingOnYou ? Color.white : Color.primary.opacity(hovered ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(session.isWaitingOnYou ? Color.orange : Color.primary.opacity(hovered ? 0.28 : 0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, selected && !session.isWaitingOnYou ? .light : colorScheme)
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.cards[session.id] = $0 }
        #endif
        .onHover { hovered = $0 }
        .help("\(title) — \(status)\(relation.map { " · " + $0 } ?? "")")
        .accessibilityLabel("Open \(title)")
        .accessibilityValue("\(status)\(relation.map { ", " + $0 } ?? "")")
    }
}

private struct ParentThreadLabel: View {
    @Environment(AppModel.self) private var model
    let parentID: UUID
    var body: some View {
        if let parent = model.sessions.first(where: { $0.id == parentID }) {
            Text("In \(parent.record.projectFolder != nil ? parent.projectName : parent.title)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct HomeThreadGroup: Identifiable {
    let id: String
    let title: String
    let threads: [ChatSession]
}

enum HomeThreadFilter: String, CaseIterable, Identifiable {
    case all = "All", needsYou = "Needs you", working = "Working"
    var id: Self { self }
}

enum HomeThreadPage: String, CaseIterable, Identifiable {
    case projects = "Projects", studios = "Studios", chats = "Chats", archive = "Archive"
    var id: Self { self }
    var icon: String {
        switch self {
        case .projects: "folder"
        case .studios: "square.stack.3d.up"
        case .chats: "bubble.left.and.bubble.right"
        case .archive: "archivebox"
        }
    }
}

/// Home deliberately ignores collapsed sidebar groups: an overview must not hide
/// a Studio's threads just because its navigation heading is folded.
@MainActor
enum HomeThreads {
    static func groups(_ model: AppModel, search: String = "", filter: HomeThreadFilter = .all) -> [HomeThreadGroup] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<UUID>()
        func matching(_ session: ChatSession) -> Bool {
            let attention = session.isWaitingOnYou || Attention.shared.unread.contains(session.id)
            guard filter != .needsYou || attention, filter != .working || session.isRunning || session.hasBackgroundWork else { return false }
            return needle.isEmpty || [session.title, session.projectName, model.studio(for: session)?.name ?? "", session.record.worktreeBranch ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        func group(_ id: String, _ title: String, _ candidates: [ChatSession]) -> HomeThreadGroup {
            let threads = candidates.filter { seen.insert($0.id).inserted }.filter(matching)
            return HomeThreadGroup(id: id, title: title, threads: threads)
        }
        func family(_ root: ChatSession) -> [ChatSession] {
            var threads = [root] + model.sidechats(of: root)
            if root.record.projectFolder != nil || root.record.convertedProjectFolder != nil {
                for branch in model.worktrees(of: root) { threads += [branch] + model.sidechats(of: branch) }
            }
            return threads
        }
        var result = [group("golem", model.dotName, model.activeSessions.filter(\.isDot)),
                      group("projects", "Projects", model.sidebarProjects.flatMap(family))]
        for studio in model.activeStudios {
            result.append(group(studio.id.uuidString, studio.name, model.chats(in: studio).flatMap(family)))
        }
        result.append(group("chats", "Chats", model.sidebarChats.flatMap(family)))
        // Include orphaned worktrees or other active records without duplicating families.
        result.append(group("other", "Other threads", model.activeSessions.sorted { $0.lastActivity > $1.lastActivity }))
        return result.filter { !$0.threads.isEmpty }
    }
    /// Partition the overview without changing the combined chooser used by Command Center.
    static func groups(_ model: AppModel, page: HomeThreadPage, search: String = "", filter: HomeThreadFilter = .all) -> [HomeThreadGroup] {
        if page == .archive {
            let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let archived = model.archivedSessions.filter { session in
                let attention = session.isWaitingOnYou || Attention.shared.unread.contains(session.id)
                guard filter != .needsYou || attention, filter != .working || session.isRunning || session.hasBackgroundWork else { return false }
                return needle.isEmpty || [session.title, session.projectName, model.studio(for: session)?.name ?? "", session.record.worktreeBranch ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            return archived.isEmpty ? [] : [HomeThreadGroup(id: "archive", title: "Archived threads", threads: archived)]
        }
        let studioIDs = Set(model.activeStudios.map { $0.id.uuidString })
        return groups(model, search: search, filter: filter).compactMap { group in
            let threads = group.threads.filter { session in
                let destination: HomeThreadPage
                if group.id == "projects" { destination = .projects }
                else if studioIDs.contains(group.id) { destination = .studios }
                else if group.id == "other", session.record.studioID.map({ studioIDs.contains($0.uuidString) }) == true { destination = .studios }
                else if group.id == "other", !session.isDot, session.record.projectFolder != nil || session.record.worktreeOf != nil || session.record.convertedProjectFolder != nil { destination = .projects }
                else { destination = .chats }
                return destination == page
            }
            return threads.isEmpty ? nil : HomeThreadGroup(id: group.id, title: group.title, threads: threads)
        }
    }

}

struct ChatHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: HomeThreadFilter = .all
    let card: (ChatSession) -> AnyView

    @AppStorage("macHomePage") private var savedPage = HomeThreadPage.projects.rawValue
    private var page: HomeThreadPage { HomeThreadPage(rawValue: savedPage) ?? .projects }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Home").font(.largeTitle.weight(.bold))
                    Spacer()
                    Button("Command Center", systemImage: "rectangle.split.2x2") { model.showingCommandCenter = true }
                    Button("Back to Chat", systemImage: "arrow.left") { model.showingHome = false }
                }
                HStack(spacing: 8) {
                    ForEach(HomeThreadPage.allCases) { destination in
                        if destination == .archive { Divider().frame(height: 24).padding(.horizontal, 4) }
                        Button { savedPage = destination.rawValue } label: {
                            HStack(spacing: 7) {
                                Image(systemName: destination.icon)
                                Text(destination.rawValue)
                                Text("\(HomeThreads.groups(model, page: destination).reduce(0) { $0 + $1.threads.count })")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(page == destination ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(page == destination ? Color.accentColor.opacity(0.65) : Color.clear))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(destination.rawValue)
                            .accessibilityAddTraits(page == destination ? .isSelected : [])
                            #if DEBUG
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.tabs[destination] = $0 }
                            #endif
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { searchField; filterPicker.frame(width: 300) }
                    VStack(alignment: .leading, spacing: 12) { searchField; filterPicker }
                }
            }.padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let groups = HomeThreads.groups(model, page: page, search: search, filter: filter)
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(group.title).font(.title2.weight(.semibold))
                                Text("\(group.threads.count)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 440), spacing: 16)], alignment: .leading, spacing: 16) {
                                ForEach(group.threads) { card($0) }
                            }
                        }
                    }
                    if groups.isEmpty {
                        ContentUnavailableView("No \(page.rawValue.lowercased()) to show", systemImage: page.icon,
                                               description: Text(search.isEmpty && filter == .all ? "Threads will appear here as you add them." : "Try another search or choose All."))
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.id(page)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel("Home \(page.rawValue.lowercased()) page")
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(page.rawValue.lowercased())", text: $search).textFieldStyle(.plain)
        }.padding(10).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
    private var filterPicker: some View {
        Picker("Threads", selection: $filter) {
            ForEach(HomeThreadFilter.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Filter threads")
    }
}

struct DesktopOverviewControls: View {
    @Environment(AppModel.self) private var model
    @AppStorage("macSidebarCards") private var cards = false
    var body: some View {
        HStack(spacing: 8) {
            Picker("Sidebar view", selection: $cards) {
                Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Cards")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 86).help("List or cards")
            Spacer()
            Button { model.showingHome = true; model.showingSettings = false } label: {
                Label("Home", systemImage: "house")
            }.buttonStyle(.borderless).help("Full-window thread overview")
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.home = $0 }
            #endif
        }
    }
}

#if DEBUG
@MainActor enum MacHomeDebug {
    static var cards: [UUID: CGRect] = [:]
    static var home: CGRect = .zero
    static var tabs: [HomeThreadPage: CGRect] = [:]
}
#endif
