import SwiftUI

/// The model button (under the message box and in the toolbar) and its popover: Claude and
/// Codex models in tabs, effort as a slider, and presets.
struct ModelPicker: View {
    let session: ChatSession
    /// Toolbar style: an icon and "Model". Otherwise the full summary with the agent's color.
    var compact = false
    let summary: String
    let color: Color
    /// Bumped by Chat → Choose Model (⌘⇧M) to toggle the popover.
    var openRequest = 0
    var handlesKeyboardRequest: () -> Bool = { true }
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            if compact {
                Label("Model", systemImage: "cpu")
            } else {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    // Truncates rather than disappearing when space is tight.
                    Text(summary).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(compact ? AnyButtonStyle(.automatic) : AnyButtonStyle(.plain))
        .help(summary + ". Click to change (\u{2318}\u{21E7}M).")
        .onChange(of: openRequest) {
            if isOpen || handlesKeyboardRequest() { isOpen.toggle() }
        }
        .popover(isPresented: $isOpen, arrowEdge: compact ? .bottom : .top) {
            ModelPopover(session: session) { isOpen = false }
        }
        .task { await ClaudeModels.shared.refresh() }
        .task { if CodexAppServer.shared.models.isEmpty { try? await CodexAppServer.shared.refreshModels() } }
    }
}

