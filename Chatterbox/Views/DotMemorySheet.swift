import SwiftUI

/// Dot's memory: the files Claude Code keeps for Dot (MEMORY.md, its index, first), to read
/// and edit. Dot reads them at the start of each session and adds to them as it learns.
struct DotMemorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var text = ""
    @State private var saved = ""
    @State private var error: String?

    private var folder: URL { AppModel.dotMemoryFolder }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.dotName)'s Memory").font(.title3.weight(.semibold))
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selected ?? folder]) }
            }
            Text("What \(model.dotName) remembers about you and your work. It reads these at the start of each session and adds to them as it learns. MEMORY.md is the index; each memory is its own file. Changes reach its next session, or tell it you changed something.")
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                List(files, id: \.self, selection: Binding(get: { selected }, set: { open($0) })) { file in
                    Text(file.lastPathComponent).lineLimit(1)
                }
                .frame(minWidth: 170, maxWidth: 240)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(minWidth: 380)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Done", role: .cancel) { saveIfChanged(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { saveIfChanged() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(text == saved)
            }
        }
        .padding(20)
        .frame(width: 820, height: 640)
        .onAppear(perform: reload)
    }

    private func reload() {
        let all = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent == "MEMORY.md" || ($1.lastPathComponent != "MEMORY.md" && $0.lastPathComponent < $1.lastPathComponent) }
        files = all
        open(selected ?? all.first)
    }

    private func open(_ file: URL?) {
        saveIfChanged()
        selected = file
        text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        saved = text
    }

    private func saveIfChanged() {
        guard let selected, text != saved else { return }
        do {
            try text.write(to: selected, atomically: true, encoding: .utf8)
            saved = text
            error = nil
        } catch {
            self.error = "Couldn't save \(selected.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

