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

    /// Which agent's models the list shows; picking one from the other agent switches to it.
    @State private var browsing: String?
    private var isCodex: Bool { options.backend == "codex" }
    private var models: [Companion.ModelOption] { isCodex ? options.codexModels : options.claudeModels }
    private var currentModel: Companion.ModelOption? { models.first { $0.id == options.model } }
    private var shownAgent: String { browsing ?? options.backend }
    private var shownModels: [Companion.ModelOption] { shownAgent == "codex" ? options.codexModels : options.claudeModels }

    var body: some View {
            Form {
                leading()
                if let favorites = options.favorites, !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(Array(favorites.enumerated()), id: \.element) { index, favorite in
                            Button { apply(.init(backend: favorite.backend, model: favorite.model)) } label: {
                                HStack {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 18)
                                    row(favorite.name, detail: favorite.backend == options.backend ? "" : "switches to \(favorite.backend == "codex" ? "Codex" : "Claude")",
                                        isOn: favorite.backend == options.backend && favorite.model == options.model)
                                }
                            }
                            .buttonStyle(ChoiceRowStyle())
                            .accessibilityIdentifier("favorite-\(index + 1)")
                        }
                    }
                }

                if let efforts = currentModel?.efforts, !efforts.isEmpty {
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

                Section("All models") {
                    // Browses either agent's list; picking from the other one switches to it.
                    Picker("Agent", selection: Binding(get: { shownAgent }, set: { browsing = $0 })) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    .pickerStyle(.segmented)
                    if shownModels.isEmpty {
                        Text("Models load once \(shownAgent == "codex" ? "Codex" : "Claude Code") starts on the Mac.").foregroundStyle(.secondary)
                    }
                    ForEach(shownModels) { model in
                        Button {
                            apply(shownAgent == options.backend ? .init(model: model.id) : .init(backend: shownAgent, model: model.id))
                            browsing = nil
                        } label: {
                            row(model.name, detail: shownAgent == options.backend ? model.detail : "switches to \(shownAgent == "codex" ? "Codex" : "Claude")",
                                isOn: shownAgent == options.backend && model.id == options.model)
                        }
                        .buttonStyle(ChoiceRowStyle())
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

