import AppKit
import SwiftUI

/// The open chat, as the window toolbar sees it (#29).
///
/// The chat view is rebuilt on every switch (`.id(session.id)`), and SwiftUI rebuilds every
/// toolbar item whose content changes, re-hosting each in AppKit and re-laying out the
/// toolbar: about a third of a switch. So the toolbar lives outside the chat view, and its
/// items hold only this bridge, which never changes. Each item reads the chat from here and
/// updates in place, inside its own hosting view, when you switch.
@MainActor
@Observable
final class ChatToolbarBridge {
    private(set) var session: ChatSession?
    private(set) var issuesPanel: IssuesPanelState?
    @ObservationIgnored private(set) var showImages: () -> Void = {}
    @ObservationIgnored private(set) var toggleTerminal: () -> Void = {}
    @ObservationIgnored private(set) var chooseProject: () -> Void = {}

    /// Every chat view on screen that registered, newest last. Two can overlap: during a
    /// switch's fade, or when the chat restored at launch is replaced at once. The newest one
    /// drives the toolbar, and when it goes the one still showing takes over again.
    private struct Registration {
        let owner: UUID
        let session: ChatSession
        let issuesPanel: IssuesPanelState
        let showImages: () -> Void
        let toggleTerminal: () -> Void
        let chooseProject: () -> Void
    }
    @ObservationIgnored private var registrations: [Registration] = []

    func attach(_ session: ChatSession, owner: UUID, issuesPanel: IssuesPanelState,
                showImages: @escaping () -> Void, toggleTerminal: @escaping () -> Void, chooseProject: @escaping () -> Void) {
        registrations.removeAll { $0.owner == owner }
        registrations.append(Registration(owner: owner, session: session, issuesPanel: issuesPanel, showImages: showImages,
                                          toggleTerminal: toggleTerminal, chooseProject: chooseProject))
        apply()
    }

    /// A chat view went away.
    func detach(owner: UUID) {
        guard registrations.contains(where: { $0.owner == owner }) else { return }
        registrations.removeAll { $0.owner == owner }
        apply()
    }

    private func apply() {
        let current = registrations.last
        showImages = current?.showImages ?? {}
        toggleTerminal = current?.toggleTerminal ?? {}
        chooseProject = current?.chooseProject ?? {}
        if session !== current?.session { session = current?.session }
        if issuesPanel !== current?.issuesPanel { issuesPanel = current?.issuesPanel }
    }

    // What changes the toolbar's set of items. These are the same for most switches, so the
    // items themselves are kept; only a different kind of chat adds or removes one.
    var hasChat: Bool { session != nil }
    var isDot: Bool { session?.isDot == true }
    var isClaude: Bool { session?.record.backend == .claude }
}

private struct ChatToolbarBridgeKey: EnvironmentKey {
    static let defaultValue: ChatToolbarBridge? = nil
}

extension EnvironmentValues {
    /// The window's toolbar bridge, when the window draws the chat's toolbar itself.
    var chatToolbarBridge: ChatToolbarBridge? {
        get { self[ChatToolbarBridgeKey.self] }
        set { self[ChatToolbarBridgeKey.self] = newValue }
    }
}

/// The chat's controls in the window toolbar. Every item's only input is the bridge.
struct ChatToolbarContent: ToolbarContent {
    let bridge: ChatToolbarBridge

    var body: some ToolbarContent {
        if bridge.hasChat {
            if bridge.isDot { ToolbarItem { ToneSlot(bridge: bridge) } }
            #if !GOLEM_APP
            if bridge.isDot {
                ToolbarItem { PlaceSlot(bridge: bridge) }
                ToolbarItem { RepoSlot(bridge: bridge) }
            }
            #endif
            if bridge.isDot {
                ToolbarItem { GolemSlot(bridge: bridge) }
            }
            #if !GOLEM_APP
            if bridge.isClaude {
                ToolbarItem { RemoteSlot(bridge: bridge) }
            }
            #endif
            if bridge.isDot { ToolbarItem { ImagesSlot(bridge: bridge) } }
            #if !GOLEM_APP
            ToolbarItem { TerminalSlot(bridge: bridge) }
            #endif
        }
    }
}

/// Controls for the open session live inside its chat, beside Notes and prompt presets.
/// The session's Brief: the assignment, the tools to use, the key files, which both agents
/// always get. Filled once set (its text in the tooltip); click to write, change or clear it.
struct BriefButton: View {
    let session: ChatSession
    @State private var open = false
    @State private var text = ""
    @Environment(\.colorScheme) private var scheme
    private var brief: String { session.record.brief ?? "" }

