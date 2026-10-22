import SwiftUI

/// The model button (under the message box and in the toolbar) and its popover: your
/// favorite models numbered (press 1–9), every model, and effort as a slider.
struct ModelPicker: View {
    let session: ChatSession
    /// Toolbar style: an icon and "Model". Otherwise the full summary with the agent's color.
    var compact = false
    /// Composer: the effort slider and the current model, which opens the picker.
    var selectionPill = false
    let summary: String
    let color: Color
    var details: String? = nil
    /// Bumped by Chat → Choose Model (⌘⇧M) to toggle the popover.
    var openRequest = 0
    var handlesKeyboardRequest: () -> Bool = { true }
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if selectionPill {
                HStack(spacing: 6) {
                    // Drag for effort here, or click the model for the list.
                    if !isOpen { ComposerEffortSlider(session: session, color: color).transition(.opacity) }
                    Button { isOpen.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(session.record.provider.iconName).resizable().scaledToFit().frame(width: 12, height: 12)
                                .foregroundStyle(color)
                            Text(summary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(color.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(color.opacity(0.65), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help((details ?? summary) + ". Click to change (\u{2318}\u{21E7}M).")
                    .accessibilityLabel("Model: \(summary)")
                }
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: isOpen)
            } else {
                Button { isOpen.toggle() } label: {
                    if compact {
                        Label("Model", systemImage: "cpu")
                    } else {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(summary).lineLimit(1).truncationMode(.tail)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                }
                .buttonStyle(compact ? AnyButtonStyle(.automatic) : AnyButtonStyle(.plain))
                .help(summary + ". Click to change (\u{2318}\u{21E7}M).")
            }
        }
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

/// Pick a model: click it or press its number among your favorites. Drag the effort below.
/// Nothing changes until the next message, so there's no confirm: click away, Esc or Return.
struct ModelPopover: View {
    let session: ChatSession
    let close: () -> Void
    @AppStorage("modelPopoverShowsAll") private var showsAll = false
    @State private var showHidden = false
    @FocusState private var focused: Bool

    init(session: ChatSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
    }

    /// One size whatever the lists: NSPopover resizing after it's on screen can leave the
    /// content shifted past its edge. The model list takes up the slack.
    static let size = CGSize(width: 380, height: 600)

    private var catalog: ClaudeModels { .shared }
    private var favorites: ModelFavorites { .shared }
    private var codexModels: [CodexModelInfo] { CodexAppServer.shared.models }
    private var active: Backend { session.record.backend }
    private var current: ModelChoice { ModelFavorites.current(session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.isRunning {
                Label("Switching agents waits until the current reply finishes.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    heading("Favorites")
                    if favorites.favorites.isEmpty {
                        Text("Star a model below to keep it here.").font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    ForEach(Array(favorites.favorites.enumerated()), id: \.element) { index, choice in
                        row(choice, detail: nil, number: index < 9 ? index + 1 : nil)
                    }
                    Button { withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() } } label: {
                        HStack {
                            Text("All models")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(showsAll ? 90 : 0))
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(.top, 4)
                    if showsAll {
                        heading("Claude")
                        claudeRows
                        heading("Codex").padding(.top, 6)
                        codexRows
                        openModelRows
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)

            Divider()
            runOnSection
            if session.record.openModel != nil {
                Text("Open models run on \(RemoteMachine.pc.name)'s graphics card at medium effort.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                effortSection
            }
            if session.supportsFastMode, session.record.openModel == nil {
                Toggle("Fast mode", isOn: Binding(get: { session.fastMode }, set: { session.setFastMode($0) }))
                    .toggleStyle(.switch)
                Text(session.fastModeNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if active == .codex, session.record.openModel == nil, session.runMachine == nil { connectionSection }
            Divider()
            HStack {
                Text("Applies from your next message.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Lists") {
                    Task {
                        await catalog.refresh(force: true)
                        try? await CodexAppServer.shared.refreshModels()
                    }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        // 1–9 picks a favorite; Return closes, as Esc does.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = Int(press.characters), digit >= 1, digit <= min(9, favorites.favorites.count) else { return .ignored }
            pick(favorites.favorites[digit - 1])
            return .handled
        }
        .onKeyPress(.return) { close(); return .handled }
        .task { await PCModels.shared.refresh() }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 2)
    }

    /// A model from the other agent can't be picked while a reply runs.
    private func locked(_ choice: ModelChoice) -> Bool { session.isRunning && choice.backend != active }

    private func pick(_ choice: ModelChoice) {
        guard !locked(choice) else { return }
        if session.record.openModel != nil { session.setOpenModel(nil) }
        favorites.choose(choice, for: session)
    }

    // MARK: - Models

    private var claudeCurrent: ClaudeCodeModel { catalog.info(session.record.model) }

    @ViewBuilder
    private var claudeRows: some View {
        let current = claudeCurrent
        let models = catalog.models.contains { $0.value == current.value } ? catalog.models : [current] + catalog.models
        ForEach(models) { m in
            row(ModelChoice(backend: .claude, model: m.value), detail: m.detail, number: nil)
        }
    }

    @ViewBuilder
    private var codexRows: some View {
        let chosen = active == .codex ? session.record.codex?.model : nil
        let fallback = codexModels.first(where: \.isDefault)?.displayName
        row(ModelChoice(backend: .codex, model: nil), detail: fallback.map { "Currently \($0)" }, number: nil)
        let entries = CodexModelCatalog.entries(codexModels, chosen: chosen)
        let shown = entries.filter { $0.isCurrent || $0.model.model == chosen }
        ForEach(shown.filter { !$0.isClaude }) { entry in
            row(ModelChoice(backend: .codex, model: entry.model.model), detail: nil, number: nil)
        }
        let proxied = shown.filter(\.isClaude)
        if !proxied.isEmpty {
            heading("Claude via proxy").padding(.top, 4)
            ForEach(proxied) { entry in row(ModelChoice(backend: .codex, model: entry.model.model), detail: nil, number: nil) }
        }
        let more = CodexModelCatalog.entries(codexModels.map { var m = $0; m.hidden = false; return m })
            .filter { entry in !shown.contains { $0.id == entry.id } && !entry.model.model.hasPrefix("gpt-image") }
        if !more.isEmpty {
            DisclosureGroup("More Codex models", isExpanded: $showHidden) {
                ForEach(more) { entry in
                    row(ModelChoice(backend: .codex, model: entry.model.model), detail: entry.isClaude ? "Claude, through the proxy" : nil, number: nil)
                }
            }
            .font(.callout).padding(.horizontal, 8).padding(.top, 4)
        }
    }

    /// A model: click to pick it; the star keeps it in Favorites; its number picks it too.
    private func row(_ choice: ModelChoice, detail: String?, number: Int?) -> some View {
        let selected = choice == current && session.record.openModel == nil
        let other = choice.backend != active
        let note = other ? "switches to \(choice.backend.label)" : detail
        return HStack(spacing: 6) {
            Button { pick(choice) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                        .foregroundStyle(Color.highlight).opacity(selected ? 1 : 0)
                    Image(choice.backend == .claude || (choice.model ?? "").lowercased().hasPrefix("claude") ? Backend.claude.iconName : Backend.codex.iconName)
                        .resizable().scaledToFit().frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ModelFavorites.name(choice))
                        if let note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if let number { Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked(choice))
            Button { favorites.toggle(choice) } label: {
                Image(systemName: favorites.isFavorite(choice) ? "star.fill" : "star")
                    .foregroundStyle(favorites.isFavorite(choice) ? Color.yellow : Color.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favorites.isFavorite(choice) ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(favorites.isFavorite(choice) ? "Remove \(ModelFavorites.name(choice)) from Favorites" : "Add \(ModelFavorites.name(choice)) to Favorites")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.highlight.opacity(0.12) : .clear))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ModelFavorites.name(choice) + (selected ? ", current" : ""))
    }

    // MARK: - Shelby-PC

    /// The PC's Ollama models, for whichever agent this chat uses. Shown once the PC answers.
    @ViewBuilder
    private var openModelRows: some View {
        let pc = PCModels.shared
        if !session.isDot, !pc.models.isEmpty {
            heading("Open models on \(RemoteMachine.pc.name)").padding(.top, 6)
            ForEach(pc.models, id: \.self) { model in
                Button { session.setOpenModel(model) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark").font(.caption.weight(.bold))
                            .foregroundStyle(Color.highlight).opacity(session.record.openModel == model ? 1 : 0)
                        Image(systemName: "desktopcomputer").font(.caption).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model)
                            Text(model == PCModels.recommended ? "Runs fully on the graphics card; fastest" : "With \(active.label)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(session.record.openModel == model ? Color.highlight.opacity(0.12) : .clear))
                .accessibilityLabel(model + (session.record.openModel == model ? ", current" : ""))
            }
        }
    }

    /// Where this chat's agent runs. Switching starts a new session there, caught up on the chat.
    @ViewBuilder
    private var runOnSection: some View {
        if !session.isDot {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Run on").font(.callout.weight(.medium))
                    Spacer()
                    Picker("Run on", selection: Binding(get: { session.record.runOn ?? "" }, set: { session.setRunOn($0.isEmpty ? nil : $0) })) {
                        Text("This Mac").tag("")
                        Text(RemoteMachine.pc.name).tag("pc")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(session.isRunning || (session.record.runOn == nil && PCModels.shared.reachable == false))
                }
                if PCModels.shared.reachable == false {
                    Text("\(RemoteMachine.pc.name) isn't reachable right now.").font(.caption).foregroundStyle(.secondary)
                } else if session.record.runOn != nil {
                    Text("Works in its own folder on the PC; new files are copied to ~/Chatterbox/PC.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
                    .disabled(session.isRunning)
                }
                Text(session.codexConnection.summary + (session.codexRoute != nil ? " Switching keeps this conversation." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Effort

    /// "" (the model's default) and then each level the current model supports, lowest first.
    private var stops: [String] { [""] + ModelFavorites.efforts(current) }

    private var defaultEffortName: String {
        guard active == .codex else { return "Default" }
        let model = codexModels.first { $0.model == session.record.codex?.model } ?? codexModels.first(where: \.isDefault)
        return model.map { "Default (\(ChatView.effortLabel($0.defaultEffort)))" } ?? "Default"
    }

    private func name(_ stop: String) -> String { stop.isEmpty ? defaultEffortName : ChatView.effortLabel(stop) }

    @ViewBuilder
    private var effortSection: some View {
        let stops = self.stops
        if stops.count <= 1 {
            Text("This model has no effort setting.").font(.callout).foregroundStyle(.secondary)
        } else {
            let index = Double(stops.firstIndex(of: ModelFavorites.effort(session)) ?? 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Effort").font(.callout.weight(.medium))
                    Spacer()
                    Text(name(stops[Int(index)])).font(.callout).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { index }, set: { favorites.setEffort(stops[Int($0.rounded())], for: session) }),
                       in: 0...Double(stops.count - 1), step: 1)
                    .accessibilityLabel("Effort")
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
        }
    }
}

/// Under the message box, beside the model: the current model's effort, one step per level.
/// Hidden when the model has no effort setting.
struct ComposerEffortSlider: View {
    let session: ChatSession
    let color: Color

    /// "" (the model's default), then each level the model supports, lowest first.
    private var stops: [String] {
        switch session.record.backend {
        case .claude:
            return [""] + ClaudeModels.shared.info(session.record.model).efforts
        case .codex:
            guard let codex = session.record.codex else { return [] }
            let models = CodexAppServer.shared.models
            let current = models.first { $0.model == codex.model } ?? models.first(where: \.isDefault)
            return [""] + (current?.efforts ?? ["low", "medium", "high"])
        }
    }
    private var effort: String {
        session.record.backend == .claude ? session.record.effort : session.record.codex?.effort ?? ""
    }
    private func set(_ value: String) { ModelFavorites.shared.setEffort(value, for: session) }
    private func name(_ stop: String) -> String { stop.isEmpty ? "Default" : ChatView.effortLabel(stop) }

    var body: some View {
        let stops = self.stops
        if stops.count > 1 {
            let index = Double(stops.firstIndex(of: effort) ?? 0)
            HStack(spacing: 6) {
                Slider(value: Binding(get: { index }, set: { set(stops[Int($0.rounded())]) }),
                       in: 0...Double(stops.count - 1), step: 1)
                    .controlSize(.mini)
                    .tint(color)
                    .frame(width: CGFloat(18 * stops.count + 24))
                Text(name(stops[Int(index)]))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .leading)
            }
            .help("Effort: \(name(stops[Int(index)]))")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Effort, \(name(stops[Int(index)]))")
        }
    }
}
