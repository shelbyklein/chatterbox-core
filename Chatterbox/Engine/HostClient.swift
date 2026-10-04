import Foundation

/// A process running in ChatterboxHost, as `list` reports it.
struct HostProcess: Equatable {
    var id: String
    var running: Bool
    /// Where its output log ends now.
    var end: Int
    /// Claude has an unanswered message, or Codex has a turn in progress.
    var busy: Bool
    var status: Int32?
}

/// The app's connection to ChatterboxHost, which runs the agent processes so they outlive
/// the app (see ChatterboxHost/Host.swift). The first use launches the host if it isn't
/// running. Requests are written in order on one socket, so a `write` sent right after a
/// `spawn` reaches the new process.
@MainActor
final class HostClient {
    static let shared = HostClient()

    private struct Subscriber {
        var onLine: (_ line: Data, _ end: Int) -> Void
        var onExit: (_ status: Int32, _ detail: String) -> Void
    }

    private var fd: Int32 = -1
    /// Bumped per connection, so frames read from a closed socket are dropped.
    private var generation = 0
    private var subscribers: [String: Subscriber] = [:]
    private var listWaiters: [Int: CheckedContinuation<[HostProcess], Error>] = [:]
    private var nextRequest = 1

    var isConnected: Bool { fd >= 0 }

    // MARK: - Connection

    /// Connects, launching the host first if needed. With `launch` false, only an already
    /// running host is used.
    func connect(launch: Bool = true) throws {
        if fd >= 0 { return }
        if let socket = UnixSocket.connect(to: HostPaths.socket) { return adopt(socket) }
        guard launch else { throw ClaudeCodeError(message: "Chatterbox's background host isn't running.") }
        try launchHost()
        // The host is listening within a few milliseconds; allow for a slow first launch.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let socket = UnixSocket.connect(to: HostPaths.socket) { return adopt(socket) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ClaudeCodeError(message: "Couldn't start Chatterbox's background host.")
    }

