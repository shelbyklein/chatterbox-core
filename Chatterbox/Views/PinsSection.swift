import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the Add Pin sheet opens with: which place the new pin goes to, and the place
/// that's open (offered as a choice).
struct PinSheetRequest: Identifiable {
    let id = UUID()
    var place: PinPlace?
    var current: PinPlace?
}

/// The global pins at the top of the sidebar. A project's or Studio's own pins show as
/// pills under its name instead (see PinPills). Click a pin to open it; drop an app, file,
/// or link here to pin it; right-click to rename, move, or remove; drag to reorder.
struct PinsSection: View {
    /// The project or Studio of the chat that's open.
    let place: PinPlace?
    let onAdd: (PinSheetRequest) -> Void
    @State private var renaming: Pin?
    @State private var newTitle = ""
    @State private var dropTargeted = false
    private var store: PinStore { .shared }

    /// Six square cards to a row: icons, with the name on hover.
    static let columns = 6

    var body: some View {
        let global = store.globalPins
        VStack(alignment: .leading, spacing: 6) {
            header("Pins", help: "Add a pin that shows everywhere") { onAdd(PinSheetRequest(place: nil, current: place)) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if global.isEmpty {
                Text("Pin websites, apps, folders, or Shortcuts you open often. Drop them here, or click +.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 26), spacing: 5), count: Self.columns), spacing: 5) {
                    ForEach(Array(global.enumerated()), id: \.element.id) { index, pin in
                        card(pin, number: index < 9 ? index + 1 : nil)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.highlight.opacity(dropTargeted ? 0.6 : 0), lineWidth: 1.5))
        .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted) { dropped($0, place: nil) }
        .alert("Rename Pin", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") { if let pin = renaming { store.rename(pin, to: newTitle.trimmingCharacters(in: .whitespaces)) } }
            Button("Cancel", role: .cancel) {}
        }

    }

    private func header(_ title: String, help: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help(help)
        }
    }

    /// A pin as a square card: its icon, the name on hover and for VoiceOver.
    private func card(_ pin: Pin, number: Int?) -> some View {
        Button { store.open(pin) } label: {
            PinIcon(pin: pin)
                .padding(7)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(pin.title)
        .accessibilityLabel(pin.title)
        .accessibilityHint("Opens the pin")
        .modifier(PinMenu(pin: pin, place: place, store: store, rename: { newTitle = pin.title; renaming = pin }))
    }

    private func row(_ pin: Pin, number: Int?) -> some View {
        PinRow(pin: pin, number: number)
            .contextMenu {
                Button("Open") { store.open(pin) }
                Button("Rename\u{2026}") { newTitle = pin.title; renaming = pin }
                if pin.kind == .app || pin.kind == .file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pin.target)]) }
                }
                if pin.kind == .website {
                    Button("Open in Browser") { if let url = PinStore.normalizedURL(pin.target) { NSWorkspace.shared.open(url) } }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pin.target, forType: .string)
                    }
                }
                Divider()
                if pin.place != nil {
                    Button("Show Everywhere") { store.setPlace(pin, to: nil) }
                } else if let place {
                    Button("Move to \(place.name)") { store.setPlace(pin, to: place) }
                }
                Divider()
                Button("Remove Pin", role: .destructive) { store.remove(pin) }
            }
            .draggable(pin.id.uuidString)
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first.flatMap(UUID.init(uuidString:)),
                      let dragged = store.pins.first(where: { $0.id == id }), dragged.place == pin.place else { return false }
                store.move(id, to: pin.id)
                return true
            }
    }

    /// Apps and files pin as themselves; links (say, dragged from a browser) pin as websites.
    private func dropped(_ providers: [NSItemProvider], place: PinPlace?) -> Bool {
        let key = place?.key
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in
                        let isApp = url.pathExtension == "app"
                        PinStore.shared.add(Pin(title: isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                                                kind: isApp ? .app : .file, target: url.path, place: key))
                    }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, !url.isFileURL else { return }
                    Task { @MainActor in
                        PinStore.shared.add(Pin(title: url.host ?? url.absoluteString, kind: .website, target: url.absoluteString, place: key))
                    }
                }
            }
        }
        return true
    }
}