/// Lets `ModelPicker` switch between plain (status line) and default (toolbar) button styles.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct ModelPopover: View {
    let session: ChatSession
    let close: () -> Void
    @State private var tab: Backend
    @State private var showHidden = false

    /// Opens on the chat's own agent, so the first layout (which sizes the popover) is the
    /// one you see.
    init(session: ChatSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        _tab = State(initialValue: session.record.backend)
    }

    /// One size whatever the tab, notices, or model lists: NSPopover resizing after it's on
    /// screen can leave the content shifted past its edge. The model list takes up the slack.
    static let size = CGSize(width: 380, height: 600)

    private var catalog: ClaudeModels { .shared }
    private var codexModels: [CodexModelInfo] { CodexAppServer.shared.models }
    private var active: Backend { session.record.backend }
    private var locked: Bool { session.isRunning && tab != active }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Agent", selection: $tab) {
                ForEach(Backend.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if locked {
                Label("Switching agents waits until the current reply finishes.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if tab == .claude { claudeRows } else { codexRows }
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)

            Divider()
            effortSection
            if tab == active, session.supportsFastMode {
                Toggle("Fast mode", isOn: Binding(get: { session.fastMode },
                                                 set: { session.setFastMode($0) }))
                    .toggleStyle(.switch)
                    .disabled(locked)
                Text(session.fastModeNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tab == .codex { connectionSection }
            Divider()

            HStack {
                Button("Save as Preset") { savePreset() }
                Spacer()
                Button("Refresh Lists") {
                    Task {
                        await catalog.refresh(force: true)
                        try? await CodexAppServer.shared.refreshModels()
                    }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .onChange(of: session.record.backend) { _, backend in tab = backend }
    }

    // MARK: - Models

    private var claudeCurrent: ClaudeCodeModel { catalog.info(session.record.model) }

    private var claudeRows: some View {
        let current = claudeCurrent
        let models = catalog.models.contains { $0.value == current.value } ? catalog.models : [current] + catalog.models
        return ForEach(models) { m in
            row(title: m.displayName, detail: m.detail, selected: active == .claude && m.value == current.value) {
                session.setBackend(.claude)
                session.setModel(m.value)
            }
        }
    }

    @ViewBuilder
    private var codexRows: some View {
        let chosen = session.record.codex?.model
        let fallback = codexModels.first(where: \.isDefault)?.displayName
        row(title: "Codex default", detail: fallback.map { "Currently \($0)" } ?? "", selected: active == .codex && chosen == nil) {
            session.setBackend(.codex)
            session.setCodexModel(nil)
        }
        ForEach(codexModels.filter { !$0.hidden || $0.model == chosen }) { m in
            row(title: m.displayName, detail: "", selected: active == .codex && chosen == m.model) {
                session.setBackend(.codex)
                session.setCodexModel(m.model)
            }
        }
        let hidden = codexModels.filter { $0.hidden && $0.model != chosen }
        if !hidden.isEmpty {
            DisclosureGroup("More models", isExpanded: $showHidden) {
                ForEach(hidden) { m in
                    row(title: m.displayName, detail: "Hidden from Codex's own picker", selected: false) {
                        session.setBackend(.codex)
                        session.setCodexModel(m.model)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    private func row(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
                    .foregroundStyle(Color.highlight).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.highlight.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    // MARK: - Connection

    /// Direct through ChatGPT (hosted tools like image generation) or through EasyCLIProxy,
    /// for this chat only. Golem always connects directly when he can.
    @ViewBuilder
    private var connectionSection: some View {
        if !session.isDot {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Connection").font(.callout.weight(.medium))
                    Spacer()
                    Picker("Connection", selection: Binding(get: { session.codexRoute?.rawValue ?? "" },
                                                            set: { session.setCodexRoute(CodexRoute(rawValue: $0)) })) {
                        Text("Default").tag("")
                        Text(CodexRoute.direct.title).tag(CodexRoute.direct.rawValue)
                            .disabled(!EasyCLIProxy.codexHasChatGPTSignIn)
                        Text(CodexRoute.proxy.title).tag(CodexRoute.proxy.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(active != .codex || locked)
                }
                Text(session.codexConnection.summary + (session.codexRoute != nil ? " Switching keeps this conversation." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Effort

    /// "" (the model's default) and then each level the tab's model supports, lowest first.
    private var stops: [String] {
        switch tab {
        case .claude:
            return [""] + claudeCurrent.efforts
        case .codex:
            let current = codexModels.first { $0.model == session.record.codex?.model } ?? codexModels.first(where: \.isDefault)
            return [""] + (current?.efforts ?? ["low", "medium", "high"])
        }
    }

    private var effort: String {
        tab == .claude ? session.record.effort : session.record.codex?.effort ?? ""
    }

    private func setEffort(_ value: String) {
        switch tab {
        case .claude: session.setEffort(value)
        case .codex: session.setCodexEffort(value.isEmpty ? nil : value)
        }
    }

    private var defaultEffortName: String {
        switch tab {
        case .claude: return "Default"
        case .codex:
            let current = codexModels.first { $0.model == session.record.codex?.model } ?? codexModels.first(where: \.isDefault)
            return current.map { "Default (\(ChatView.effortLabel($0.defaultEffort)))" } ?? "Default"
        }
    }

    private func name(_ stop: String) -> String { stop.isEmpty ? defaultEffortName : ChatView.effortLabel(stop) }

    @ViewBuilder
    private var effortSection: some View {
        let stops = self.stops
        if stops.count <= 1 || (tab == .codex && session.record.codex == nil) {
            Text(tab == .codex && session.record.codex == nil ? "Pick a Codex model to set its effort." : "This model has no effort setting.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            let index = Double(stops.firstIndex(of: effort) ?? 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Effort").font(.callout.weight(.medium))
                    Spacer()
                    Text(name(stops[Int(index)])).font(.callout).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { index }, set: { setEffort(stops[Int($0.rounded())]) }),
                       in: 0...Double(stops.count - 1), step: 1)
                // Labels under each stop, spread to match the slider's ticks.
                HStack(spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                        Text(stop.isEmpty ? "Default" : ChatView.effortLabel(stop).replacingOccurrences(of: "Extra High", with: "X-High"))
                            .font(.system(size: 9))
                            .foregroundStyle(i == Int(index) ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : i == stops.count - 1 ? .trailing : .center)
                    }
                }
            }
            .disabled(locked)
        }
    }

    // MARK: - Presets

    private func savePreset() {
        let record = session.record
        let title: String
        if record.backend == .claude {
            let m = catalog.info(record.model)
            title = m.displayName + (record.effort.isEmpty ? "" : " \u{00B7} \(ChatView.effortLabel(record.effort))")
        } else {
            let m = codexModels.first { $0.model == record.codex?.model }
            title = (m?.displayName ?? "Codex") + (record.codex?.effort.map { " \u{00B7} \(ChatView.effortLabel($0))" } ?? "")
        }
        ModelPresets.shared.saveCurrent(session, title: title)
        close()
    }
}
