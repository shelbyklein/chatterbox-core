import SwiftUI

/// Edits a Studio's instructions: what it's for, and the sites, files, and tools its chats
/// should use. Every chat in the Studio gets them; open chats pick up changes with their
/// next message.
struct StudioInstructionsSheet: View {
    let studio: Studio
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private static let placeholder = """
    What this Studio is for:
    USA Archery marketing and design: event graphics, social posts, print pieces.

    Where to look:
    - usarchery.org for events, rules, athletes, and official wording
    - The brand guide in ~/Documents/USA Archery/brand
    - SmugMug for event photos

    How to work:
    - Use the official logos and colors; never redraw them.
    - Save finished files in an Exports folder.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(studio.name) Instructions").font(.title3.weight(.semibold))
                Text("Every chat in this Studio follows these. Say what it's for, and point to the sites, files, and tools to use.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("Open chats get the new version with their next message.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setInstructions(text, forStudio: studio.id)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear { text = studio.instructions ?? "" }
    }
}
