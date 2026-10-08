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

enum PinSize: Double, CaseIterable {
    case small = 24, medium = 32, large = 44
    var name: String { switch self { case .small: "Small"; case .medium: "Medium"; case .large: "Large" } }
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
                Text(request.place.map { "In " + $0.name } ?? "Global")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Global shortcuts stay in the window toolbar; editing belongs in Settings > Pins.
struct GlobalPinsToolbar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarPinSize") private var size = PinSize.small.rawValue
    private var store: PinStore { .shared }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(store.globalPins.prefix(8))) { pin in
                Button { store.open(pin) } label: {
                    PinIcon(pin: pin)
                        .padding(4)
                        .frame(width: size, height: size)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pin.title)
                .accessibilityLabel(pin.title)
            }
            if store.globalPins.count > 8 {
                Menu {
                    ForEach(Array(store.globalPins.dropFirst(8))) { pin in
                        Button(pin.title) { store.open(pin) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("More global pins")
            }
            if store.globalPins.isEmpty {
                Button {
                    AppPreferences.defaults.set("pins", forKey: "settingsPage")
                    model.showingSettings = true
                } label: {
                    Image(systemName: "pin").padding(5).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Set up global pins in Settings")
                .accessibilityLabel("Global Pins settings")
            }
        }
        .padding(.horizontal, 5)
        .contextMenu {
            Button("Manage Global Pins…") {
                AppPreferences.defaults.set("pins", forKey: "settingsPage")
                model.showingSettings = true
            }
        }
    }
}

struct PinsSettingsView: View {
    @State private var adding: PinSheetRequest?
    @State private var renaming: Pin?
    @State private var title = ""
    @AppStorage("sidebarPinSize") private var size = PinSize.small.rawValue
    @AppStorage(PinStore.openInAppKey) private var openInApp = true
    private var store: PinStore { .shared }

    var body: some View {
        Form {
            Section {
                Picker("Toolbar icon size", selection: $size) {
                    ForEach(PinSize.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                }
                Toggle("Open website pins inside Chatterbox", isOn: $openInApp)
                    .help("The page opens inside Chatterbox with the chat floating beside it. Off: website pins open in your browser.")
            }
            Section {
                if store.globalPins.isEmpty {
                    Text("Add websites, apps, files, folders or Shortcuts you use everywhere.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.globalPins.enumerated()), id: \.element.id) { index, pin in
                    HStack(spacing: 10) {
                        Button { store.open(pin) } label: { PinIcon(pin: pin).frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help("Open " + pin.title)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pin.title)
                            Text(pin.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            let pins = store.globalPins
                            store.move(pin.id, to: pins[index - 1].id)
                        } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("Move up")
                        Button {
                            let pins = store.globalPins
                            store.move(pin.id, to: pins[index + 1].id)
                        } label: { Image(systemName: "arrow.down") }
                        .disabled(index == store.globalPins.count - 1).help("Move down")
                        Button("Rename") { title = pin.title; renaming = pin }
                        Button { store.remove(pin) } label: { Image(systemName: "trash") }
                            .help("Remove " + pin.title)
                    }
                    .padding(.vertical, 3)
                }
                Button("Add Global Pin…") { adding = PinSheetRequest(place: nil, current: nil) }
            } header: {
                Text("Global pins")
            } footer: {
                Text("Global pins appear in the middle of the top bar. To add a project pin, right-click the project and choose Add Pin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(WideFormStyle())
        .frame(maxWidth: .infinity)
        .sheet(item: $adding) { AddPinSheet(request: $0) }
        .alert("Rename Pin", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $title)
            Button("Rename") { if let pin = renaming { store.rename(pin, to: title.trimmingCharacters(in: .whitespacesAndNewlines)) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
