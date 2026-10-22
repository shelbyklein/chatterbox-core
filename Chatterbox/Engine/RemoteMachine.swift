import Foundation

/// A computer chats can run on besides this Mac: Shelby-PC, a Windows PC reached over SSH.
/// A chat set to run there starts its Claude Code or Codex on the PC through
/// `chatterbox-worker.js` (deploy/pc-worker), in a scratch workspace of its own. Files it
/// writes are copied back to `~/Chatterbox/PC/<workspace>` so they show in the chat.
/// The PC also serves open-weight models through Ollama, which any chat can pick.
struct RemoteMachine: Hashable, Sendable {
    var id: String
    var name: String
    /// The `~/.ssh/config` alias.
    var sshHost: String
    var workerPath: String
    var workspaceRoot: String
    var attachmentsRoot: String

    /// Settings keys, so another PC or user can be set up without a rebuild.
    static var pc: RemoteMachine {
        let defaults = AppPreferences.defaults
        func value(_ key: String, _ fallback: String) -> String {
            let set = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
            return set.isEmpty ? fallback : set
        }
        return RemoteMachine(id: "pc", name: value("pcName", "Shelby-PC"), sshHost: value("pcSSHHost", "desktop"),
                             workerPath: value("pcWorkerPath", #"C:\Users\sklei\.chatterbox\chatterbox-worker.js"#),
                             workspaceRoot: value("pcWorkspaceRoot", #"D:\Chatterbox\workspaces"#),
                             attachmentsRoot: value("pcAttachmentsRoot", #"D:\Chatterbox\attachments"#))
    }

    static func named(_ id: String?) -> RemoteMachine? { id == "pc" ? .pc : nil }

    /// Where copies of this machine's files live on the Mac.
    var mirrorRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Chatterbox/PC", isDirectory: true)
    }

    /// The Mac copy of a file in one of this machine's workspaces, if it's in one.
    func mirror(of remotePath: String) -> URL? {
        let root = workspaceRoot.lowercased() + #"\"#
        guard remotePath.lowercased().hasPrefix(root) else { return nil }
        let relative = remotePath.dropFirst(root.count).split(separator: "\\").filter { $0 != ".." && $0 != "." }
        guard !relative.isEmpty else { return nil }
        return relative.reduce(mirrorRoot) { $0.appendingPathComponent(String($1)) }
    }

    func workspace(_ folder: String) -> String { workspaceRoot + #"\"# + folder }

    /// A workspace folder name for a chat: its title, made safe, and part of its id.
    static func workspaceFolder(title: String, id: UUID) -> String {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, c in if !(c == "-" && result.hasSuffix("-")) { result.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let short = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (short.isEmpty ? "chat" : short) + "-" + id.uuidString.prefix(8).lowercased()
    }
}

/// Starting and talking to programs on a `RemoteMachine` over SSH.
enum RemoteLaunch {
    /// Tests put a stand-in here that runs the worker locally.
    static var ssh: String { ProcessInfo.processInfo.environment["CHATTERBOX_SSH_BINARY"] ?? "/usr/bin/ssh" }

    /// Options for every connection: never prompt, give up quickly when the PC is off, and
    /// notice a dropped connection within a minute.
    static func sshOptions(connectTimeout: Int = 10) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
    }

    /// A port on the machine that leads back to one on this Mac (`ssh -R`), for as long as
    /// the connection it rides on: how a PC agent reaches EasyCLIProxy here.
    struct Forward: Equatable, Sendable {
        var remotePort: Int
        var host: String
        var port: Int
    }

    /// What runs on the Mac to start `executable` on the machine: SSH to the worker. A port
    /// another PC agent already holds is fine (same proxy behind it), so a failed forward
    /// doesn't stop the agent.
    static func command(on machine: RemoteMachine, forwards: [Forward] = []) -> [String] {
        sshOptions() + forwards.flatMap { ["-o", "ExitOnForwardFailure=no", "-R", "127.0.0.1:\($0.remotePort):\($0.host):\($0.port)"] }
            + [machine.sshHost, "node \"\(machine.workerPath)\""]
    }

    /// The worker's first line: what to run, where, and with which variables. Sent on stdin,
    /// so secrets never appear on a command line on either computer.
    static func header(executable: String, arguments: [String], cwd: String?, environment: [String: String]) -> Data {
        var header: [String: JSON] = ["v": 1, "exe": .string(executable), "args": .array(arguments.map(JSON.string)),
                                      "env": .object(environment.mapValues(JSON.string))]
        if let cwd { header["cwd"] = .string(cwd) }
        return (try? JSON.object(header).encoded()) ?? Data()
    }

    /// Starts `executable` on the machine as a process in the host. Only `environment` is
    /// passed: the Mac's own variables (PATH, HOME) mean nothing on the PC.
    @MainActor static func spawn(id: String, executable: String, arguments: [String], cwd: String?, environment: [String: String],
                      kind: String?, on machine: RemoteMachine, forwards: [Forward] = []) throws {
        try HostClient.shared.spawn(id: id, executable: ssh, arguments: command(on: machine, forwards: forwards), cwd: nil,
                                    environment: BinaryLocator.environment, kind: kind)
        HostClient.shared.write(id: id, header(executable: executable, arguments: arguments, cwd: cwd, environment: environment))
    }

    /// Runs a PowerShell script on the machine and returns what it printed.
    static func run(_ script: String, on machine: RemoteMachine, connectTimeout: Int = 6, input: Data? = nil) async throws -> Data {
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        return try await process(ssh, sshOptions(connectTimeout: connectTimeout) + [machine.sshHost, "powershell -NoProfile -NonInteractive -EncodedCommand \(encoded)"], input: input)
    }

    /// Copies a file from the machine to the Mac.
    static func fetch(_ remotePath: String, to local: URL, from machine: RemoteMachine) async throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await process("/usr/bin/scp", ["-q", "-B", "-o", "ConnectTimeout=10", "\(machine.sshHost):\(scpPath(remotePath))", local.path])
    }

    /// Copies a file from the Mac to the machine.
    static func upload(_ local: URL, to remotePath: String, on machine: RemoteMachine) async throws {
        _ = try await process("/usr/bin/scp", ["-q", "-B", "-o", "ConnectTimeout=10", local.path, "\(machine.sshHost):\(scpPath(remotePath))"])
    }

    /// Windows OpenSSH takes forward slashes, and a drive path needs a leading one.
    static func scpPath(_ path: String) -> String {
        let forward = path.replacingOccurrences(of: "\\", with: "/")
        return forward.dropFirst().first == ":" ? "/" + forward : forward
    }

    /// Runs a program to the end off the main thread; a non-zero exit throws with its stderr.
    static func process(_ executable: String, _ arguments: [String], input: Data? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = BinaryLocator.environment
                let out = Pipe(), err = Pipe(), stdin = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = stdin
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()
                var output = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let errors = err.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 { continuation.resume(returning: output) } else {
                    let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: RemoteError(status: process.terminationStatus, detail: detail))
                }
            }
        }
    }

