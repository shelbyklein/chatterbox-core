import SwiftUI

/// Golem's message bar keeps the technical controls out of sight, like iMessage: access,
/// quick switches, and the model live behind this cog. A small orange dot on it means the
/// agent may act without asking. ⌘⇧M and the mode shortcut open it too.
struct ChatSettingsCog: View {
    let session: ChatSession
    var modelRequest = 0
    var modeRequest = 0
    var handlesKeyboardRequest: () -> Bool = { true }
    @State private var isOpen = false
    @State private var page = Page.main

    enum Page { case main, model }

    var body: some View {
        Button { page = .main; isOpen.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if session.mode.isUnrestricted {
                        Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: -3, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Chat settings: access \u{00B7} \(session.mode.title)")
        .accessibilityLabel("Chat Settings")
        .accessibilityValue(session.mode.isUnrestricted ? "\(session.mode.title), unrestricted" : session.mode.title)
        .onChange(of: modelRequest) { if handlesKeyboardRequest() { page = .model; isOpen = true } }
        .onChange(of: modeRequest) { if handlesKeyboardRequest() { page = .main; isOpen = true } }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            // Keep the hosting root, both pages and its size stable. Replacing the root
            // with a wider model page can leave SwiftUI's popover content at the old origin.
            ZStack(alignment: .top) {
                ScrollView { main }
                    .opacity(page == .main ? 1 : 0)
                    .allowsHitTesting(page == .main)
                    .disabled(page != .main)
                    .accessibilityHidden(page != .main)
                ModelPopover(session: session) { page = .main }
                    .opacity(page == .model ? 1 : 0)
                    .allowsHitTesting(page == .model)
                    .disabled(page != .model)
                    .accessibilityHidden(page != .model)
            }
            .frame(width: ModelPopover.size.width, height: ModelPopover.size.height)
            .fixedSize()
            .task(id: page) {
                guard page == .model else { return }
                await ClaudeModels.shared.refresh()
                if CodexAppServer.shared.models.isEmpty { try? await CodexAppServer.shared.refreshModels() }
            }
        }
    }

    var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            RestartThreadControl(session: session)
            ThreadRestartStatus(session: session)
            Divider()
            if session.supportsFastMode {
                Toggle("Fast mode", isOn: Binding(get: { session.fastMode },
                                                 set: { session.setFastMode($0) }))
                    .toggleStyle(.switch)
                Text(session.fastModeNote)
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            section("Access") {
                ForEach(PermissionModes.modes(for: session.record.backend)) { mode in
                    row(selected: mode.id == session.mode.id) {
                        session.setMode(mode.id)
                    } label: {
                        Image(systemName: mode.systemImage).frame(width: 18)
                            .foregroundStyle(mode.isUnrestricted ? Color.orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            section("Quick Switch") {
                ForEach(ModelPresets.shared.presets) { preset in
                    row(selected: false) { ModelPresets.shared.apply(preset, to: session) } label: {
                        Image(systemName: "bolt").frame(width: 18).foregroundStyle(.secondary)
                        Text(preset.title)
                    }
                }
            }
            Divider()
            row(selected: false) { page = .model } label: {
                Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                Text("Model and Effort\u{2026}")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: ModelPopover.size.width)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
            content()
        }
    }

    private func row(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.highlight.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shared by the Chat menu, sidebar menus, Golem settings and mini options.
struct RestartThreadControl: View {
    let session: ChatSession
    var body: some View {
        Button {
            Task { await session.restartThread() }
        } label: {
            Label(session.isRestartingThread ? "Restarting Thread…" : session.isRunning ? "Stop and Restart Thread" : "Restart Thread",
                  systemImage: "arrow.clockwise")
        }
        .disabled(session.isRestartingThread || session.awaitingHostResume)
        .help("Reconnect this thread, keeping its history and draft. Stops its current reply without resending anything.")
    }
}

struct ThreadRestartStatus: View {
    let session: ChatSession
    var body: some View {
        if session.isRestartingThread || session.threadRestartStatus != nil {
            HStack(alignment: .top, spacing: 8) {
                if session.isRestartingThread { ProgressView().controlSize(.small) }
                Text(session.isRestartingThread ? "Restarting thread…" : session.threadRestartStatus ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !session.isRestartingThread {
                    Button { session.threadRestartStatus = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss restart status")
                }
            }
        }
    }
}