    var body: some View {
        Button { text = brief; open.toggle() } label: {
            Image(systemName: brief.isEmpty ? "doc.text" : "doc.text.fill")
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(brief.isEmpty ? Color.secondary : Color.primary)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .help(brief.isEmpty ? "Brief: what this session is for, the tools to use, the key files. Both agents get it." : "Brief: \(brief)")
        .accessibilityLabel(brief.isEmpty ? "Brief, not set" : "Brief: \(brief)")
        .popover(isPresented: $open, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Session brief").font(.headline)
                Text("The assignment, the tools to use (an MCP server, say) and the key files. Claude and Codex both get it, and keep it across an agent switch.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.body).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 140)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Brief")
                HStack {
                    if !brief.isEmpty { Button("Clear", role: .destructive) { session.setBrief(""); open = false } }
                    Spacer()
                    Button("Cancel") { open = false }.keyboardShortcut(.cancelAction)
                    Button("Save") { session.setBrief(text); open = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines) == brief)
                }
                Text("It reaches the agent with your next message.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16).frame(width: 380)
        }
    }
}

/// The session's (or project's) notes, behind an icon with their count.
struct NotesButton: View {
    let scope: String
    let project: Bool
    @State private var open = false
    @State private var store = PinnedNotesStore.shared
    @Environment(\.colorScheme) private var scheme
    private var count: Int { store.notes[scope]?.count ?? 0 }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "note.text")
                .frame(width: 36, height: 32).contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.accentColor)).offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .help(project ? "Project notes" : "Session notes")
        .accessibilityLabel((project ? "Project notes" : "Session notes") + (count > 0 ? ", \(count)" : ""))
        .popover(isPresented: $open, arrowEdge: .leading) {
            ChatNotes(scope: scope, project: project, panelWidth: 300)
        }
    }
}

/// The session's button column: every control the same 36×32 tile.
enum SideIcon {
    struct Tile: ViewModifier {
        @Environment(\.colorScheme) private var scheme
        func body(content: Content) -> some View {
            content
                .frame(width: 36, height: 32).contentShape(Rectangle())
                .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        }
    }
    /// A menu as a tile, without its arrow.
    struct MenuStyle: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(Tile())
            } else {
                content
            }
        }
    }
}

/// The repository and its issues, behind a branch icon (sessions in a GitHub repo).
struct RepoButton: View {
    let bridge: ChatToolbarBridge
    @State private var open = false

    var body: some View {
        if let session = bridge.session, bridge.issuesPanel != nil,
           let status = GitStatusStore.shared.status(for: session.record.projectFolder),
           let repo = status.remote(preferring: session.record.gitRemote)?.repo {
            Button { open.toggle() } label: { Image(systemName: "arrow.triangle.branch") }
                .buttonStyle(.plain).modifier(SideIcon.Tile())
                .help("\(repo)\(status.branch.map { " · " + $0 } ?? ""): branch, remote and issues")
                .accessibilityLabel("Repository")
                .popover(isPresented: $open, arrowEdge: .leading) { RepoSlot(bridge: bridge).padding(14) }
        }
    }
}

/// The tools (MCP servers, connectors, skills) this session gets, behind a puzzle piece.
struct ToolsButton: View {
    let session: ChatSession
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "puzzlepiece.extension") }
            .buttonStyle(.plain).modifier(SideIcon.Tile())
            .help("Tools: MCP servers, connectors and skills for this session")
            .accessibilityLabel("Tools")
            .popover(isPresented: $open, arrowEdge: .leading) { SessionToolsSummary(session: session).padding(16).frame(width: 320) }
    }
}

struct SessionImages: View {
    let bridge: ChatToolbarBridge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { bridge.showImages() } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .help("Library: the images and files this session made or shared")
        .accessibilityLabel("Library")
    }
}

struct ToneSlot: View {
    let bridge: ChatToolbarBridge
    var body: some View {
        if let session = bridge.session { ToneMenu(session: session) }
    }
}

/// The project folder, or the Studio the chat is in.
struct PlaceSlot: View {
    let bridge: ChatToolbarBridge
    /// Just an icon, for the session's button column.
    var iconOnly = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = bridge.session {
            if let studio = model.studio(for: session) { studioButton(studio, session) } else { projectButton(session) }
        }
    }

    private func projectButton(_ session: ChatSession) -> some View {
        Menu {
            Button(session.record.projectFolder == nil ? "Bind to Folder\u{2026}" : "Change Folder\u{2026}") { bridge.chooseProject() }
            if let folder = session.record.projectFolder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                Button("Open Terminal Here  \u{2325}\u{2318}T") { model.openTerminal() }
                Divider()
                Button("Edit AGENTS.md") { openForEditing(folder + "/AGENTS.md") }
                Button("Edit CLAUDE.md") { openForEditing(folder + "/CLAUDE.md") }
                Divider()
                Button("Unbind from Folder") { session.unbindProject() }
            }
        } label: {
            if iconOnly { Image(systemName: session.record.projectFolder == nil ? "folder.badge.plus" : "folder.fill") }
            else {
                ToolbarLabel(session.record.projectFolder == nil ? "No Project" : session.projectName,
                             systemImage: session.record.projectFolder == nil ? "folder.badge.plus" : "folder.fill")
            }
        }
        .modifier(SideIcon.MenuStyle(enabled: iconOnly))
        .help(session.record.projectFolder.map { "This session is bound to \($0). Claude and Codex work in this folder." }
              ?? "Bind this chat to a project folder so Claude or Codex can work in it. Each folder gets one chat.")
    }

    private func studioButton(_ studio: Studio, _ session: ChatSession) -> some View {
        Menu {
            Button("Studio Instructions\u{2026}") { model.editingStudioInstructions = studio.id }
            Button("Fork This Session") { model.fork(session) }
                .disabled(!model.canFork(session))
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: studio.folder)]) }
            Button("Open Terminal Here  \u{2325}\u{2318}T") { model.openTerminal() }
            Divider()
            Button("Edit design.md") { studio.ensureDesignFile(); openForEditing(studio.designFile) }
            Button("Edit AGENTS.md") { openForEditing(studio.folder + "/AGENTS.md") }
            Button("Edit CLAUDE.md") { openForEditing(studio.folder + "/CLAUDE.md") }
            Divider()
            Button("Remove from Studio") { model.move(session, to: nil) }
                .disabled(session.isRunning)
        } label: {
            if iconOnly { Image(systemName: "paintpalette") } else { ToolbarLabel(studio.name, systemImage: "paintpalette") }
        }
        .modifier(SideIcon.MenuStyle(enabled: iconOnly))
        .help("This session is in the \(studio.name) Studio. Its sessions share \(studio.folder).")
    }
}