    /// The host binary ships inside the app (Contents/MacOS). Tests point at theirs with
    /// `CHATTERBOX_HOST_BINARY`.
    static var hostBinary: URL? {
        if let path = ProcessInfo.processInfo.environment["CHATTERBOX_HOST_BINARY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.url(forAuxiliaryExecutable: "ChatterboxHost")
    }

    private func launchHost() throws {
        guard let binary = Self.hostBinary else { throw ClaudeCodeError(message: "Chatterbox's background host is missing from the app.") }
        let fm = FileManager.default
        try fm.createDirectory(at: HostPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = HostPaths.directory.appendingPathComponent("host.log")
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        _ = try? log.seekToEnd()
        // The host calls setsid() itself, so it doesn't share the app's fate when the app quits.
        let process = Process()
        process.executableURL = binary
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }

    private func adopt(_ socket: Int32) {
        fd = socket
        generation += 1
        let generation = generation
        let thread = Thread { [weak self] in
            var reader = HostFrameReader()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(socket, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                let frames = reader.feed(Data(buffer[0..<n]))
                guard !frames.isEmpty else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(frames, generation: generation) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionLost(generation: generation) } }
        }
        thread.name = "Chatterbox host reader"
        thread.start()
    }

    private func connectionLost(generation: Int) {
        guard generation == self.generation, fd >= 0 else { return }
        close(fd)
        fd = -1
        let lost = subscribers
        subscribers = [:]
        for (_, subscriber) in lost { subscriber.onExit(-1, "Chatterbox's background host stopped.") }
        let waiters = listWaiters
        listWaiters = [:]
        for (_, waiter) in waiters { waiter.resume(throwing: ClaudeCodeError(message: "Chatterbox's background host stopped.")) }
    }

    /// Drops the connection without stopping anything in the host, as quitting does.
    func disconnect() {
        guard fd >= 0 else { return }
        generation += 1
        close(fd)
        fd = -1
        subscribers = [:]
    }

    private func handle(_ frames: [HostFrameReader.Frame], generation: Int) {
        guard generation == self.generation else { return }
        for frame in frames {
            let header = frame.header
            let id = header["id"]?.string ?? ""
            switch header["op"]?.string {
            case "line":
                guard let raw = frame.raw, let end = header["end"]?.int else { continue }
                subscribers[id]?.onLine(raw, end)
            case "exit":
                guard let subscriber = subscribers.removeValue(forKey: id) else { continue }
                subscriber.onExit(Int32(header["status"]?.int ?? -1), header["stderr"]?.string ?? "")
            case "list":
                guard let req = header["req"]?.int, let waiter = listWaiters.removeValue(forKey: req) else { continue }
                let processes = (header["processes"]?.array ?? []).compactMap { p -> HostProcess? in
                    guard let id = p["id"]?.string else { return nil }
                    return HostProcess(id: id, running: p["running"]?.bool ?? false, end: p["end"]?.int ?? 0,
                                       busy: p["busy"]?.bool ?? false, status: p["status"]?.int.map(Int32.init))
                }
                waiter.resume(returning: processes)
            case "spawned":
                if let error = header["error"]?.string { NSLog("Chatterbox host: \(error)") }
            case "error":
                NSLog("Chatterbox host: \(header["message"]?.string ?? "error")")
            default:
                break
            }
        }
    }

    private func send(_ request: JSON) {
        guard fd >= 0, var data = try? request.encoded() else { return }
        data.append(0x0A)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        if !ok { connectionLost(generation: generation) }
    }

    // MARK: - Requests

    /// Starts a process in the host. If one with this id is already running, it's kept.
    func spawn(id: String, executable: String, arguments: [String], cwd: String?, environment: [String: String], kind: String?) throws {
        try connect()
        var request: [String: JSON] = [
            "op": "spawn", "id": .string(id), "executable": .string(executable),
            "args": .array(arguments.map(JSON.string)), "env": .object(environment.mapValues(JSON.string)),
        ]
        if let cwd { request["cwd"] = .string(cwd) }
        if let kind { request["protocol"] = .string(kind) }
        send(.object(request))
    }

    /// Streams the process's output from `offset` (every saved line first, then live ones),
    /// then its exit. One subscriber per process.
    func attach(id: String, from offset: Int, onLine: @escaping (_ line: Data, _ end: Int) -> Void,
                onExit: @escaping (_ status: Int32, _ detail: String) -> Void) throws {
        try connect()
        subscribers[id] = Subscriber(onLine: onLine, onExit: onExit)
        send(["op": "attach", "id": .string(id), "from": .number(Double(offset))])
    }

    func detach(id: String) {
        subscribers.removeValue(forKey: id)
        send(["op": "detach", "id": .string(id)])
    }

    /// Writes one line to the process's stdin.
    func write(id: String, _ line: Data) {
        send(["op": "write", "id": .string(id), "data": .string(String(decoding: line, as: UTF8.self))])
    }

    /// Stops the process. `forget` also removes its log once it has ended.
    func kill(id: String, forget: Bool = true) {
        subscribers.removeValue(forKey: id)
        send(["op": "kill", "id": .string(id), "forget": .bool(forget)])
    }

    /// Removes an ended process's log.
    func forget(id: String) {
        send(["op": "forget", "id": .string(id)])
    }

    /// Everything up to `offset` is saved, so the host may trim it from a long log.
    func ack(id: String, offset: Int) {
        send(["op": "ack", "id": .string(id), "offset": .number(Double(offset))])
    }

    /// The host's processes. With `launch` false and no host running, there are none.
    func list(launch: Bool = false) async throws -> [HostProcess] {
        do { try connect(launch: launch) } catch {
            if launch { throw error }
            return []
        }
        let req = nextRequest
        nextRequest += 1
        return try await withCheckedThrowingContinuation { continuation in
            listWaiters[req] = continuation
            send(["op": "list", "req": .number(Double(req))])
        }
    }
}
