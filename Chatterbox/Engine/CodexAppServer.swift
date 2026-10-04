import Foundation
import Observation

struct CodexError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct CodexModelInfo: Identifiable, Hashable {
    var id: String { model }
    var model: String
    var displayName: String
    var defaultEffort: String
    var efforts: [String]
    /// Hidden from Codex's own default picker, but still usable.
    var hidden: Bool
    /// The model Codex uses when a chat doesn't pick one.
    var isDefault: Bool = false
}

/// One shared `codex app-server` process, spoken to with JSON-RPC over stdio. It runs in
/// ChatterboxHost, so turns keep going after the app quits; on relaunch the app reattaches
/// and replays what it missed (see `resume`).
/// It uses the user's own Codex install, config, and ChatGPT sign-in.
@MainActor
@Observable
final class CodexAppServer {
    static let shared = CodexAppServer()

    private(set) var models: [CodexModelInfo] = []
    /// Skills per working folder, from `skills/list`.
    private(set) var skills: [String: [SlashCommand]] = [:]
    private(set) var statusMessage: String?

    /// The app-server's id in the host; a new one per launch of the process.
    @ObservationIgnored private(set) var hostID: String?
    @ObservationIgnored private var running = false
    /// Request ids continue from the clock, so replies to an earlier app run's requests
    /// (replayed after a relaunch) never match a new request.
    @ObservationIgnored private var nextID = Int(Date().timeIntervalSince1970 * 1000)
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    @ObservationIgnored private var threadHandlers: [String: (_ method: String, _ params: JSON, _ requestID: JSON?) -> Void] = [:]
    @ObservationIgnored private var startTask: Task<Void, Error>?
    /// Threads loaded into the current process. A fresh process must resume a thread before using it.
    @ObservationIgnored private(set) var loadedThreads: Set<String> = []
    /// Where the output handled so far ends in the host's log.
    @ObservationIgnored private(set) var offset = 0
    /// The end of the line being handled right now, so chats can skip lines they had already
    /// seen before a relaunch.
    @ObservationIgnored private(set) var currentLineEnd = 0
    /// Lines up to here were handled by an earlier run of the app.
    @ObservationIgnored private var replayedThrough = 0

    var isRunning: Bool { running }

    // MARK: - Lifecycle

