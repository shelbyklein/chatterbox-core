import SwiftUI

/// A chat's agent, model, effort, mode, and presets, as on the Mac. Each change applies
/// right away, even mid-reply.
struct ChatSettingsSheet: View {
    let options: Companion.ChatOptions
    let apply: (Companion.SettingsRequest) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatSettingsForm(options: options, apply: apply)
                .navigationTitle("Session Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The settings themselves, for a chat (Chat Settings) or one about to start (New Chat);
/// `leading` goes above them (New Chat's "Start in").
struct ChatSettingsForm<Leading: View>: View {
    let options: Companion.ChatOptions
    let apply: (Companion.SettingsRequest) -> Void
    @ViewBuilder var leading: () -> Leading

    /// Which provider's models the model menu lists ("claude", "codex" or "open").
    @State private var browsing: String?
    private var isCodex: Bool { options.backend == "codex" }
    private var currentModel: Companion.ModelOption? { (isCodex ? options.codexModels : options.claudeModels).first { $0.id == options.model } }

    var body: some View {
            Form {
                leading()
                Section {
                    CompactModelPicker(options: options, browsing: $browsing, apply: apply)
                } header: {
                    Text("Model")
                } footer: {
                    if CompactModelPicker.shownProvider(options, browsing) == "open" {
                        Text("Run by \(isCodex ? "Codex" : "Claude Code") on the PC's graphics card, at medium effort.")
                    }
                }
                if options.openModel == nil, let efforts = currentModel?.efforts, !efforts.isEmpty {
                    Section {
                        EffortSlider(efforts: efforts, effort: options.effort, defaultEffort: currentModel?.defaultEffort) {
                            apply(.init(effort: $0))
                        }
                        .id(options.model)
                        if let fast = options.fastMode {
                            Toggle(isOn: Binding(get: { fast }, set: { apply(.init(fastMode: $0)) })) {
                                Label("Fast mode", systemImage: "hare")
                            }
                        }
                    } header: {
                        Text("Effort")
                    } footer: {
                        if options.fastMode != nil {
                            Text(isCodex ? "Fast mode gives faster replies with higher usage. Applies to the next reply; availability depends on your model and plan." : "Requires usage credits and account support; billed outside your subscription allowance. Applies after the current reply.")
                        }
                    }
                }

                if !options.modes.isEmpty {
                    Section("Permissions") {
                        PermissionsRow(modes: options.modes, selected: options.mode) { apply(.init(mode: $0)) }
                    }
                }

            }
    }
}

/// The model, compactly: the provider (Claude, Codex or the PC's open models), then one row
/// with the model in use that drops down that provider's models, each with its detail line
/// and the current one checked. Picking another provider's model switches to it. Two rows
/// however many models there are; Chat Settings, New Chat and the Desk's start step use it.
struct CompactModelPicker: View {
    let options: Companion.ChatOptions
    /// Which provider's models the menu lists; nil: the one in use.
    @Binding var browsing: String?
    let apply: (Companion.SettingsRequest) -> Void

    /// The provider in use: an open model's, or the agent's.
    static func provider(_ options: Companion.ChatOptions) -> String { options.openModel != nil ? "open" : options.backend }
    static func shownProvider(_ options: Companion.ChatOptions, _ browsing: String?) -> String { browsing ?? provider(options) }
    static func providerName(_ provider: String) -> String {
        switch provider {
        case "open": "Open models"
        case "codex": "Codex"
        default: "Claude"
        }
    }

    private var provider: String { Self.provider(options) }
    private var shownProvider: String { Self.shownProvider(options, browsing) }
    private var currentID: String { options.openModel ?? options.model }
    private var shownModels: [Companion.ModelOption] {
        switch shownProvider {
        case "open": options.openModels ?? []
        case "codex": options.codexModels
        default: options.claudeModels
        }
    }
    /// The model in use, when the menu lists its provider's.
    private var current: Companion.ModelOption? {
        guard shownProvider == provider else { return nil }
        return shownModels.first { $0.id == currentID }
    }

    private var emptyNote: String {
        switch shownProvider {
        case "open": "No open models: the PC is off or still being checked."
        case "codex": "Models load once Codex starts on the Mac."
        default: "Models load once Claude Code starts on the Mac."
        }
    }

    private func change(picking model: Companion.ModelOption) -> Companion.SettingsRequest {
        switch shownProvider {
        case "open": .init(openModel: model.id)
        case options.backend: .init(model: model.id)
        default: .init(backend: shownProvider, model: model.id)
        }
    }

    private func detail(for model: Companion.ModelOption) -> String {
        shownProvider == "open" || shownProvider == options.backend ? model.detail
            : "switches to \(shownProvider == "codex" ? "Codex" : "Claude")"
    }

    var body: some View {
        // The provider first; its models drop down from the row under it.
        Picker("Provider", selection: Binding(get: { shownProvider }, set: { browsing = $0 == provider ? nil : $0 })) {
            Text("Claude").tag("claude")
            Text("Codex").tag("codex")
            if options.openModels != nil { Text("Open models").tag("open") }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("model-provider")
        if shownModels.isEmpty {
            Text(emptyNote).foregroundStyle(.secondary)
        } else {
            Menu {
                // Toggles: a menu checks the one in use and shows each detail under its name.
                ForEach(shownModels) { model in
                    Toggle(isOn: Binding(get: { model.id == current?.id }, set: { on in
                        // The one in use, tapped again, stays.
                        guard on else { return }
                        apply(change(picking: model))
                        browsing = nil
                    })) {
                        Text(model.name)
                        if !detail(for: model).isEmpty { Text(detail(for: model)) }
                    }
                }
            } label: {
                row
            }
            // The row in the text's own colors, not tinted like a button.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityIdentifier("model-current")
        }
    }

    /// The model in use (or, browsing another provider, a prompt to pick one of its), with its detail.
    private var row: some View {
        let other = shownProvider == "open" ? "Choose an open model" : "Choose a \(Self.providerName(shownProvider)) model"
        let title = current?.name ?? (shownProvider == provider ? (currentID.isEmpty ? "Default" : currentID) : other)
        let line = current.map(detail(for:)) ?? (shownProvider == provider ? "" : shownProvider == "open" ? "Runs on the PC" : "Switches to \(Self.providerName(shownProvider))")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.isEmpty ? "Model: \(title)" : "Model: \(title), \(line)")
        .accessibilityHint("Shows the \(shownProvider == "open" ? "open" : Self.providerName(shownProvider)) models")
    }
}

extension ChatSettingsForm where Leading == EmptyView {
    init(options: Companion.ChatOptions, apply: @escaping (Companion.SettingsRequest) -> Void) {
        self.init(options: options, apply: apply) { EmptyView() }
    }
}

enum ChatSettingsLabels {
    /// "xhigh" → "Extra High", the way the Mac names them.
    static func effort(_ effort: String) -> String {
        effort == "xhigh" ? "Extra High" : effort.capitalized
    }
}

/// Effort as a slider that snaps to the levels the model supports, weakest first. With no
/// effort chosen it rests on the model's default; the change is sent when you let go.
private struct EffortSlider: View {
    let efforts: [String]
    let effort: String
    let defaultEffort: String?
    let choose: (String) -> Void
    @State private var position: Double?

    private var current: Int {
        efforts.firstIndex(of: effort) ?? defaultEffort.flatMap { efforts.firstIndex(of: $0) } ?? 0
    }
    private var shown: Int { position.map { Int($0.rounded()) } ?? current }
    private var isDefault: Bool { position == nil && effort.isEmpty }

    private func label(_ index: Int) -> String {
        let name = ChatSettingsLabels.effort(efforts[index])
        return isDefault && efforts[index] == defaultEffort ? "\(name) (default)" : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Effort", systemImage: "gauge.with.dots.needle.50percent")
                Spacer()
                Text(label(shown)).foregroundStyle(.secondary).monospacedDigit()
            }
            if efforts.count > 1 {
                Slider(
                    value: Binding(get: { position ?? Double(current) }, set: { position = $0 }),
                    in: 0...Double(efforts.count - 1),
                    step: 1
                ) {
                    Text("Effort")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "brain").foregroundStyle(.secondary)
                } onEditingChanged: { editing in
                    guard !editing, let position else { return }
                    let picked = efforts[Int(position.rounded())]
                    if picked != effort { choose(picked) }
                    // Keep showing the pick until the Mac's answer replaces `effort`.
                }
                .accessibilityValue(label(shown))
                HStack {
                    ForEach(efforts.indices, id: \.self) { index in
                        Text(efforts[index] == "xhigh" ? "X-High" : ChatSettingsLabels.effort(efforts[index]))
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(index == shown ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : index == efforts.count - 1 ? .trailing : .center)
                    }
                }
                .padding(.horizontal, 20)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: effort) { _, _ in position = nil }
    }
}

/// The four access levels as one row of equal icon-only buttons; the chosen one is filled
/// (orange when unrestricted), and its name and meaning sit underneath.
private struct PermissionsRow: View {
    let modes: [Companion.ModeOption]
    let selected: String
    let choose: (String) -> Void

    private var current: Companion.ModeOption? { modes.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(modes) { mode in
                    let isOn = mode.id == selected
                    let color: Color = mode.isUnrestricted ? .orange : .accentColor
                    Button { if !isOn { choose(mode.id) } } label: {
                        Image(systemName: mode.systemImage)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(isOn ? Color.white : (mode.isUnrestricted ? Color.orange : Color.primary))
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isOn ? color : Color(.tertiarySystemFill))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityHint(mode.detail)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            if let current {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(current.isUnrestricted ? .orange : .primary)
                    if !current.detail.isEmpty {
                        Text(current.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