/// The GitHub repo chip and issue controls, for a chat in a repository.
struct RepoSlot: View {
    let bridge: ChatToolbarBridge

    var body: some View {
        if let session = bridge.session, let panel = bridge.issuesPanel,
           let status = GitStatusStore.shared.status(for: session.record.projectFolder),
           let remote = status.remote(preferring: session.record.gitRemote), let repo = remote.repo {
            HStack(spacing: 8) {
                RepoChip(repo: repo, remote: remote, status: status, folder: session.record.projectFolder ?? "",
                         onSelectRemote: session.setGitRemote, onShowIssues: { panel.show() })
                IssueToolbarItems(session: session, panel: panel, repo: repo, branch: status.branch)
            }
        }
    }
}

struct GolemSlot: View {
    let bridge: ChatToolbarBridge
    @Environment(AppModel.self) private var model
    @AppStorage("golemActivityExpanded") private var golemPanelOpen = false

    var body: some View {
        if let session = bridge.session, session.isDot {
            HStack(spacing: 8) {
                Button { withAnimation(.smooth(duration: 0.25)) { golemPanelOpen.toggle() } } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(golemPanelOpen ? "Hide \(session.title)\u{2019}s activity, decisions and schedule" : "Show \(session.title)\u{2019}s activity, decisions and schedule")
                .accessibilityLabel("\(session.title) Panel")
                Button { model.showingDot = true } label: { ToolbarLabel("Mini", systemImage: "pip") }
                    .help("Keep \(session.title) above other apps (⌘J)")
                Button { model.editingDotMemory = true } label: { ToolbarLabel("Memory", systemImage: "brain") }
                    .help("What Dot remembers about you and your work (MEMORY.md)")
            }
        }
    }
}

/// Remote Control: whether this chat can be opened on claude.ai and in the Claude app.
struct RemoteSlot: View {
    let bridge: ChatToolbarBridge

    var body: some View {
        if let session = bridge.session, session.record.backend == .claude {
            Menu {
                if let url = session.remoteURL {
                    Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Divider()
                    Button("Turn Off Remote Control") { session.setRemoteControl(false) }
                } else if session.wantsRemoteControl {
                    Text("Connecting\u{2026}")
                    Button("Turn Off Remote Control") { session.setRemoteControl(false) }
                } else {
                    Button("Turn On Remote Control") { session.setRemoteControl(true) }
                }
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(session.remoteURL != nil ? Color.green : Color.secondary)
            }
            .help(session.remoteURL != nil
                  ? "Remote Control is on: this session is on claude.ai and in the Claude app."
                  : "Remote Control: open this session on claude.ai or in the Claude app")
        }
    }
}

struct ImagesSlot: View {
    let bridge: ChatToolbarBridge
    var body: some View {
        Button { bridge.showImages() } label: { Image(systemName: "photo.on.rectangle.angled") }
            .help("Every image made in this session").accessibilityLabel("Images")
    }
}

struct TerminalSlot: View {
    let bridge: ChatToolbarBridge
    var body: some View {
        Button { bridge.toggleTerminal() } label: { Image(systemName: "terminal") }
            .help("A terminal in this session's folder, at the bottom of the window (\u{2303}`)").accessibilityLabel("Terminal")
    }
}

/// The toolbar for a chat in a window that doesn't draw one itself.
struct OwnChatToolbar: ViewModifier {
    let enabled: Bool
    let bridge: ChatToolbarBridge
    func body(content: Content) -> some View {
        if enabled {
            content
                .toolbar { ChatToolbarContent(bridge: bridge) }
                .background { WindowToolbarShortcuts(bridge: bridge) }
        } else { content }
    }
}
