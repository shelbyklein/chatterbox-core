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
struct SessionTools: View {
    let bridge: ChatToolbarBridge
    @State private var open = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Image(systemName: "chevron.down").font(.caption2)
            }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .help("Session tools: tone, folder, images and repository")
        .accessibilityLabel("Session tools")
        .popover(isPresented: $open, arrowEdge: .top) {
            SessionToolsPanel(bridge: bridge).padding(16).frame(minWidth: 260, maxWidth: 420)
        }
    }
}

struct SessionToolsPanel: View {
    let bridge: ChatToolbarBridge
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session tools").font(.headline)
            ToneSlot(bridge: bridge)
            PlaceSlot(bridge: bridge)
            Button("Image Library", systemImage: "photo.on.rectangle.angled") { bridge.showImages() }
            RepoSlot(bridge: bridge)
        }
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
            ToolbarLabel(session.record.projectFolder == nil ? "No Project" : session.projectName,
                         systemImage: session.record.projectFolder == nil ? "folder.badge.plus" : "folder.fill")
        }
        .help(session.record.projectFolder.map { "This chat is bound to \($0). Claude and Codex work in this folder." }
              ?? "Bind this chat to a project folder so Claude or Codex can work in it. Each folder gets one chat.")
    }

    private func studioButton(_ studio: Studio, _ session: ChatSession) -> some View {
        Menu {
            Button("Studio Instructions\u{2026}") { model.editingStudioInstructions = studio.id }
            Button("Fork This Chat") { model.fork(session) }
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
            ToolbarLabel(studio.name, systemImage: "paintpalette")
        }
        .help("This chat is in the \(studio.name) Studio. Its chats share \(studio.folder).")
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
                  ? "Remote Control is on: this chat is on claude.ai and in the Claude app."
                  : "Remote Control: open this chat on claude.ai or in the Claude app")
        }
    }
}

struct ImagesSlot: View {
    let bridge: ChatToolbarBridge
    var body: some View {
        Button { bridge.showImages() } label: { Image(systemName: "photo.on.rectangle.angled") }
            .help("Every image made in this chat").accessibilityLabel("Images")
    }
}

struct TerminalSlot: View {
    let bridge: ChatToolbarBridge
    var body: some View {
        Button { bridge.toggleTerminal() } label: { Image(systemName: "terminal") }
            .help("A terminal in this chat's folder, at the bottom of the window (\u{2303}`)").accessibilityLabel("Terminal")
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