/// A project's or Studio's pins as small pills under its name in the sidebar. Click one to
/// open it; right-click to rename, copy, show everywhere, or remove.
struct PinPills: View {
    let pins: [Pin]
    var onOpen: () -> Void = {}
    @State private var renaming: Pin?
    @State private var newTitle = ""
    private var store: PinStore { .shared }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(pins) { pin in
                Button { onOpen(); store.open(pin) } label: {
                    HStack(spacing: 4) {
                        PinIcon(pin: pin).frame(width: 11, height: 11)
                        Text(pin.title).lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(pin.target)
                .contextMenu {
                    Button("Open") { onOpen(); store.open(pin) }
                    if pin.kind == .website {
                        Button("Open in Browser") { if let url = PinStore.normalizedURL(pin.target) { NSWorkspace.shared.open(url) } }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pin.target, forType: .string)
                        }
                    }
                    if pin.kind == .app || pin.kind == .file {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pin.target)]) }
                    }
                    Button("Rename\u{2026}") { newTitle = pin.title; renaming = pin }
                    Divider()
                    Button("Show Everywhere") { store.setPlace(pin, to: nil) }
                    Button("Remove Pin", role: .destructive) { store.remove(pin) }
                }
            }
        }
        .alert("Rename Pin", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") { if let pin = renaming { store.rename(pin, to: newTitle.trimmingCharacters(in: .whitespaces)) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Pins a dropped link, file, or app to `place`.
    static func drop(_ providers: [NSItemProvider], into place: PinPlace) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if url.isFileURL {
                        let isApp = url.pathExtension == "app"
                        PinStore.shared.add(Pin(title: isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                                                kind: isApp ? .app : .file, target: url.path, place: place.key))
                    } else {
                        PinStore.shared.add(Pin(title: url.host ?? url.absoluteString, kind: .website, target: url.absoluteString, place: place.key))
                    }
                }
            }
        }
        return true
    }
}

private struct PinRow: View {
    let pin: Pin
    let number: Int?
    private var store: PinStore { .shared }

