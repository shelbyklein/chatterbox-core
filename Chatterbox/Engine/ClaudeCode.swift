import Foundation

struct ClaudeCodeError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Finds command-line tools the way a terminal would, since apps launched from Finder
/// get a minimal PATH.
enum BinaryLocator {
    static func find(_ name: String, customPathKey: String) -> String? {
        let fm = FileManager.default
        if let custom = AppPreferences.defaults.string(forKey: customPathKey)?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                          "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)", "\(home)/.cargo/bin/\(name)",
                          "\(home)/.claude/local/\(name)"]
        if let found = candidates.first(where: fm.isExecutableFile(atPath:)) { return found }

        // Fall back to asking the user's shell, which knows their PATH.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "command -v \(name)"]
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

    /// The app's environment with the usual tool folders added to PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPath + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }
}

/// One `claude` (Claude Code) process in stream-json mode, owned by one chat. It runs in
/// ChatterboxHost rather than as the app's child, so a reply outlives the app; `offset` is how
/// far its output has been read, which a relaunch continues from with `attach`.
/// It uses the user's own Claude Code install, settings, and subscription sign-in.
@MainActor
final class ClaudeCodeProcess {
    struct Config {
        var cwd: String
        var model: String
        var effort: String
        var permissionMode: String
        var appendSystemPrompt: String
        var resumeSessionID: String?
        var extraDirectories: [String] = []
        /// Resume into a new session instead of continuing the old one (a forked chat).
        var forkSession = false
        /// Extra tool servers, as `--mcp-config` JSON (Dot's chatterbox tools).
        var mcpConfig: String?
        /// Tools that run without asking.
        var allowedTools: [String] = []
        /// Added to the environment (EasyCLIProxyAPI's address and key).
        var environment: [String: String] = [:]
        var fastMode = false
    }

    /// Every message the CLI writes, except replies to our own control requests.
    var onMessage: ((JSON) -> Void)?
    /// Called once if the process ends; the text is the last thing it printed to stderr.
    var onExit: ((_ status: Int32, _ detail: String) -> Void)?

