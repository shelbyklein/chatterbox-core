import Foundation
import Observation

/// The tools a thread gets, as chips: its sidebar's Tools section on the Mac, and the phone's
/// About panel (ChatDetail.tools). Reading the agents' own configs can take a moment (a large
/// ~/.claude.json), so it's done off the main thread and kept for a minute per agent and folder.
@MainActor @Observable
final class ThreadTools {
    static let shared = ThreadTools()
    private struct Entry { var chips: [Companion.ToolChip]; var at: Date }
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    static let lifetime: TimeInterval = 60

    /// What the session gets, newest known; nil until the first look finishes. Asking starts a
    /// fresh look when the last one is over a minute old.
    func chips(for session: ChatSession) -> [Companion.ToolChip]? {
        let key = Self.key(session)
        let entry = entries[key]
        if entry.map({ Date().timeIntervalSince($0.at) > Self.lifetime }) ?? true { refresh(session, key: key) }
        return entry?.chips
    }

    #if DEBUG
    /// For render tests: these chips, as if just looked up, so no real agent config is read.
    func seed(_ chips: [Companion.ToolChip], for session: ChatSession) {
        entries[Self.key(session)] = Entry(chips: chips, at: .distantFuture)
    }
    #endif

    private static func key(_ session: ChatSession) -> String {
        "\(session.record.backend.rawValue)|\(session.record.boundFolder ?? "")|\(session.record.studioID?.uuidString ?? "")"
    }

    private func refresh(_ session: ChatSession, key: String) {
        guard loading.insert(key).inserted else { return }
        let backend = session.record.backend, folder = session.record.boundFolder
        let tools = ToolScopes.effective(for: session)
        Task {
            let chips = await Task.detached(priority: .utility) {
                Self.chips(ToolDiscovery.loadedServers(backend, projectFolder: folder, tools: tools), off: tools.off)
            }.value
            self.loading.remove(key)
            if self.entries[key]?.chips != chips || self.entries[key] == nil {
                self.entries[key] = Entry(chips: chips, at: Date())
            } else {
                self.entries[key]?.at = Date()
            }
        }
    }

    /// Servers in the order the agent loads them, then connectors and skills switched off.
    nonisolated static func chips(_ servers: [ToolDiscovery.LoadedServer], off: Set<String>) -> [Companion.ToolChip] {
        var seen = Set<String>()
        var chips: [Companion.ToolChip] = []
        for server in servers where seen.insert(server.name).inserted {
            let on = server.state == .on || server.state == .addedInChatterbox
            chips.append(.init(name: server.name, kind: "server", isOn: on))
        }
        for key in off.sorted() where !key.hasPrefix("server:") {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            chips.append(.init(name: parts[1], kind: parts[0], isOn: false))
        }
        return chips
    }
}
