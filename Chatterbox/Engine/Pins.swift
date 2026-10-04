import Foundation
#if !CHATTERBOX_HEADLESS
import AppKit
#endif
import Observation

/// Where a pin shows: a project or a Studio, whose pins appear while you're in one of its
/// chats. Pins with no place show everywhere.
struct PinPlace: Equatable {
    /// "project:<folder>" or "studio:<id>", stored on the pin.
    var key: String
    var name: String
}

/// Something you open often: a website, an app, a file or folder, or a macOS Shortcut.
/// Shown at the top of the sidebar; the first nine open with ⌃⌘1–⌃⌘9.
struct Pin: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case website, app, file, shortcut

        var label: String {
            switch self {
            case .website: "Website"
            case .app: "App"
            case .file: "File or Folder"
            case .shortcut: "Shortcut"
            }
        }
    }

    var id = UUID()
    var title: String
    var kind: Kind
    /// A URL, an app or file path, or a Shortcut's name.
    var target: String
    /// The project or Studio it belongs to (a `PinPlace` key); nil shows it everywhere.
    var place: String?
}

@MainActor
@Observable
final class PinStore {
    static let shared = PinStore()

    private(set) var pins: [Pin]
    #if !CHATTERBOX_HEADLESS
    /// Favicons for website pins, fetched from the site itself.
    private(set) var favicons: [String: NSImage] = [:]
    @ObservationIgnored private var loadingFavicons: Set<String> = []
    #endif
    private let key = "pins"

    init() {
        if let data = AppPreferences.defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Pin].self, from: data) {
            pins = saved
        } else {
            pins = []
        }
    }

    /// Pins that show everywhere.
    var globalPins: [Pin] { pins.filter { $0.place == nil } }

    func pins(in place: PinPlace?) -> [Pin] {
        guard let place else { return [] }
        return pins.filter { $0.place == place.key }
    }

    /// What's shown with this place open, in ⌃⌘-number order: global pins, then its own.
    func visiblePins(in place: PinPlace?) -> [Pin] { globalPins + pins(in: place) }

    func add(_ pin: Pin) {
        guard !pins.contains(where: { $0.kind == pin.kind && $0.target == pin.target && $0.place == pin.place }) else { return }
        pins.append(pin)
        save()
    }

    func remove(_ pin: Pin) {
        pins.removeAll { $0.id == pin.id }
        save()
    }

    /// Moves a pin to a project or Studio, or makes it global with nil.
    func setPlace(_ pin: Pin, to place: PinPlace?) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        pins[index].place = place?.key
        save()
    }

    func rename(_ pin: Pin, to title: String) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }), !title.isEmpty else { return }
        pins[index].title = title
        save()
    }

    /// Moves a pin to where `target` is, for drag-to-reorder.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = pins.firstIndex(where: { $0.id == id }),
              let to = pins.firstIndex(where: { $0.id == target }) else { return }
        pins.insert(pins.remove(at: from), at: to)
        save()
    }

    /// Settings > General: website pins open inside Chatterbox, with the chat floating over
    /// the page.
    static let openInAppKey = "openWebsitePinsInApp"
    static var opensInApp: Bool { AppPreferences.defaults.object(forKey: openInAppKey) as? Bool ?? true }
    /// Shows a page inside Chatterbox (set by AppModel).
    @ObservationIgnored var showPage: ((URL) -> Void)?

    #if !CHATTERBOX_HEADLESS
    func open(_ pin: Pin) {
        switch pin.kind {
        case .website:
            guard let url = Self.normalizedURL(pin.target) else { return }
            if Self.opensInApp, let showPage { showPage(url) } else { NSWorkspace.shared.open(url) }
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: pin.target), configuration: NSWorkspace.OpenConfiguration())
        case .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: pin.target))
        case .shortcut:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", pin.target]
            try? process.run()
        }
    }

    #else
    func open(_ pin:Pin) { NotificationCenter.default.post(name:Notification.Name("ChatterboxRuntimeOpenPin"),object:pin) }
    #endif

    func open(number: Int, in place: PinPlace?) {
        let shown = visiblePins(in: place)
        guard shown.indices.contains(number - 1) else { return }
        open(shown[number - 1])
    }

    /// Adds "https://" when a URL was typed without a scheme.
    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        let local = trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1")
        return URL(string: (local ? "http://" : "https://") + trimmed)
    }

    /// Whether a pin's target still exists (apps and files can move or be deleted).
    func isAvailable(_ pin: Pin) -> Bool {
        switch pin.kind {
        case .app, .file: FileManager.default.fileExists(atPath: pin.target)
        case .website, .shortcut: true
        }
    }

    // MARK: - Icons

    #if !CHATTERBOX_HEADLESS
    func icon(for pin: Pin) -> NSImage? {
        switch pin.kind {
        case .app, .file:
            return FileManager.default.fileExists(atPath: pin.target) ? NSWorkspace.shared.icon(forFile: pin.target) : nil
        case .website:
            guard let host = Self.normalizedURL(pin.target)?.host else { return nil }
            if let image = favicons[host] { return image }
            loadFavicon(for: pin.target, host: host)
            return nil
        case .shortcut:
            return nil
        }
    }

    private func loadFavicon(for target: String, host: String) {
        guard !loadingFavicons.contains(host), let url = Self.normalizedURL(target),
              let scheme = url.scheme, let favicon = URL(string: "\(scheme)://\(url.host ?? host)\(url.port.map { ":\($0)" } ?? "")/favicon.ico") else { return }
        loadingFavicons.insert(host)
        Task {
            var request = URLRequest(url: favicon)
            request.timeoutInterval = 5
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
            favicons[host] = image
        }
    }

    #endif

    // MARK: - Suggestions

    /// Apps in /Applications and ~/Applications, for the add sheet.
    static func installedApps() -> [URL] {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "\(NSHomeDirectory())/Applications", "/System/Applications"]
        let apps = folders.flatMap { folder in
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        return apps.sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }
    }

    /// Your macOS Shortcuts, from the `shortcuts` command.
    static func shortcutNames() async -> [String] {
        let result = await Git.run("/usr/bin/shortcuts", ["list"])
        guard result.status == 0 else { return [] }
        return result.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func save() {
        #if !CHATTERBOX_HEADLESS
        if RuntimeClient.usesDaemon {RuntimeClient.shared.command("pins",body:["pins":(try? .value(pins)) ?? []]);return}
        #endif
        if let data = try? JSONEncoder().encode(pins) { AppPreferences.defaults.set(data, forKey: key) }
    }
    func applyRuntimePins(_ values:[Pin]){pins=values}
}