    func ensureStarted() async throws {
        // At launch, wait to learn whether a Codex from before the relaunch is still running:
        // starting a second one would orphan any reply the first one is working on.
        if !resumeChecked {
            if resumeWaiters.isEmpty {
                Task { try? await Task.sleep(for: .seconds(10)); self.finishResumeCheck() }
            }
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        if running, startTask == nil { return }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.launch() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func launch() async throws {
        guard let binary = Self.locateBinary() else {
            throw CodexError(message: "Couldn't find the `codex` command. Install the Codex CLI, or set its path in Settings.")
        }
        let id = "codex-\(UUID().uuidString.prefix(8))"
        try HostClient.shared.spawn(id: id, executable: binary, arguments: ["app-server"], cwd: nil,
                                    environment: BinaryLocator.environment, kind: "codex")
        try follow(id, from: 0)
        loadedThreads = []
        replayedThrough = 0

        _ = try await rawRequest("initialize", [
            "clientInfo": ["name": "chatterbox", "title": "Chatterbox", "version": "0.1.0"],
            "capabilities": .null,
        ])
        write(["method": "initialized"])
        statusMessage = nil
        saveResumeState()
        Task { try? await self.refreshModels() }
        Task { UsageLimits.shared.updateCodex(try? await self.rawRequest("account/rateLimits/read", .null)["rateLimits"]) }
    }

    private func follow(_ id: String, from start: Int) throws {
        hostID = id
        offset = start
        running = true
        try HostClient.shared.attach(id: id, from: start, onLine: { [weak self] line, end in
            self?.consume(line, end: end)
        }, onExit: { [weak self] status, detail in
            self?.handleExit(status: status, detail: detail)
        })
    }

    private func handleExit(status: Int32, detail: String) {
        guard running else { return }
        let error = CodexError(message: "Codex stopped unexpectedly (exit \(status))\(detail.isEmpty ? "" : ": \(detail)")")
        if let hostID { HostClient.shared.forget(id: hostID) }
        running = false
        hostID = nil
        loadedThreads = []
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending = [:]
        for (_, handler) in threadHandlers { handler("chatterbox/processExited", ["message": .string(error.message)], nil) }
        statusMessage = error.message
        saveResumeState()
    }

    /// Stops the app-server, e.g. when replies shouldn't outlive the app.
    func terminate() {
        guard let hostID else { return }
        HostClient.shared.kill(id: hostID, forget: true)
        running = false
        self.hostID = nil
        loadedThreads = []
        saveResumeState()
    }

    // MARK: - Resuming after a relaunch

    private struct ResumeState: Codable {
        var processID: String?
        var offset: Int
        var loadedThreads: [String]
    }

    private static var resumeFile: URL { HostPaths.directory.appendingPathComponent("codex-resume.json") }

    /// Remembers which process is ours and how far its output was handled. Saved after the
    /// chats themselves, so every chat's saved state is at least this far along.
    func saveResumeState() {
        let state = ResumeState(processID: hostID, offset: offset, loadedThreads: loadedThreads.sorted())
        try? FileManager.default.createDirectory(at: HostPaths.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: Self.resumeFile, options: .atomic)
        if let hostID, HostClient.shared.isConnected { HostClient.shared.ack(id: hostID, offset: offset) }
    }

    /// The process an earlier run of the app left in the host, if it's still there.
    static var savedProcessID: String? {
        guard let data = try? Data(contentsOf: resumeFile) else { return nil }
        return (try? JSONDecoder().decode(ResumeState.self, from: data))?.processID
    }

    /// Reattaches to the app-server an earlier run left in the host and replays what it
    /// printed since. Chats register their thread handlers first, so nothing is dropped.
    /// Whether the launch-time check for a Codex still running from before has happened.
    private var resumeChecked = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Lets waiting starts go ahead. Called once the check is done, or after a while
    /// regardless, so nothing waits forever if the check never runs.
    private func finishResumeCheck() {
        guard !resumeChecked else { return }
        resumeChecked = true
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func resume(_ processes: [HostProcess]) {
        defer { finishResumeCheck() }
        guard !running, let data = try? Data(contentsOf: Self.resumeFile),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data),
              let id = state.processID, processes.contains(where: { $0.id == id }) else { return }
        loadedThreads = Set(state.loadedThreads)
        replayedThrough = state.offset
        do {
            try follow(id, from: state.offset)
            if processes.first(where: { $0.id == id })?.running == true {
                Task { try? await self.refreshModels() }
            }
        } catch {
            running = false
            hostID = nil
        }
    }

    static func locateBinary() -> String? {
        let fm = FileManager.default
        if let custom = AppPreferences.defaults.string(forKey: "codexPath")?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex", "\(home)/.cargo/bin/codex"]
        if let found = candidates.first(where: fm.isExecutableFile(atPath:)) { return found }

        // Fall back to asking the user's shell, which knows their PATH.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "command -v codex"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: output, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - Messaging

    func request(_ method: String, _ params: JSON, timeout: Duration? = nil) async throws -> JSON {
        try await ensureStarted()
        return try await rawRequest(method, params, timeout: timeout)
    }

    private func rawRequest(_ method: String, _ params: JSON, timeout: Duration? = nil) async throws -> JSON {
        let id = nextID
        nextID += 1
        let timer = timeout.map { timeout in
            Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.pending.removeValue(forKey: id)?.resume(throwing: CodexError(message: "Codex \(method) timed out."))
            }
        }
        defer { timer?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(["id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    func respond(to requestID: JSON, result: JSON) {
        write(["id": requestID, "result": result])
    }

    func respondError(to requestID: JSON, message: String) {
        write(["id": requestID, "error": ["code": -32601, "message": .string(message)]])
    }

    func register(thread: String, handler: @escaping (_ method: String, _ params: JSON, _ requestID: JSON?) -> Void) {
        threadHandlers[thread] = handler
    }

    func markLoaded(_ thread: String) {
        loadedThreads.insert(thread)
    }

    func refreshSkills(for folder: String) async {
        guard (try? await ensureStarted()) != nil,
              let result = try? await request("skills/list", ["cwds": [.string(folder)]]) else { return }
        let entries = result["data"]?.array ?? []
        let list = entries.flatMap { $0["skills"]?.array ?? [] }.compactMap { skill -> SlashCommand? in
            guard let name = skill["name"]?.string, skill["enabled"]?.bool != false else { return nil }
            return SlashCommand(name: name,
                                description: skill["interface"]?["shortDescription"]?.string ?? skill["description"]?.string ?? "",
                                codexSkillPath: skill["path"]?.string)
        }
        skills[folder] = list.sorted { $0.name < $1.name }
    }

    func refreshModels() async throws {
        var all: [CodexModelInfo] = []
        var cursor: String?
        repeat {
            var params: [String: JSON] = ["includeHidden": true]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request("model/list", .object(params))
            all += (result["data"]?.array ?? []).compactMap { m in
                guard let model = m["model"]?.string else { return nil }
                return CodexModelInfo(
                    model: model,
                    displayName: m["displayName"]?.string ?? model,
                    defaultEffort: m["defaultReasoningEffort"]?.string ?? "medium",
                    efforts: (m["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string },
                    hidden: m["hidden"]?.bool ?? false,
                    isDefault: m["isDefault"]?.bool ?? false
                )
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil
        models = all
    }

    private func write(_ message: JSON) {
        guard running, let hostID, let data = try? message.encoded() else { return }
        HostClient.shared.write(id: hostID, data)
    }

    private func consume(_ line: Data, end: Int) {
        currentLineEnd = end
        defer { offset = end }
        guard !line.isEmpty, let message = try? JSON.parse(line) else { return }
        dispatch(message)
    }

    private func dispatch(_ message: JSON) {
        let method = message["method"]?.string
        let id = message["id"]

        // Response to one of our requests.
        if method == nil, let id = id?.int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: CodexError(message: error["message"]?.string ?? "Codex returned an error."))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        guard let method else { return }
        let params = message["params"] ?? .null

        // Account-wide, so it belongs to no one thread.
        if method == "account/rateLimits/updated" {
            UsageLimits.shared.updateCodex(params["rateLimits"])
            return
        }
        // Notification or server request aimed at a thread.
        if let thread = params["threadId"]?.string, let handler = threadHandlers[thread] {
            handler(method, params, id)
            return
        }
        // Server requests we can't route must still be answered so Codex doesn't hang
        // (unless an earlier run of the app already saw it).
        if let id, currentLineEnd > replayedThrough {
            respondError(to: id, message: "Chatterbox doesn't support \(method) yet.")
        }
    }
}
