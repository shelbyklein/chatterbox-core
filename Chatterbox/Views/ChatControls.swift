import SwiftUI

/// The tone button in the toolbar: the current tone's name, with the three to pick from.
struct ToneMenu: View {
    let session: ChatSession

    var body: some View {
        let current = session.record.personality
        Menu {
            Picker("Tone", selection: Binding(get: { current }, set: session.setPersonality)) {
                ForEach(Personality.allCases) { tone in
                    Label(tone.label, systemImage: Self.icon(tone)).tag(tone)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ToolbarLabel(current.label, systemImage: Self.icon(current))
        }
        .help("Tone: \(current.label). Changes apply from your next message.")
    }

    static func icon(_ tone: Personality) -> String {
        switch tone {
        case .friendly: "face.smiling"
        case .pragmatic: "wrench.and.screwdriver"
        case .neutral: "circle.dashed"
        }
    }
}

/// The preset buttons under the message box, tinted with each preset's agent color.
/// Right-click to rename or delete one; drag one onto another to reorder.
struct PresetPills: View {
    let session: ChatSession
    let style: ReaderStyle
    private let presets = ModelPresets.shared
    @State private var renaming: ModelPreset?
    @State private var newTitle = ""
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 6) {
            // Dot only takes Claude presets.
            ForEach(presets.presets) { preset in pill(preset) }
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") {
                if let renaming { presets.rename(renaming, to: newTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func pill(_ preset: ModelPreset) -> some View {
        let active = presets.matches(preset, session: session)
        let color = style.color(for: preset.backend)
        let targeted = dropTarget == preset.id
        return Button { presets.apply(preset, to: session) } label: {
            Text(preset.title)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(active ? 0.3 : 0.1)))
                .overlay(Capsule().strokeBorder(active || targeted ? color : .clear, lineWidth: 1))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.isRunning && preset.backend != session.record.backend)
        .help(active ? "Using \(preset.title)" : "Switch to \(preset.title). Right-click to rename or delete; drag to reorder.")
        .contextMenu {
            Button("Rename\u{2026}") {
                newTitle = preset.title
                renaming = preset
            }
            Button("Delete", role: .destructive) { presets.remove(preset) }
        }
        .draggable(preset.id.uuidString) {
            Text(preset.title)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.3)))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            presets.move(id, to: preset.id)
            return true
        } isTargeted: { dropTarget = $0 ? preset.id : (dropTarget == preset.id ? nil : dropTarget) }
    }
}
