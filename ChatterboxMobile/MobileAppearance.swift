import SwiftUI

/// The phone's own look: light or dark, and each agent's color (the same choices as the Mac's
/// Settings → Appearance). Kept on this device.
enum MobileAppearance {
    static let schemeKey = "mobileThemeScheme"          // system | light | dark
    static let claudeKey = "readerClaudeColor"
    static let codexKey = "readerCodexColor"

    static var claudeColor: String { AppPreferences.defaults.string(forKey: claudeKey) ?? ReaderStyle.claudeDefault }
    static var codexColor: String { AppPreferences.defaults.string(forKey: codexKey) ?? ReaderStyle.codexDefault }

    /// The color you picked for an agent, or nil for its built-in one.
    static func chosen(for backend: String) -> Color? {
        let id = backend == "codex" ? codexColor : claudeColor
        let builtIn = backend == "codex" ? ReaderStyle.codexDefault : ReaderStyle.claudeDefault
        return id == builtIn ? nil : ReaderStyle.bubbleColor(id)
    }

    static func colorScheme(_ id: String) -> ColorScheme? { id == "light" ? .light : id == "dark" ? .dark : nil }
}

/// Appearance, from the chat list's menu. Changes apply when you tap Done.
struct MobileAppearanceSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scheme = AppPreferences.defaults.string(forKey: MobileAppearance.schemeKey) ?? "system"
    @State private var claude = MobileAppearance.claudeColor
    @State private var codex = MobileAppearance.codexColor

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $scheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Claude") { swatches($claude, icon: "AgentClaude") }
                Section("Codex") { swatches($codex, icon: "AgentCodex") }
                Section {
                    Button("Restore Defaults") {
                        scheme = "system"; claude = ReaderStyle.claudeDefault; codex = ReaderStyle.codexDefault
                    }
                } footer: {
                    Text("Agent colors mark each agent's messages, icons and presets. These settings are kept on this \(UIDevice.current.model).")
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } }
            }
        }
        .preferredColorScheme(MobileAppearance.colorScheme(scheme))
    }

    private func swatches(_ selection: Binding<String>, icon: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
            ForEach(ReaderStyle.bubbleColors, id: \.id) { option in
                let on = selection.wrappedValue == option.id
                Button { selection.wrappedValue = option.id } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(option.color).frame(width: 36, height: 36)
                            Image(icon).resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(.white)
                        }
                        .overlay(Circle().strokeBorder(on ? Color.primary : .clear, lineWidth: 2).padding(-4))
                        Text(option.label).font(.caption2).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 6)
    }

    private func save() {
        let defaults = AppPreferences.defaults
        defaults.set(scheme, forKey: MobileAppearance.schemeKey)
        defaults.set(claude, forKey: MobileAppearance.claudeKey)
        defaults.set(codex, forKey: MobileAppearance.codexKey)
    }
}