    var body: some View {
        Button { store.open(pin) } label: {
            HStack(spacing: 7) {
                PinIcon(pin: pin).frame(width: 16, height: 16)
                Text(pin.title).lineLimit(1)
                Spacer(minLength: 0)
                if !store.isAvailable(pin) {
                    Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .help("\(pin.target) is missing")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(number.map { "\(pin.target)  (\u{2303}\u{2318}\($0))" } ?? pin.target)
    }
}

struct PinIcon: View {
    let pin: Pin

    // GitHub's monochrome favicon has a transparent background. Treat its alpha
    // as a mask so it follows the sidebar theme without tinting other brands.
    var usesTemplateIcon: Bool {
        guard pin.kind == .website,
              let host = PinStore.normalizedURL(pin.target)?.host?.lowercased() else { return false }
        return host == "github.com" || host == "www.github.com"
    }

    var body: some View {
        if let image = PinStore.shared.icon(for: pin) {
            Image(nsImage: image)
                .renderingMode(usesTemplateIcon ? .template : .original)
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: pin.kind == .shortcut ? "square.stack.3d.up.fill" : pin.kind == .website ? "globe" : "doc")
                .foregroundStyle(.secondary)
        }
    }
}

/// Adding a pin: pick the kind, then a site, app, file, or Shortcut. Apps you likely want
/// (those not yet pinned) are suggested.
struct AddPinSheet: View {
    let request: PinSheetRequest
    @Environment(\.dismiss) private var dismiss
    @State private var placeKey: String?
    @State private var kind: Pin.Kind = .website
    @State private var title = ""
    @State private var url = ""
    @State private var appQuery = ""
    @State private var apps: [URL] = []
    @State private var shortcuts: [String] = []
    @State private var loadedShortcuts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add a Pin").font(.title3.weight(.semibold))
                Spacer()
                if let current = request.current {
                    Picker("Show", selection: $placeKey) {
                        Text("Everywhere").tag(String?.none)
                        Text("In \(current.name)").tag(String?.some(current.key))
                    }
                    .fixedSize()
                    .help("Where this pin shows: in every chat, or only in \(current.name)'s chats")
                }
            }
            Picker("Kind", selection: $kind) {
                ForEach(Pin.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch kind {
                case .website: websiteForm
                case .app: appList
                case .file: fileChooser
                case .shortcut: shortcutList
                }
            }
            .frame(height: 280, alignment: .top)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { placeKey = request.place?.key }
        .task { apps = PinStore.installedApps() }
        .task(id: kind) {
            if kind == .shortcut, !loadedShortcuts {
                shortcuts = await PinStore.shortcutNames()
                loadedShortcuts = true
            }
        }
    }

    private var websiteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Address, e.g. localhost:3000 or ontarget.com", text: $url).textFieldStyle(.roundedBorder)
            TextField("Name (optional)", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Add Pin") {
                    guard let link = PinStore.normalizedURL(url) else { return }
                    let name = title.trimmingCharacters(in: .whitespaces)
                    PinStore.shared.add(Pin(title: name.isEmpty ? (link.host ?? link.absoluteString) : name, kind: .website, target: link.absoluteString, place: placeKey))
                    url = ""
                    title = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(PinStore.normalizedURL(url) == nil)
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search apps", text: $appQuery).textFieldStyle(.roundedBorder)
            List {
                ForEach(filteredApps, id: \.self) { app in
                    let pinned = PinStore.shared.pins.contains { $0.kind == .app && $0.target == app.path && $0.place == placeKey }
                    Button {
                        PinStore.shared.add(Pin(title: app.deletingPathExtension().lastPathComponent, kind: .app, target: app.path, place: placeKey))
                    } label: {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                            Text(app.deletingPathExtension().lastPathComponent)
                            Spacer()
                            if pinned { Image(systemName: "pin.fill").foregroundStyle(Color.highlight) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pinned)
                }
            }
        }
    }

    /// Apps matching the search, with your own projects' apps (in ~/Applications) first.
    private var filteredApps: [URL] {
        let q = appQuery.trimmingCharacters(in: .whitespaces)
        let matched = q.isEmpty ? apps : apps.filter { $0.deletingPathExtension().lastPathComponent.localizedStandardContains(q) }
        let home = NSHomeDirectory() + "/Applications"
        return matched.filter { $0.path.hasPrefix(home) } + matched.filter { !$0.path.hasPrefix(home) }
    }

    private var fileChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pin a file or folder: a project folder, a document, a log.").foregroundStyle(.secondary)
            Button("Choose\u{2026}") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Pin"
                guard panel.runModal() == .OK else { return }
                for url in panel.urls {
                    PinStore.shared.add(Pin(title: url.lastPathComponent, kind: url.pathExtension == "app" ? .app : .file, target: url.path, place: placeKey))
                }
            }
        }
    }

    private var shortcutList: some View {
        Group {
            if !loadedShortcuts {
                ProgressView().frame(maxWidth: .infinity)
            } else if shortcuts.isEmpty {
                Text("No Shortcuts found. Make one in the Shortcuts app, then come back.").foregroundStyle(.secondary)
            } else {
                List(shortcuts, id: \.self) { name in
                    let pinned = PinStore.shared.pins.contains { $0.kind == .shortcut && $0.target == name && $0.place == placeKey }
                    Button { PinStore.shared.add(Pin(title: name, kind: .shortcut, target: name, place: placeKey)) } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.secondary)
                            Text(name)
                            Spacer()
                            if pinned { Image(systemName: "pin.fill").foregroundStyle(Color.highlight) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pinned)
                }
            }
        }
    }
}

/// A pin's right-click menu and drag-to-reorder, for cards.
private struct PinMenu: ViewModifier {
    let pin: Pin
    let place: PinPlace?
    let store: PinStore
    let rename: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Open") { store.open(pin) }
                Button("Rename\u{2026}", action: rename)
                if pin.kind == .app || pin.kind == .file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pin.target)]) }
                }
                if pin.kind == .website {
                    Button("Open in Browser") { if let url = PinStore.normalizedURL(pin.target) { NSWorkspace.shared.open(url) } }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pin.target, forType: .string)
                    }
                }
                Divider()
                if pin.place != nil {
                    Button("Show Everywhere") { store.setPlace(pin, to: nil) }
                } else if let place {
                    Button("Move to \(place.name)") { store.setPlace(pin, to: place) }
                }
                Divider()
                Button("Remove Pin", role: .destructive) { store.remove(pin) }
            }
            .draggable(pin.id.uuidString)
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first.flatMap(UUID.init(uuidString:)),
                      let dragged = store.pins.first(where: { $0.id == id }), dragged.place == pin.place else { return false }
                store.move(id, to: pin.id)
                return true
            }
    }
}
