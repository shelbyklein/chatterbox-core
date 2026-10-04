import SwiftUI
import WebKit

/// Beside Dot's chat: its computer's screen, live. Click and type in it to take over (to sign
/// in somewhere, say). Set it up the first time, then start and stop it here.
struct DotComputerPanel: View {
    static let windowID = "dot-computer"
    @Environment(AppModel.self) private var model
    @State private var showingPreviews = false
    private var computer: DotComputer { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                Text("\(model.dotName)'s Computer").font(.headline)
                statusLabel
                Spacer()
                Button { NSWorkspace.shared.open(DotComputer.downloadsFolder) } label: { Label("Downloads", systemImage: "folder") }
                    .help("The computer's downloads, the one folder it shares with your Mac")
                Button { showingPreviews.toggle() } label: {
                    Label("Local Previews\(PreviewRelays.shared.enabled.isEmpty ? "" : " (\(PreviewRelays.shared.enabled.count))")", systemImage: "network")
                }
                .help("Let the computer's browser open local sites on this Mac, such as SKD Studio previews")
                .popover(isPresented: $showingPreviews, arrowEdge: .bottom) { LocalPreviewsPopover() }
                actions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            content
        }
        .task { await computer.refresh() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch computer.state {
        case .running: Label("Running", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
        case .building, .starting: ProgressView().controlSize(.small)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch computer.state {
        case .running:
            Button("Stop") { Task { await model.stopDotComputer() } }
        case .stopped, .failed:
            Button("Start") { Task { await model.startDotComputer() } }.buttonStyle(.borderedProminent)
        case .notSetUp:
            Button("Set Up") { Task { await model.setUpDotComputer() } }.buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch computer.state {
        case .running:
            LiveScreen(url: computer.viewURL)
        case .building, .starting:
            message("desktopcomputer", computer.progress.isEmpty ? "Starting\u{2026}" : computer.progress)
        case .notSetUp:
            message("desktopcomputer.and.arrow.down",
                    "\(model.dotName) can have its own computer: a small Linux machine with a web browser, separate from your Mac. It browses, reads pages, and fills in forms there while you watch, and you can take over to sign in.\n\nSetting it up downloads about 2.4 GB with Docker, once.")
        case .noDocker:
            message("shippingbox", "\(model.dotName)'s computer runs with Docker. Install Docker Desktop, then come back.")
        case .stopped:
            message("power", "The computer is off. Start it to let \(model.dotName) browse; its logins are kept from last time.")
        case .failed(let reason):
            message("exclamationmark.triangle", reason)
        case .checking:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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

/// The computer's screen through noVNC: live, and clickable to take over.
private struct LiveScreen: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Local sites on this Mac, each with a switch: on, the computer's browser can open it at
/// its usual http://localhost:PORT address. Nothing is reachable from the network.
private struct LocalPreviewsPopover: View {
    private let previews = PreviewRelays.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local Previews").font(.headline)
                Spacer()
                if previews.scanning { ProgressView().controlSize(.small) }
                Button { Task { await previews.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Look again").accessibilityLabel("Refresh")
            }
            Text("Turn on a site to let the computer's browser open it, at the same localhost address you use. Only this Mac can reach it; nothing is shared on the network.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if previews.sites.isEmpty && !previews.scanning {
                Text("No local sites found. Start the site in SKD Studio, then refresh.").foregroundStyle(.secondary)
            }
            ForEach(previews.sites) { site in
                Toggle(isOn: Binding(get: { previews.enabled.contains(site.port) }, set: { previews.setEnabled(site.port, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site.title).lineLimit(1)
                        Text("localhost:\(site.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            // Turned on earlier but not running now.
            ForEach(previews.enabled.sorted().filter { port in !previews.sites.contains { $0.port == port } }, id: \.self) { port in
                Toggle(isOn: Binding(get: { true }, set: { previews.setEnabled(port, $0) })) {
                    Text("localhost:\(port) (not running)").foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
            }
        }
        .padding(14)
        .frame(width: 340)
        .task { await previews.scan() }
    }
}
