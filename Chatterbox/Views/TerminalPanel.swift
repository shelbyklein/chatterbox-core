import AppKit
import SwiftTerm
import SwiftUI

/// A real terminal (your login shell, in the chat's folder) that slides up from the bottom of
/// the chat: for commands only you can run, like signing in. Each chat keeps its own, so its
/// history and anything still running survive switching chats and closing the panel. ⌃`
/// shows or hides it; a shell command in a reply can be put into it with Run in Terminal.
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()
    private var terminals: [UUID: ChatTerminal] = [:]

    func terminal(for session: ChatSession) -> ChatTerminal {
        if let existing = terminals[session.id], existing.isAlive { return existing }
        let terminal = ChatTerminal(folder: session.workingFolder)
        terminals[session.id] = terminal
        return terminal
    }

    func restart(_ session: ChatSession) {
        terminals[session.id]?.view.terminate()
        terminals[session.id] = nil
    }
}

/// One shell and its view.
@MainActor
final class ChatTerminal: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    private(set) var isAlive = true
    private let started = Date()
    private var startupDirectory: URL?
    var onExit: (() -> Void)?

    init(folder: String) {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        view.caretColor = .systemGray
        // A readable ANSI palette on the embedded terminal's dark background.
        let ansiRGB: [Int] = [
            0x20242B, 0xF07178, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCE1E8,
            0x687585, 0xFF9299, 0xB5E890, 0xFFD68A,
            0x8ACBFF, 0xE0A3F3, 0x7ADBE6, 0xFFFFFF
        ]
        view.installColors(ansiRGB.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 255) * 257, green: UInt16((rgb >> 8) & 255) * 257, blue: UInt16(rgb & 255) * 257)
        })
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        var env = BinaryLocator.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["CLICOLOR"] = "1"
        // Forward the user's normal zsh startup files, then style only this
        // embedded session. Never edit ~/.zshrc or replace their login setup.
        if (shell as NSString).lastPathComponent == "zsh" {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-zsh-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                startupDirectory = directory
                env["CHATTERBOX_ZSH_USER_DIR"] = env["ZDOTDIR"] ?? NSHomeDirectory()
                env["CHATTERBOX_ZSH_STARTUP_DIR"] = directory.path
                env["ZDOTDIR"] = directory.path
                for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
                    var script = "ZDOTDIR=\"$CHATTERBOX_ZSH_USER_DIR\"\n[[ -r \"$CHATTERBOX_ZSH_USER_DIR/\(file)\" ]] && source \"$CHATTERBOX_ZSH_USER_DIR/\(file)\"\nCHATTERBOX_ZSH_USER_DIR=\"$ZDOTDIR\"\nZDOTDIR=\"$CHATTERBOX_ZSH_STARTUP_DIR\"\n"
                    if file == ".zshrc" || file == ".zlogin" {
                        script += "PROMPT='%F{green}%n%f %F{cyan}%1~%f %F{yellow}%#%f '\n"
                    }
                    try script.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
                }
            } catch {
                // A failed optional prompt setup must not prevent opening a shell.
                if let startupDirectory { try? FileManager.default.removeItem(at: startupDirectory) }
                startupDirectory = nil
                if let original = env["CHATTERBOX_ZSH_USER_DIR"], original != NSHomeDirectory() { env["ZDOTDIR"] = original }
                else { env.removeValue(forKey: "ZDOTDIR") }
                env.removeValue(forKey: "CHATTERBOX_ZSH_USER_DIR")
                env.removeValue(forKey: "CHATTERBOX_ZSH_STARTUP_DIR")
            }
        }
        // A login shell, so the PATH and prompt are the ones you know from Terminal.
        view.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent,
                          currentDirectory: FileManager.default.fileExists(atPath: folder) ? folder : NSHomeDirectory())
    }

    /// Types a command at the prompt without running it: you press Return.
    func type(_ command: String) {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // A shell that's just starting would echo it before its prompt: wait for it to settle.
        let wait = max(0, 1.2 - Date().timeIntervalSince(started))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.view.send(txt: line) }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.isAlive = false
            if let directory = self.startupDirectory {
                try? FileManager.default.removeItem(at: directory)
                self.startupDirectory = nil
            }
            self.onExit?()
        }
    }
}

/// The panel: a slim bar (folder, restart, close) above the terminal, with a handle to
/// drag it taller or shorter.
struct TerminalPanel: View {
    let session: ChatSession
    let onClose: () -> Void
    /// A command to type in once the terminal is up, then cleared.
    @Binding var pending: String?
    @AppStorage("terminalPanelHeight") private var height = 260.0
    @State private var dragStart: Double?
    @State private var generation = 0
    @State private var exited = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag to resize.
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                    let start = dragStart ?? height
                    if dragStart == nil { dragStart = start }
                    height = min(max(start - drag.translation.height, 120), 700)
                }.onEnded { _ in dragStart = nil })
                .accessibilityLabel("Resize terminal")
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text((session.workingFolder as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                if exited { Text("Shell ended").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button { TerminalStore.shared.restart(session); exited = false; generation += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Start a new shell")
                .accessibilityLabel("Restart terminal")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("Hide the terminal (\u{2303}`). It keeps running.")
                    .accessibilityLabel("Hide terminal")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            TerminalHost(session: session, pending: $pending, exited: $exited)
                .id(generation)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .frame(height: height)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1)))
        .environment(\.colorScheme, .dark)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: ChatSession
    @Binding var pending: String?
    @Binding var exited: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.isEmpty { attach(to: container) }
        if let command = pending {
            let terminal = TerminalStore.shared.terminal(for: session)
            DispatchQueue.main.async {
                terminal.type(command)
                pending = nil
                container.window?.makeFirstResponder(terminal.view)
            }
        }
    }

    private func attach(to container: NSView) {
        let terminal = TerminalStore.shared.terminal(for: session)
        terminal.onExit = { exited = true }
        let view = terminal.view
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
    }
}