    /// The process's id in the host.
    private(set) var hostID: String?
    /// Where the output handled so far ends in the host's log.
    private(set) var offset = 0
    private var running = false
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]

    var isRunning: Bool { running }

    static func locateBinary() -> String? { BinaryLocator.find("claude", customPathKey: "claudePath") }

    static func arguments(_ config: Config) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    // Echoes each message as it joins the conversation, which ends its "Queued" state.
                    "--replay-user-messages",
                    "--model", config.model, "--permission-mode", config.permissionMode,
                    // Only makes "Bypass permissions" selectable later; the mode above still applies.
                    "--allow-dangerously-skip-permissions",
                    "--append-system-prompt", config.appendSystemPrompt]
        args += ["--settings", config.fastMode ? "{\"fastMode\":true}" : "{\"fastMode\":false}"]
        if !config.effort.isEmpty { args += ["--effort", config.effort] }
        if let id = config.resumeSessionID {
            args += ["--resume", id]
            if config.forkSession { args.append("--fork-session") }
        }
        for dir in config.extraDirectories { args += ["--add-dir", dir] }
        if let mcp = config.mcpConfig { args += ["--mcp-config", mcp] }
        if !config.allowedTools.isEmpty { args += ["--allowedTools", config.allowedTools.joined(separator: ",")] }
        return args
    }

    /// Starts a new process in the host under `id`.
    func start(_ config: Config, id: String) throws {
        guard let binary = Self.locateBinary() else {
            throw ClaudeCodeError(message: "Couldn't find the `claude` command. Install Claude Code, or set its path in Settings.")
        }
        try HostClient.shared.spawn(id: id, executable: binary, arguments: Self.arguments(config), cwd: config.cwd,
                                    environment: BinaryLocator.environment.merging(config.environment) { $1 }, kind: "claude")
        try attach(id: id, from: 0)
    }

    /// Follows a process already in the host, replaying its output from `offset` first.
    func attach(id: String, from offset: Int) throws {
        hostID = id
        self.offset = offset
        running = true
        try HostClient.shared.attach(id: id, from: offset, onLine: { [weak self] line, end in
            self?.consume(line, end: end)
        }, onExit: { [weak self] status, detail in
            self?.handleExit(status: status, detail: detail)
        })
    }

    func send(_ message: JSON) {
        guard running, let hostID, let data = try? message.encoded() else { return }
        HostClient.shared.write(id: hostID, data)
    }

    func sendUser(_ content: [JSON]) {
        send(["type": "user", "message": ["role": "user", "content": .array(content)], "parent_tool_use_id": .null, "session_id": ""])
    }

    /// Sends a control request (interrupt, set_model, …) and waits for its reply.
    @discardableResult
    func control(_ subtype: String, _ fields: [String: JSON] = [:]) async throws -> JSON {
        guard isRunning else { throw ClaudeCodeError(message: "Claude Code isn't running.") }
        let id = UUID().uuidString
        var request = fields
        request["subtype"] = .string(subtype)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["type": "control_request", "request_id": .string(id), "request": .object(request)])
        }
    }

    /// Sends a control request right away without waiting for the reply, so it stays in order
    /// with messages sent after it (a model change must land before the next message).
    func controlNow(_ subtype: String, _ fields: [String: JSON] = [:]) {
        guard isRunning else { return }
        var request = fields
        request["subtype"] = .string(subtype)
        send(["type": "control_request", "request_id": .string(UUID().uuidString), "request": .object(request)])
    }

    /// Answers a control request that came from the CLI, such as a permission prompt.
    func respond(to requestID: String, _ response: JSON) {
        send(["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID), "response": response]])
    }

    /// Stops the process and removes its log.
    func terminate() {
        onExit = nil
        if let hostID { HostClient.shared.kill(id: hostID, forget: true) }
        failPending()
        running = false
        hostID = nil
    }

    private func consume(_ line: Data, end: Int) {
        defer { offset = end }
        guard !line.isEmpty, let message = try? JSON.parse(line) else { return }
        if message["type"]?.string == "control_response" {
            guard let id = message["response"]?["request_id"]?.string, let continuation = pending.removeValue(forKey: id) else { return }
            if message["response"]?["subtype"]?.string == "error" {
                continuation.resume(throwing: ClaudeCodeError(message: message["response"]?["error"]?.string ?? "Claude Code refused the request."))
            } else {
                continuation.resume(returning: message["response"]?["response"] ?? .null)
            }
            return
        }
        onMessage?(message)
    }

    private func handleExit(status: Int32, detail: String) {
        guard running else { return }
        running = false
        failPending()
        // Everything it printed has been handled; the log isn't needed anymore.
        if let hostID { HostClient.shared.forget(id: hostID) }
        onExit?(status, detail)
    }

    private func failPending() {
        let error = ClaudeCodeError(message: "Claude Code stopped.")
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending = [:]
    }
}

/// What a short-lived `claude` process reports at startup: the models this account can use
/// and who is signed in. Starting up doesn't call the model, so it costs nothing.
struct ClaudeCodeInfo {
    var models: [ClaudeCodeModel]
    var commands: [SlashCommand]
    var accountEmail: String?
    var plan: String?

    @MainActor
    static func probe() async throws -> ClaudeCodeInfo {
        let process = ClaudeCodeProcess()
        let config = ClaudeCodeProcess.Config(cwd: NSHomeDirectory(), model: "default", effort: "", permissionMode: "default", appendSystemPrompt: "")
        try process.start(config, id: "probe-\(UUID().uuidString)")
        defer { process.terminate() }
        let response = try await withThrowingTaskGroup(of: JSON.self) { group in
            group.addTask { @MainActor in try await process.control("initialize") }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw ClaudeCodeError(message: "Claude Code didn't respond.")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let models = (response["models"]?.array ?? []).compactMap { m -> ClaudeCodeModel? in
            guard let value = m["value"]?.string else { return nil }
            return ClaudeCodeModel(
                value: value,
                resolvedModel: m["resolvedModel"]?.string ?? value,
                displayName: m["displayName"]?.string ?? value,
                detail: m["description"]?.string ?? "",
                efforts: m["supportsEffort"]?.bool == true ? (m["supportedEffortLevels"]?.array ?? []).compactMap(\.string) : []
            )
        }
        return ClaudeCodeInfo(models: models,
                              commands: (response["commands"]?.array ?? []).compactMap(SlashCommand.init(claude:)),
                              accountEmail: response["account"]?["email"]?.string,
                              plan: response["account"]?["subscriptionType"]?.string)
    }
}
