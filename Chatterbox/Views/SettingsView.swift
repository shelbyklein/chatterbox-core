import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var detectedCodex: String?
    @State private var detectedClaude: String?

    @AppStorage("defaultBackend") private var defaultBackend = Backend.claude
    @AppStorage("notifyNeeds") private var notifyNeeds = true
    @AppStorage("notifyReplies") private var notifyReplies = true
    @AppStorage("notifySound") private var notifySound = true
    @AppStorage("notifyBadge") private var notifyBadge = true
    @AppStorage("defaultModel") private var defaultModel = "default"
    @AppStorage("defaultEffort") private var defaultEffort = ""
    @AppStorage("codexDefaultModel") private var codexDefaultModel = ""
    @AppStorage("codexDefaultEffort") private var codexDefaultEffort = ""
    /// The preset open for editing, if any.
    @State private var editingPreset: UUID?
    @AppStorage("defaultPersonality") private var defaultPersonality = Personality.friendly
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("codexPath") private var codexPath = ""
    @AppStorage("codexFolder") private var codexFolder = NSHomeDirectory()
    @AppStorage("claudeDefaultMode") private var claudeDefaultMode = PermissionModes.defaultClaude
    @AppStorage("codexDefaultMode") private var codexDefaultMode = PermissionModes.defaultCodex
    @AppStorage(AppModel.keepRepliesRunningKey) private var keepRepliesRunning = true
    @AppStorage(KeepAwake.key) private var keepAwake = true
    @AppStorage(PinStore.openInAppKey) private var openPinsInApp = true
    @AppStorage(ChatSession.remoteControlKey) private var remoteControl = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            #if GOLEM_APP
            Form { DotActivitySettings() }
                .formStyle(.grouped)
                .tabItem { Label(model.dotName, systemImage: "circle.circle") }
            #endif
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            InstructionsSettingsView()
                .tabItem { Label("Instructions", systemImage: "text.book.closed") }
            SecretsSettingsView()
                .tabItem { Label("Secrets", systemImage: "key") }
            PluginsSettingsView()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            CompanionSettingsView()
                .tabItem { Label("iPhone", systemImage: "iphone") }
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("When an agent needs you", isOn: $notifyNeeds)
                Toggle("When a reply finishes", isOn: $notifyReplies)
                Toggle("Play a sound", isOn: $notifySound)
                Toggle("Show a badge on the Dock icon", isOn: $notifyBadge)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Only while you're away from the chat: Chatterbox isn't frontmost, or a different chat is open. Approvals can be allowed or denied right from the notification.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                defaultModelPicker(title: "Claude", icon: "sparkle", options: claudeOptions,
                                   model: Binding(get: { ClaudeModels.shared.info(defaultModel).value }, set: {
                                       defaultModel = $0
                                       if !ClaudeModels.shared.info($0).efforts.contains(defaultEffort) { defaultEffort = "" }
                                   }),
                                   effort: $defaultEffort,
                                   efforts: ClaudeModels.shared.info(defaultModel).efforts)
                defaultModelPicker(title: "Codex", icon: "terminal", options: codexOptions,
                                   model: Binding(get: { codexDefaultModel }, set: { codexDefaultModel = $0; codexDefaultEffort = "" }),
                                   effort: $codexDefaultEffort,
                                   efforts: CodexAppServer.shared.models.first { $0.model == codexDefaultModel }?.efforts
                                       ?? CodexAppServer.shared.models.first(where: \.isDefault)?.efforts ?? [])
            } header: {
                Text("Default models")
            } footer: {
                Text("What new chats start with. Change a chat's own model from the bar under its message box.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(ModelPresets.shared.presets) { preset in presetRow(preset) }
                HStack {
                    Button("Add Preset") {
                        let preset = ModelPreset(title: "", backend: .codex, model: codexDefaultModel.isEmpty ? nil : codexDefaultModel, effort: nil)
                        var named = preset
                        named.title = ModelPresets.automaticTitle(preset)
                        ModelPresets.shared.add(named)
                        editingPreset = named.id
                    }
                    Spacer()
                    Button("Restore Default Presets") { ModelPresets.shared.resetToDefaults() }
                }
            } header: {
                Text("Quick-switch presets")
            } footer: {
                Text("Shown under the message box, to switch a chat's agent, model, and effort in one click. You can also save a chat's current setup from its model menu with \u{201C}Save as Preset\u{201D}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


            Section("New chats") {
                Picker("Chat with", selection: $defaultBackend) {
                    ForEach(Backend.allCases) { Text($0.label).tag($0) }
                }
                Picker("Tone", selection: $defaultPersonality) {
                    ForEach(Personality.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Working folder") {
                    Button((codexFolder as NSString).abbreviatingWithTildeInPath) {
                        if let path = FolderPicker.choose(startingAt: codexFolder, message: "Choose where chats without a project work") { codexFolder = path }
                    }
                }
                .help("Where Claude Code and Codex work in chats that aren't bound to a project folder.")
                Picker("Claude mode", selection: $claudeDefaultMode) {
                    ForEach(PermissionModes.claude) { Text($0.title).tag($0.id) }
                }
                Picker("Codex mode", selection: $codexDefaultMode) {
                    ForEach(PermissionModes.codex) { Text($0.title).tag($0.id) }
                }
            }

            Section {
                Toggle("Remote Control for Claude chats", isOn: $remoteControl)
                    .help("Claude chats you use can be read and continued on claude.ai and in the Claude app, while Chatterbox is open. Turn it on or off for one chat from its toolbar.")
                Toggle("Open website pins inside Chatterbox", isOn: $openPinsInApp)
                    .help("The page takes the chat's place, and the chat floats in the corner. Off: pins open in your browser.")
                Toggle("Keep replies running after Chatterbox quits", isOn: $keepRepliesRunning)
                Toggle("Keep this Mac awake while Chatterbox is open", isOn: $keepAwake)
                    .onChange(of: keepAwake) { KeepAwake.shared.apply() }
                    .help("So your phone can reach it, and agents, check-ins, and the email watch keep running. The display still sleeps; closing a laptop's lid still puts it to sleep.")
            } footer: {
                Text(keepRepliesRunning
                     ? "A reply in progress finishes in the background and is waiting when you reopen Chatterbox, along with any question it asked."
                     : "Quitting stops any reply in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProxySection()
            DiagnosticsSection()

            Section {
                LabeledContent("Signed in") {
                    if let email = ClaudeModels.shared.accountEmail {
                        Text(email + (ClaudeModels.shared.plan.map { " (\($0))" } ?? ""))
                    } else {
                        Text(ClaudeModels.shared.statusMessage ?? "Checking\u{2026}").foregroundStyle(.secondary)
                    }
                }
                TextField("claude path", text: $claudePath, prompt: Text(detectedClaude ?? "Auto-detect"))
            } header: {
                Text("Claude Code")
            } footer: {
                Text(detectedClaude == nil
                     ? "Couldn't find the `claude` command. Install Claude Code, or enter its full path."
                     : "Uses your installed Claude Code, its settings, and your Claude subscription. The mode under the message box decides what Claude may do without asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


            Section {
                TextField("codex path", text: $codexPath, prompt: Text(detectedCodex ?? "Auto-detect"))
            } header: {
                Text("Codex")
            } footer: {
                Text(detectedCodex == nil
                     ? "Couldn't find the `codex` command. Install the Codex CLI, or enter its full path."
                     : "Uses your installed Codex CLI, its config, and your ChatGPT sign-in. Codex asks before running commands that need approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .task(id: codexPath) { detectedCodex = CodexAppServer.locateBinary() }
        .task(id: claudePath) {
            detectedClaude = ClaudeCodeProcess.locateBinary()
            await ClaudeModels.shared.refresh(force: !claudePath.isEmpty)
        }
        .task { if CodexAppServer.shared.models.isEmpty { try? await CodexAppServer.shared.refreshModels() } }
    }

    /// "Codex · GPT-6.1-Sol · Low": what a preset switches to, in names rather than ids.
    private func presetDetail(_ preset: ModelPreset) -> String {
        if preset.followsDefault == true { return "Follows your \(preset.backend.label) default" }
        let model: String
        switch preset.backend {
        case .claude: model = preset.model.map { ClaudeModels.shared.info($0).displayName } ?? "default model"
        case .codex: model = preset.model.flatMap { id in CodexAppServer.shared.models.first { $0.model == id }?.displayName } ?? preset.model ?? "Codex's default"
        }
        return "\(preset.backend.label) \u{00B7} \(model) \u{00B7} \(preset.effort.map { ChatView.effortLabel($0) } ?? "default effort")"
    }

    /// A model in the default-model picker: its id, name, and a line about it.
    private struct ModelChoice: Identifiable {
        var id: String
        var name: String
        var detail: String
    }

    private var claudeOptions: [ModelChoice] { claudeChoices(including: defaultModel) }

    /// Claude's current models: the newest of each family (Opus 5.5, not 4.8), plus Default.
    /// An older one shows only when it's the one already chosen.
    private func claudeChoices(including selected: String) -> [ModelChoice] {
        let catalog = ClaudeModels.shared
        let current = catalog.info(selected)
        let models = catalog.models.contains { $0.value == current.value } ? catalog.models : [current] + catalog.models
        var newest: [String: Double] = [:]
        for model in models {
            if let (family, version) = Self.familyAndVersion(model.displayName) { newest[family] = max(newest[family] ?? 0, version) }
        }
        return models.filter { model in
            guard model.value != current.value, let (family, version) = Self.familyAndVersion(model.displayName) else { return true }
            return version >= (newest[family] ?? 0)
        }
        .map { ModelChoice(id: $0.value, name: $0.displayName, detail: $0.detail) }
    }

    /// "GPT-6.1-Sol" → ("Sol", 6.1); "GPT-5.5" → ("", 5.5).
    private static func codexFamilyAndVersion(_ name: String) -> (String, Double)? {
        let parts = name.split(separator: "-")
        guard parts.count >= 2, let version = Double(parts[1]) else { return nil }
        return (parts.dropFirst(2).joined(separator: "-"), version)
    }

    /// "Opus 4.8" → ("Opus", 4.8); nil for names like "Default (recommended)".
    private static func familyAndVersion(_ name: String) -> (String, Double)? {
        let parts = name.split(separator: " ")
        guard parts.count == 2, let version = Double(parts[1]) else { return nil }
        return (String(parts[0]), version)
    }

    private var codexOptions: [ModelChoice] { codexChoices(including: codexDefaultModel) }

    /// Codex's current models: the newest of each family (GPT-6.1-Sol, not GPT-6-Sol), from
    /// the newest generation only. An older one shows only when it's the one already chosen.
    private func codexChoices(including codexDefaultModel: String) -> [ModelChoice] {
        let listed = CodexAppServer.shared.models.filter { !$0.hidden || $0.model == codexDefaultModel }
        var newest: [String: Double] = [:]
        var newestGeneration = 0.0
        for model in listed {
            guard let (family, version) = Self.codexFamilyAndVersion(model.displayName) else { continue }
            newest[family] = max(newest[family] ?? 0, version)
            newestGeneration = max(newestGeneration, version.rounded(.down))
        }
        let models = listed.filter { model in
            guard model.model != codexDefaultModel, let (family, version) = Self.codexFamilyAndVersion(model.displayName) else { return true }
            return version >= (newest[family] ?? 0) && version.rounded(.down) >= newestGeneration
        }
        let fallback = models.first(where: \.isDefault)?.displayName
        var choices = [ModelChoice(id: "", name: "Codex's default", detail: fallback.map { "Currently \($0); follows Codex if that changes" } ?? "Whatever Codex picks")]
        choices += models.map { ModelChoice(id: $0.model, name: $0.displayName, detail: $0.isDefault ? "Codex's default right now" : "") }
        if !codexDefaultModel.isEmpty, !models.contains(where: { $0.model == codexDefaultModel }) {
            choices.append(ModelChoice(id: codexDefaultModel, name: codexDefaultModel, detail: "Not in Codex's list right now"))
        }
        return choices
    }

    /// A preset: its name and what it switches to, opening to the same pickers as the defaults.
    private func presetRow(_ preset: ModelPreset) -> some View {
        let isEditing = editingPreset == preset.id
        let presets = ModelPresets.shared
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: Binding(get: { preset.title }, set: { presets.rename(preset, to: $0) }))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 220, alignment: .leading)
                Spacer()
                if !isEditing { Text(presetDetail(preset)).foregroundStyle(.secondary).font(.caption) }
                Button(isEditing ? "Done" : "Edit") { editingPreset = isEditing ? nil : preset.id }
                    .buttonStyle(.borderless)
                Button { presets.remove(preset) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove preset")
            }
            if isEditing, preset.followsDefault == true {
                Text("This one switches to your default \(preset.backend.label) model, set above. Changing it here makes it a fixed preset instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isEditing {
                Picker("Agent", selection: Binding(get: { preset.backend }, set: { backend in
                    let model = backend == .claude ? ClaudeModels.shared.models.first?.value : (codexDefaultModel.isEmpty ? nil : codexDefaultModel)
                    presets.update(preset.id, backend: backend, model: model, effort: nil)
                })) {
                    ForEach(Backend.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                let isClaude = preset.backend == .claude
                // A full id ("claude-opus-5-5") shows as its own model's row (Opus 5.5).
                let modelID = isClaude ? ClaudeModels.shared.info(preset.model ?? "default").value : (preset.model ?? "")
                defaultModelPicker(
                    title: preset.backend.label, icon: isClaude ? "sparkle" : "terminal",
                    options: isClaude ? claudeChoices(including: modelID) : codexChoices(including: preset.model ?? ""),
                    model: Binding(get: { modelID }, set: { presets.update(preset.id, backend: preset.backend, model: $0.isEmpty ? nil : $0, effort: nil) }),
                    effort: Binding(get: { preset.effort ?? "" }, set: { presets.update(preset.id, backend: preset.backend, model: preset.model, effort: $0.isEmpty ? nil : $0) }),
                    efforts: isClaude ? ClaudeModels.shared.info(modelID).efforts
                        : (CodexAppServer.shared.models.first { $0.model == preset.model }?.efforts
                           ?? CodexAppServer.shared.models.first(where: \.isDefault)?.efforts ?? []))
            }
        }
    }

    /// One agent's default: its models as a list to pick from, then effort as a row of buttons.
    private func defaultModelPicker(title: String, icon: String, options: [ModelChoice], model: Binding<String>,
                                    effort: Binding<String>, efforts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            if options.isEmpty {
                Text("Models show up once \(title) has started.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(options) { option in
                    Button { model.wrappedValue = option.id } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: model.wrappedValue == option.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.wrappedValue == option.id ? Color.primary : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.name)
                                if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(model.wrappedValue == option.id ? 0.08 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !efforts.isEmpty {
                Picker("Effort", selection: effort) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text(ChatView.effortLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Settings in the main window, in the chat's place (⌘,). Done, Esc, or picking a chat
/// goes back.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { model.showingSettings = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
    }
}

/// Settings → Appearance: how the transcript reads, with a live preview.
private struct AppearanceSettingsView: View {
    private let settings = ReaderStyleSettings()
    @AppStorage(Theme.schemeKey) private var themeScheme = "system"
    @AppStorage(Theme.backgroundKey) private var themeBackground = "standard"
    @AppStorage(Theme.highlightKey) private var themeHighlight = "default"
    @AppStorage("readerGroupSteps") private var groupSteps = true

    private static let preview = """
    ## A quick preview
    This is how replies read. Adjust **text size**, line height, and spacing until long answers feel comfortable. Code like `git status` gets its own font.

    - Lists wrap with a hanging indent, so longer items stay easy to scan.
    - Tables, quotes, and code blocks follow the same settings.

    | Setting | Effect |
    |---|---|
    | Line height | Space between wrapped lines |
    | Paragraph spacing | Space between blocks |
    """

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Theme", selection: $themeScheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .disabled(themeBackground != "standard")
                    LabeledContent("Background") {
                        HStack(spacing: 8) {
                            ForEach(Theme.backgrounds, id: \.id) { option in
                                Button { themeBackground = option.id } label: {
                                    VStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Theme.background(option.id) ?? Color.windowBackground)
                                            .frame(width: 34, height: 22)
                                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(themeBackground == option.id ? 1 : 0.2),
                                                                                                   lineWidth: themeBackground == option.id ? 2 : 1))
                                        Text(option.label).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            VStack(spacing: 3) {
                                ColorPicker("Custom", selection: Binding(
                                    get: { Theme.background(themeBackground) ?? .black },
                                    set: { themeBackground = ReaderStyle.hex($0) }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                Text("Custom").font(.caption2).foregroundStyle(themeBackground.hasPrefix("#") ? .primary : .secondary)
                            }
                        }
                    }
                    LabeledContent("Highlight") {
                        HStack(spacing: 6) {
                            Button { themeHighlight = "default" } label: {
                                Circle().fill(Color.primary).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.secondary, lineWidth: themeHighlight == "default" ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help("Plain (white in dark mode, black in light)")
                            ForEach(ReaderStyle.bubbleColors.filter { $0.id != "gray" }, id: \.id) { preset in
                                Button { themeHighlight = preset.id } label: {
                                    Circle().fill(preset.color).frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: themeHighlight == preset.id ? 2 : 0).padding(-3))
                                }
                                .buttonStyle(.plain)
                                .help(preset.label)
                            }
                            ColorPicker("Custom", selection: Binding(
                                get: { Color.highlight },
                                set: { themeHighlight = ReaderStyle.hex($0) }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .help("Custom color")
                        }
                    }
                } header: {
                    Text("Window")
                } footer: {
                    Text("A dark background keeps Chatterbox in dark mode so text stays readable. The highlight marks selection, unread badges, progress, and main buttons.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Text") {
                    Picker("Font", selection: settings.$design) {
                        ForEach(ReaderStyle.designs, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    slider("Text size", value: settings.$textSize, range: 11...22, step: 1, unit: "pt")
                    slider("Line height", value: settings.$lineSpacing, range: 0...12, step: 1, unit: "pt",
                           hint: "Extra space between wrapped lines")
                    slider("Paragraph spacing", value: settings.$paragraphSpacing, range: 4...28, step: 1, unit: "pt")
                    slider("Code size", value: settings.$codeSize, range: 10...20, step: 1, unit: "pt")
                }
                Section {
                    colorRow("Claude", selection: settings.$claudeColor)
                    colorRow("Codex", selection: settings.$codexColor)
                    slider("Bubble strength", value: Binding(get: { settings.bubbleStrength * 100 }, set: { settings.bubbleStrength = $0 / 100 }),
                           range: 5...60, step: 1, unit: "%")
                } header: {
                    Text("Agent colors")
                } footer: {
                    Text("Your messages take the color of the agent they went to. The message box and model line use the current agent's color.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Steps and thinking") {
                    Toggle("Group steps into one row", isOn: $groupSteps)
                    Toggle("Compact step rows", isOn: settings.$compactSteps)
                    Text("Tightens the spacing of \u{201C}Running\u{2026}\u{201D} rows, notes, and thinking.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show thinking", isOn: settings.$showThinking)
                }
                Section("Layout") {
                    slider("Conversation width", value: settings.$contentWidth, range: 560...1400, step: 20, unit: "pt",
                           hint: "The widest the chat column gets in a large window")
                }
                Section {
                    Button("Restore Defaults") { settings.reset() }
                }
            }
            .formStyle(.grouped)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ItemView(item: DisplayItem(kind: .user, text: "Claude, can you make the replies easier to read?"), agent: .claude)
                        .padding(.vertical, settings.style.paragraphSpacing / 2)
                    ItemView(item: DisplayItem(kind: .user, text: "Codex, check the build too."), agent: .codex)
                        .padding(.vertical, settings.style.paragraphSpacing / 2)
                    ItemView(item: DisplayItem(kind: .tool, text: "Reading MarkdownText.swift", toolState: .done))
                        .padding(.vertical, settings.compactSteps ? 1 : settings.style.paragraphSpacing / 2)
                    if settings.showThinking {
                        ItemView(item: DisplayItem(kind: .thought, text: "Checking the current spacing"))
                            .padding(.vertical, settings.compactSteps ? 1 : settings.style.paragraphSpacing / 2)
                    }
                    MarkdownText(text: Self.preview)
                        .padding(.vertical, settings.style.paragraphSpacing / 2)
                }
                .environment(\.readerStyle, settings.style)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(maxWidth: 640)
    }

    private func colorRow(_ title: String, selection: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                ForEach(ReaderStyle.bubbleColors, id: \.id) { preset in
                    Button { selection.wrappedValue = preset.id } label: {
                        Circle().fill(preset.color).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: selection.wrappedValue == preset.id ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(preset.label)
                }
                ColorPicker("Custom", selection: Binding(
                    get: { ReaderStyle.bubbleColor(selection.wrappedValue) },
                    set: { selection.wrappedValue = ReaderStyle.hex($0) }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("Custom color")
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack {
                    Slider(value: value, in: range, step: step).frame(width: 200)
                    Text("\(Int(value.wrappedValue)) \(unit)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Settings → Instructions: what Chatterbox tells both agents, your own instructions for
/// every chat, and each agent's own global file.
private struct InstructionsSettingsView: View {
    @AppStorage("defaultPersonality") private var personality = Personality.friendly
    @State private var draft = Prompts.userInstructions
    @State private var saved = Prompts.userInstructions

    var body: some View {
        Form {
            Section {
                ScrollView {
                    Text(Prompts.agentInstructions(personality))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170)
            } header: {
                Text("Chatterbox instructions")
            } footer: {
                Text("Added to Claude Code's and Codex's own system prompts in every chat: your tone (shown for the default tone), plus notes about the chat window. Each agent keeps its own base prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 170)
                HStack {
                    Button("Save") { save() }.disabled(draft == saved)
                    Button("Revert") { draft = saved }.disabled(draft == saved)
                    Spacer()
                    Button("Show File") { reveal(Prompts.userInstructionsFile) }
                }
            } header: {
                Text("Your instructions for every chat")
            } footer: {
                Text("Sent to both agents. New chats get them in their instructions; ongoing chats get the update with your next message. Stored in \((Prompts.userInstructionsFile.path as NSString).abbreviatingWithTildeInPath).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                fileRow("Claude Code: ~/.claude/CLAUDE.md", "\(NSHomeDirectory())/.claude/CLAUDE.md")
                fileRow("Codex: ~/.codex/AGENTS.md", "\(NSHomeDirectory())/.codex/AGENTS.md")
            } header: {
                Text("Each agent's own global instructions")
            } footer: {
                Text("In a project, Claude reads CLAUDE.md and Codex reads AGENTS.md. Chatterbox also gives each agent the other's file, so either one covers both. Edit them from the project's folder menu in the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640, maxHeight: .infinity)
    }

    private func save() {
        let url = Prompts.userInstructionsFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? draft.write(to: url, atomically: true, encoding: .utf8)
        saved = draft
    }

    private func fileRow(_ title: String, _ path: String) -> some View {
        LabeledContent(title) {
            Button(FileManager.default.fileExists(atPath: path) ? "Edit" : "Create") { openForEditing(path) }
        }
    }

    private func reveal(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) { save() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Opens a Markdown file in the user's editor, creating it first if needed.
@MainActor
func openForEditing(_ path: String) {
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
        NSWorkspace.shared.open(url)
    } else {
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Settings → General: Dot checking in on its own, and watching for chats that need you.
#if GOLEM_APP
private struct DotActivitySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DotActivity.checkInsKey) private var checkIns = true
    @AppStorage(DotActivity.watchWaitingKey) private var watchWaiting = true
    @AppStorage(EmailWatch.enabledKey) private var emailWatch = true
    @AppStorage(DotActivity.summarizeFinishedKey) private var summarizeFinished = true
    @State private var times = DotActivity.times

    var body: some View {
        Section {
            Toggle("Check in on its own, weekdays", isOn: $checkIns)
            if checkIns {
                ForEach(times.indices, id: \.self) { index in
                    DatePicker(index == 0 ? "First check-in" : "Then at", selection: Binding(
                        get: { Self.date(times[index]) },
                        set: { times[index] = Self.minutes($0); DotActivity.times = times }
                    ), displayedComponents: .hourAndMinute)
                }
                HStack {
                    if times.count < 4 {
                        Button("Add a Time") { times.append(min((times.last ?? 15 * 60) + 120, 23 * 60)); DotActivity.times = times }
                    }
                    if times.count > 1 {
                        Button("Remove Last") { times.removeLast(); DotActivity.times = times }
                    }
                    Spacer()
                    Button("Check In Now") { DotActivity.shared.checkInNow() }
                }
            }
            Toggle("\(model.dotName) summarizes finished work", isOn: $summarizeFinished)
            Toggle("\(model.dotName) briefs you when a chat is waiting on you", isOn: $watchWaiting)
        } header: {
            Text(model.dotName)
        } footer: {
            Text("At each check-in, \(model.dotName) looks over your email, USA Archery in ClickUp, and your chats, and sends you a short briefing only when something needs you; otherwise it leaves a single quiet line. It runs while Chatterbox is open on a Mac that's awake, catching up within three hours if the Mac was asleep.")
                .font(.caption).foregroundStyle(.secondary)
        }
        emailSection
        miniSection
    }

    @AppStorage("golemBubbleTextSize") private var bubbleTextSize = 14.0
    @AppStorage("golemBubbleStyle") private var bubbleStyle = "solid"
    @AppStorage("golemBubbleShow") private var bubbleShow = true
    @AppStorage(GolemMiniWindow.sizeKey) private var miniSize = 1.0

    @ViewBuilder private var miniSection: some View {
        Section {
            Picker("Size on screen", selection: Binding(get: { miniSize }, set: { value in
                miniSize = value
                model.dotMiniWindow?.setScale(CGFloat(value))
            })) {
                ForEach(GolemMiniWindow.sizes, id: \.label) { Text($0.label).tag(Double($0.scale)) }
            }
            Toggle("Show his reply bubble", isOn: $bubbleShow)
            if bubbleShow {
                Picker("Bubble", selection: $bubbleStyle) {
                    Text("Solid").tag("solid")
                    Text("Glass").tag("glass")
                    Text("Tinted").tag("tinted")
                }
                .pickerStyle(.segmented)
                LabeledContent("Bubble text") {
                    HStack {
                        Slider(value: $bubbleTextSize, in: 11...20, step: 1).frame(width: 200)
                        Text("\(Int(bubbleTextSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("\(model.dotName) Mini")
        } footer: {
            Text("The floating \(model.dotName) (⌘J). Right-click him for these too.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var emailSection: some View {
        let watch = EmailWatch.shared
        Section {
            Toggle("Watch your email", isOn: $emailWatch)
            if emailWatch {
                HStack {
                    if watch.isSweeping {
                        ProgressView().controlSize(.small)
                        Text("Sweeping\u{2026}").foregroundStyle(.secondary)
                    } else if let problem = watch.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                    } else if let last = watch.lastSweep {
                        Text("Last swept \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Send Test") { watch.sendTest() }
                    Button("Sweep Now") { watch.sweepNow() }.disabled(watch.isSweeping)
                }
            }
        } footer: {
            Text("Every 15 minutes from 9 to 5, and every 30 the rest of the time, GPT-6-Luna reads the mail that arrived since the last sweep in your Gmail accounts, by the rules in \(model.dotName)'s memory. Each email that needs you comes as a notification with why it matters and a suggested next step, with Draft Reply, Tell \(model.dotName)\u{2026}, and Open. It only reads mail; nothing is sent without you.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minutes(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
    }
}

#endif

/// Hang and crash reports: what Chatterbox recorded when it stopped responding or didn't
/// quit cleanly.
private struct DiagnosticsSection: View {
    private let diagnostics = Diagnostics.shared

    var body: some View {
        Section {
            if diagnostics.reports.isEmpty {
                Text("No reports. If Chatterbox stops responding for more than 2 seconds, or doesn't close properly, a report shows up here. If the window looks stuck, press ⌃⌥⌘D (Help → Report a Freeze) to capture one on the spot.")
                    .foregroundStyle(.secondary)
            }
            ForEach(diagnostics.reports.prefix(8)) { report in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(report.title)
                        Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString((try? String(contentsOf: report.url, encoding: .utf8)) ?? "", forType: .string)
                    }
                    .help("Copy the whole report, to paste into a chat")
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
                }
            }
            HStack {
                Spacer()
                Button("Open Reports Folder") { NSWorkspace.shared.open(Diagnostics.folder) }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Reports are plain text in \(Diagnostics.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Paste one into a chat, or ask an agent to read the newest, to find what froze.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { diagnostics.reload() }
    }
}

/// EasyCLIProxyAPI: send Claude and Codex chats through the local proxy that pools your
/// accounts. The assistant and the email watch always connect directly.
private struct ProxySection: View {
    @AppStorage(EasyCLIProxy.claudeKey) private var claude = false
    @AppStorage(EasyCLIProxy.codexKey) private var codex = false
    @Environment(AppModel.self) private var model
    private let proxy = EasyCLIProxy.shared

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(proxy.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    if proxy.isRunning, let endpoint = proxy.endpoint {
                        Text("Running at \(endpoint.host):\(endpoint.port) \u{00B7} \(proxy.modelCount) models").foregroundStyle(.secondary)
                    } else if proxy.endpoint == nil {
                        Text("Not installed (no CLIProxyAPI config found)").foregroundStyle(.secondary)
                    } else {
                        Text("Not running. Open EasyCLIProxyAPI.").foregroundStyle(.secondary)
                    }
                    Button("Check") { Task { await proxy.refresh() } }.controlSize(.small)
                }
            }
            Toggle("Send Claude chats through it", isOn: $claude)
            Toggle("Send Codex chats through it", isOn: $codex)
        } header: {
            Text("EasyCLIProxyAPI")
        } footer: {
            Text("Spreads chats across the accounts you've signed in to EasyCLIProxyAPI. Through it, Claude can't use your claude.ai connectors and Codex can't use ChatGPT apps like Gmail, so \(model.dotName) and the email watch always connect directly. Takes effect with each chat's next message; if the proxy stops answering, chats connect directly.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await proxy.refresh() }
        .onChange(of: claude) { restartClaudeChats() }
        .onChange(of: codex) { Task { await proxy.refresh() } }
    }

    /// Claude Code reads its address at launch: idle chats restart into the new route.
    private func restartClaudeChats() {
        Task {
            await proxy.refresh()
            for session in model.sessions where !session.isDot && session.record.backend == .claude {
                session.restartClaudeForNewTools()
            }
        }
    }
}

/// Dedicated Settings tab; the existing editor, storage and scope controls are reused.
struct SecretsSettingsView: View {
    var body: some View {
        Form { SecretsSection() }
            .formStyle(.grouped)
            .frame(maxWidth: 640, maxHeight: .infinity)
    }
}

/// Secrets & accounts for agents: kept in Keychain, given to chats as environment variables.
struct SecretsSection: View {
    @Environment(AppModel.self) private var model
    private let vault = SecretVault.shared
    @State private var editing: SecretEntry?
    @State private var removing: SecretEntry?

    var body: some View {
        Section {
            if vault.entries.isEmpty {
                Text("No secrets yet. Add an API key, a token, or an account's password, and agents can use it in commands without ever seeing it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(vault.entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isAccount ? "person.badge.key" : "key")
                        .foregroundStyle(vault.hasValue(entry) ? Color.secondary : Color.orange)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text("$\(entry.variable)\(entry.isAccount ? " \u{00B7} \(entry.username)" : "") \u{00B7} \(scope(entry))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if !vault.hasValue(entry) { Text("No value").font(.caption).foregroundStyle(.orange) }
                    Button("Edit") { editing = entry }
                    Button(role: .destructive) { removing = entry } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove \(entry.name)").accessibilityLabel("Remove \(entry.name)")
                }
            }
            HStack {
                Spacer()
                Button("Add Secret\u{2026}") { editing = SecretEntry(name: "", variable: "") }
            }
        } header: {
            Text("Secrets & Accounts")
        } footer: {
            Text("Values are kept in your Mac's Keychain and never shown here again. Chats in scope get each one as an environment variable for the commands their agent runs; the agent is told only its name and what it's for, and any value that shows up in a chat is masked. A command that prints a value would still show it to the agent's model, so agents are told never to.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { entry in
            SecretEditor(entry: entry, isNew: !vault.entries.contains { $0.id == entry.id },
                         projects: model.sidebarProjects.compactMap { session in
                             session.record.projectFolder.map { (name: session.projectName, folder: $0) }
                         }) { saved, value in
                try vault.save(saved, value: value)
                restartClaudeChats()
            }
        }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let entry = removing { vault.remove(entry); restartClaudeChats() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes it from Keychain. Chats lose $\(removing?.variable ?? "") with their next message.")
        }
    }

    private func scope(_ entry: SecretEntry) -> String {
        if entry.projects.isEmpty { return "all chats" }
        let names = entry.projects.compactMap { folder in model.session(boundTo: folder)?.projectName }
        return names.isEmpty ? "\(entry.projects.count) project\(entry.projects.count == 1 ? "" : "s")" : names.joined(separator: ", ")
    }

    /// Claude Code reads its environment at launch: idle chats restart into the new one.
    private func restartClaudeChats() {
        for session in model.sessions where session.record.backend == .claude { session.restartClaudeForNewTools() }
    }
}

struct SecretEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: SecretEntry
    let isNew: Bool
    let projects: [(name: String, folder: String)]
    let onSave: (SecretEntry, String?) throws -> Void
    @State private var value = ""
    @State private var isAccount = false
    @State private var everywhere = true
    @State private var error: String?
    @State private var variableEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Kind", selection: $isAccount) {
                        Text("API key or token").tag(false)
                        Text("Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $entry.name, prompt: Text(isAccount ? "SDHQ WordPress admin" : "Stripe test key"))
                        .onChange(of: entry.name) { _, name in
                            if !variableEdited { entry.variable = SecretEntry.variableName(from: name) }
                        }
                    TextField("Variable", text: Binding(get: { entry.variable }, set: { entry.variable = $0.uppercased(); variableEdited = true }))
                    if isAccount {
                        TextField("User name", text: $entry.username)
                    }
                    SecureField(isAccount ? "Password" : "Value", text: $value,
                                prompt: Text(isNew ? "Paste it here" : "Leave empty to keep the saved one"))
                    TextField("What it's for", text: $entry.note, prompt: Text("Told to agents, e.g. \u{201C}Stripe test mode for the PlayCase store\u{201D}"), axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text(isAccount
                         ? "Agents get $\(entry.variable.isEmpty ? "NAME" : entry.variable) (the password) and $\(entry.variable.isEmpty ? "NAME" : entry.variable)_USER."
                         : "Agents get it as $\(entry.variable.isEmpty ? "NAME" : entry.variable).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Available to") {
                    Toggle("All chats", isOn: $everywhere)
                    if !everywhere {
                        ForEach(projects, id: \.folder) { project in
                            Toggle(project.name, isOn: Binding(
                                get: { entry.projects.contains(project.folder) },
                                set: { on in
                                    if on { entry.projects.append(project.folder) } else { entry.projects.removeAll { $0 == project.folder } }
                                }))
                        }
                        if projects.isEmpty { Text("No projects yet.").foregroundStyle(.secondary) }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.name.trimmingCharacters(in: .whitespaces).isEmpty || !SecretEntry.isValidVariable(entry.variable)
                              || (isNew && value.isEmpty) || (!everywhere && entry.projects.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            isAccount = entry.isAccount
            everywhere = entry.projects.isEmpty
            variableEdited = !isNew
        }
    }

    private func save() {
        var saved = entry
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        if !isAccount { saved.username = "" }
        if everywhere { saved.projects = [] }
        do {
            try onSave(saved, value.isEmpty ? nil : value)
            value = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