    struct RemoteError: LocalizedError {
        var status: Int32
        var detail: String
        /// 255 is SSH's own failure: the PC is off, asleep or off the network.
        var errorDescription: String? {
            status == 255 ? "\(RemoteMachine.pc.name) isn't reachable. Is it on and connected?" + (detail.isEmpty ? "" : " (\(detail.split(separator: "\n").last ?? ""))")
                : detail.isEmpty ? "The command on \(RemoteMachine.pc.name) failed (exit \(status))." : detail
        }
    }
}

/// Open-weight models served by Ollama on the PC, and the tunnel Mac chats reach them by.
@MainActor
@Observable
final class PCModels {
    static let shared = PCModels()
    /// Ollama's own port on the PC, which listens there only.
    nonisolated static let ollamaPort = 11434
    /// The Mac end of the SSH tunnel to it. Tests set their own, away from the live tunnel.
    nonisolated static let tunnelPort = Int(ProcessInfo.processInfo.environment["CHATTERBOX_PC_TUNNEL_PORT"] ?? "") ?? 47340
    /// Fits the PC's GPU entirely, and the fastest that handles agent tools (see plans/pc-worker.md).
    nonisolated static let recommended = "qwen3.5:9b"

    private(set) var models: [String] = []
    /// nil until the first check.
    private(set) var reachable: Bool?
    private var checkedAt: Date?

    func refresh(force: Bool = false) async {
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 60 { return }
        checkedAt = Date()
        do {
            let out = try await RemoteLaunch.run("(Invoke-RestMethod http://127.0.0.1:\(Self.ollamaPort)/api/tags).models | % { $_.name }", on: .pc)
            models = String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted()
            reachable = true
        } catch {
            models = []
            reachable = false
        }
    }

    // MARK: - Tunnel (Mac chats using a PC model)

    private var tunnel: Process?

    /// Makes sure `127.0.0.1:tunnelPort` reaches Ollama on the PC, starting the tunnel if needed.
    nonisolated static func ensureTunnel() async throws {
        if await portOpen() { return }
        await MainActor.run { shared.startTunnel() }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if await portOpen() { return }
        }
        throw RemoteLaunch.RemoteError(status: 255, detail: "the tunnel to Ollama didn't open")
    }

    func startTunnel() {
        if let tunnel, tunnel.isRunning { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteLaunch.ssh)
        process.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                             "-L", "127.0.0.1:\(Self.tunnelPort):127.0.0.1:\(Self.ollamaPort)", RemoteMachine.pc.sshHost]
        process.environment = BinaryLocator.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        tunnel = process
    }

    nonisolated private static func portOpen() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(tunnelPort)/api/version")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
