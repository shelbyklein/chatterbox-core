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

    /// Which provider's models the list shows ("claude", "codex" or "open"); picking one
    /// from another provider switches to it.
    @State private var browsing: String?
    private var isCodex: Bool { options.backend == "codex" }
    private var models: [Companion.ModelOption] { isCodex ? options.codexModels : options.claudeModels }
    private var currentModel: Companion.ModelOption? { models.first { $0.id == options.model } }
    /// The provider in use: an open model's, or the agent's.
    private var provider: String { options.openModel != nil ? "open" : options.backend }
    private var currentID: String { options.openModel ?? options.model }
    private var shownProvider: String { browsing ?? provider }
    private var shownModels: [Companion.ModelOption] {
        switch shownProvider {
        case "open": options.openModels ?? []
        case "codex": options.codexModels
        default: options.claudeModels
        }
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
            Form {
                leading()
                Section {
                    // The provider first; its models drop down under it. Picking another
                    // provider's model switches to it.
                    Picker("Provider", selection: Binding(get: { shownProvider }, set: { browsing = $0 })) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                        if options.openModels != nil { Text("Open models").tag("open") }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("model-provider")
                    if shownModels.isEmpty {
                        Text(emptyNote).foregroundStyle(.secondary)
                    }
                    ForEach(shownModels) { model in
                        Button {
                            apply(change(picking: model))
                            browsing = nil
                        } label: {
                            row(model.name, detail: detail(for: model), isOn: shownProvider == provider && model.id == currentID)
                        }
                        .buttonStyle(ChoiceRowStyle())
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if shownProvider == "open" {
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

    private func row(_ title: String, detail: String, isOn: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if isOn { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
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

/// A whole-row button in a form, in the text's own colors.
private struct ChoiceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
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

