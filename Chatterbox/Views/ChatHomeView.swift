import ImageIO
import SwiftUI

/// Shared by the compact sidebar and full-window overview. Opening a card selects the
/// existing session; it never creates, copies or submits a conversation.
private struct ThreadCardScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// Home's card size (its slider): every size in a thread's card or tile is multiplied by it.
    var threadCardScale: CGFloat {
        get { self[ThreadCardScaleKey.self] }
        set { self[ThreadCardScaleKey.self] = newValue }
    }
}

struct ThreadCard: View {
    let session: ChatSession
    var expanded = false
    var iconOnly = false
    var selected = false
    var showsThumbnail = false
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.threadCardScale) private var scale
    @AppStorage(ProjectSort.key) private var projectSort = ProjectSort.recent.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    private let appearance = ReaderStyleSettings()

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
    private var tint: Color { appearance.style.color(for: session.record.provider) }
    @ViewBuilder private var activityIndicator: some View {
        if session.isRunning {
            ActivitySpinner(color: tint).frame(width: 10, height: 10)
                .help("\(session.record.provider.label) is working")
        } else {
            Circle().fill(session.isWaitingOnYou ? .orange : Attention.shared.unread.contains(session.id) ? .blue : .secondary.opacity(0.4))
                .frame(width: 6, height: 6)
        }
    }
    // Cards are also used outside List, where listRowBackground cannot highlight them.
    // Waiting on the user takes priority over the selected-card appearance.
    private var cardBackground: Color {
        if session.isWaitingOnYou { return Color.yellow.opacity(colorScheme == .dark ? 0.22 : 0.18) }
        return selected ? .white : Color.primary.opacity(hovered ? 0.10 : 0.055)
    }
    private var preview: String {
        guard let text = session.items.last(where: { $0.kind == .assistant || $0.kind == .user })?.text else { return "No messages yet" }
        return ChatSession.firstSentence(of: text, limit: expanded ? 320 : 110) ?? "Open to view the conversation"
    }
    private var relation: String? {
        if session.record.automationID != nil { return "Automation" }
        if session.record.sidechatOf != nil { return "Temporary" }
        if let branch = session.record.worktreeBranch { return branch }
        return nil
    }

    private var backendIcon: some View {
        HStack(spacing: 5) {
            if let folder = session.record.projectFolder, let icon = ProjectIcons.shared.icons[folder] {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: (expanded ? 24 : 16) * scale, height: (expanded ? 24 : 16) * scale)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 5 : 3.5, style: .continuous))
            }
            Image(session.record.provider.iconName).resizable().scaledToFit()
                .frame(width: (expanded ? 19 : 13) * scale, height: (expanded ? 19 : 13) * scale)
                .foregroundStyle(tint)
                .accessibilityLabel(session.record.provider.label)
                .help(session.record.provider == session.record.backend ? session.record.provider.label : "Claude model via Codex")
        }
        .task(id: session.record.projectFolder) { ProjectIcons.shared.load(session.record.projectFolder) }
    }

    private var agentBadge: some View {
        Image(session.record.provider.iconName).resizable().scaledToFit()
            .foregroundStyle(tint).frame(width: 11 * scale, height: 11 * scale)
            .padding(4)
            .background(Circle().fill(Color.black.opacity(0.72)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
            .padding(4)
    }

    /// The project's logo, else the thread's newest image, with its agent in the corner; else the agent.
    @ViewBuilder private var tileFace: some View {
        if let folder = session.record.projectFolder, let icon = ProjectIcons.shared.icons[folder] {
            // A project's logo comes first: it says which project at a glance.
            Image(nsImage: icon).resizable().scaledToFit()
                .frame(width: 44 * scale, height: 44 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 64 * scale, height: 64 * scale)
                .overlay(alignment: .bottomTrailing) { agentBadge }
        } else if let thumbnail = ThreadThumbnails.shared.images[session.id] {
            Image(nsImage: thumbnail).resizable().scaledToFill()
                .frame(width: 64 * scale, height: 64 * scale)
                .overlay(alignment: .bottomTrailing) { agentBadge }
        } else {
            Image(session.record.provider.iconName).resizable().scaledToFit()
                .foregroundStyle(tint).frame(width: 28 * scale, height: 28 * scale)
        }
    }

    var body: some View {
        Button(action: open) {
            if iconOnly {
                VStack(spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        tileFace
                            .frame(width: 64 * scale, height: 64 * scale)
                            .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(session.isWaitingOnYou ? Color.orange : Color.primary.opacity(0.16), lineWidth: session.isWaitingOnYou ? 2 : 1))
                        activityIndicator.padding(8)
                    }
                    Text(title).font(.system(size: 8.5 * scale, weight: .medium)).lineLimit(2)
                        .multilineTextAlignment(.center).frame(height: 24 * scale, alignment: .top)
                    if model.isPinnedThread(session) { SessionOriginLabel(session: session) }
                }.frame(width: 80 * scale, height: 94 * scale)
                    .task(id: session.record.projectFolder) { ProjectIcons.shared.load(session.record.projectFolder) }
                    .background(selected && !session.isWaitingOnYou ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
            } else {
            VStack(alignment: .leading, spacing: expanded ? 12 : 7) {
                HStack(spacing: 6) {
                    #if GOLEM_APP
                    if session.isDot { GolemHead(size: expanded ? 26 : 18) }
                    else { backendIcon }
                    #else
                    backendIcon
                    #endif
                    Spacer(minLength: 0)
                    if expanded { Text(status).font(.system(size: 10.5 * scale, weight: .medium)).lineLimit(1) }
                    activityIndicator
                }
                Text(title).font(.system(size: (expanded ? 15 : 11.5) * scale, weight: .semibold))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if model.isPinnedThread(session) { SessionOriginLabel(session: session) }
                if let relation {
                    Label(relation, systemImage: session.record.sidechatOf != nil ? "bubble.left.and.bubble.right" : "arrow.triangle.branch")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if expanded, let parentID = session.record.sidechatOf {
                    ParentThreadLabel(parentID: parentID)
                }
                // The same details as the sidebar list: tags, drift from main, and today's
                // turns while projects are sorted by Most Active.
                if !session.tags.isEmpty { TagPills(tags: session.tags) }
                if let status = GitStatusStore.shared.status(for: session.record.projectFolder), let drift = status.mainDriftText {
                    Label(drift, systemImage: "arrow.triangle.branch").font(.caption2).lineLimit(1)
                        .foregroundStyle((status.behindMain ?? 0) > 20 ? Color.orange : Color.secondary)
                }
                if projectSort == ProjectSort.active.rawValue, session.record.projectFolder != nil {
                    let today = session.activityRank.day
                    Label(expanded ? (today == 0 ? "No turns today" : "\(today) turn\(today == 1 ? "" : "s") today")
                                   : (today == 0 ? "None today" : "\(today) today"), systemImage: "flame")
                        .font(.caption2).lineLimit(1)
                        .help("\(today) turn\(today == 1 ? "" : "s") started in the last 24 hours")
                        .foregroundStyle(today == 0 ? Color.secondary : Color.orange)
                }
                Text(preview).font(.system(size: (expanded ? 13 : 10.5) * scale)).foregroundStyle(.secondary)
                    .lineLimit(expanded ? 4 : 2).frame(maxWidth: .infinity, alignment: .leading)
                if showsThumbnail, let thumbnail = ThreadThumbnails.shared.images[session.id] {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .frame(height: (expanded ? 100 : 56) * scale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("Latest image in " + title)
                }
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
            .padding((expanded ? 18 : 10) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Room for tags and status lines: a card grows to fit them.
            .frame(minHeight: (expanded ? 250 : 144) * scale)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(session.isWaitingOnYou ? Color.orange : Color.primary.opacity(hovered ? 0.28 : 0.12), lineWidth: session.isWaitingOnYou ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .buttonStyle(.plain)
        .task(id: (iconOnly || showsThumbnail) ? ThreadThumbnails.key(session) : "") {
            if iconOnly || showsThumbnail { ThreadThumbnails.shared.refresh(session) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !iconOnly {
                LinkedStudioShortcut(folder: session.record.projectFolder).padding(10 * scale)
            }
        }
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
    /// Whether a thread passes Home's search and All / Needs you / Working filter.
    static func matches(_ session: ChatSession, _ model: AppModel, search: String, filter: HomeThreadFilter) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let attention = session.isWaitingOnYou || Attention.shared.unread.contains(session.id)
        guard filter != .needsYou || attention, filter != .working || session.isRunning || session.hasBackgroundWork else { return false }
        return needle.isEmpty || [session.title, session.projectName, model.studio(for: session)?.name ?? "", session.record.worktreeBranch ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    static func groups(_ model: AppModel, search: String = "", filter: HomeThreadFilter = .all) -> [HomeThreadGroup] {
        var seen = Set<UUID>()
        func matching(_ session: ChatSession) -> Bool { matches(session, model, search: search, filter: filter) }
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
            let archived = model.archivedSessions.filter { matches($0, model, search: search, filter: filter) }
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

struct DesktopOverviewControls: View {
    @Environment(AppModel.self) private var model
    @AppStorage("macProjectsSidebarCards") private var projectsCards = true
    @AppStorage("macChatsSidebarCards") private var chatsCards = false
    @AppStorage("macStudioSidebarCards") private var studioCards = false
    private var cards: Binding<Bool> {
        Binding(get: { model.studioSidebarID != nil ? studioCards : model.showingChatsSidebar ? chatsCards : projectsCards },
                set: { if model.studioSidebarID != nil { studioCards = $0 } else if model.showingChatsSidebar { chatsCards = $0 } else { projectsCards = $0 } })
    }
    var body: some View {
        HStack(spacing: 8) {
            Picker("Sidebar view", selection: cards) {
                Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Cards")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 86).help("List or cards")
            Spacer()
        }
    }
}

#if DEBUG
@MainActor enum MacHomeDebug {
    /// Pinned cards and inspector rows, by thread.
    static var cards: [UUID: CGRect] = [:]
    /// Left-column entries: "pinned" or a Studio's id.
    static var entries: [String: CGRect] = [:]
    static var pinnedGroups: [String: CGRect] = [:]
    static var column: CGRect = .zero
    static var activity: CGRect = .zero
    static var preview: CGRect = .zero
    static var openChat: CGRect = .zero
    static var filter: CGRect = .zero
    /// The thread the inspector shows, and the pixel size of its preview image.
    static var inspected: UUID?
    static var listed: [UUID] = []
    static var previewPixels: CGSize = .zero
}
#endif


/// Each thread's newest image, as a small thumbnail for its Home tile: one it generated, one a
/// reply pointed to, or one you attached. Found from the end of the chat, only when the chat
/// has changed, and decoded small off the main thread.
@MainActor
@Observable
final class ThreadThumbnails {
    static let shared = ThreadThumbnails()
    private(set) var images: [UUID: NSImage] = [:]
    /// The same newest image decoded large, for Studios' preview cards and inspector.
    private(set) var largeImages: [UUID: NSImage] = [:]
    @ObservationIgnored private var keys: [UUID: String] = [:]
    @ObservationIgnored private var sources: [UUID: URL] = [:]
    @ObservationIgnored private var largeSources: [UUID: URL] = [:]
    static let largeSide = 1600

    /// Changes when the chat gains a row, not while a reply streams into the last one.
    static func key(_ session: ChatSession) -> String {
        "\(session.id)|\(session.items.count)|\(session.items.last?.id.uuidString ?? "")|\(session.items.last?.phase.rawValue ?? "")"
    }

    func refresh(_ session: ChatSession) {
        let key = Self.key(session)
        guard keys[session.id] != key else { return }
        keys[session.id] = key
        let id = session.id
        guard let url = session.latestThumbnailURL() else {
            sources[id] = nil
            largeSources[id] = nil
            if images[id] != nil { images[id] = nil }
            if largeImages[id] != nil { largeImages[id] = nil }
            return
        }
        guard sources[id] != url else { return }
        sources[id] = url
        Task.detached(priority: .utility) {
            let image = Self.thumbnail(url, side: 160)
            await MainActor.run {
                guard self.sources[id] == url else { return }
                self.images[id] = image
            }
        }
    }

    /// Decodes the newest image large, on demand: only cards and the inspector ask for it.
    func refreshLarge(_ session: ChatSession) {
        refresh(session)
        let id = session.id
        guard let url = sources[id], largeSources[id] != url else { return }
        largeSources[id] = url
        Task.detached(priority: .utility) {
            let image = Self.thumbnail(url, side: Self.largeSide)
            await MainActor.run {
                guard self.largeSources[id] == url else { return }
                self.largeImages[id] = image
            }
        }
    }

    nonisolated static func thumbnail(_ url: URL, side: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
