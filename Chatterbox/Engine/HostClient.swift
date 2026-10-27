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

    /// The host new processes start in (on `HostPaths.socket`), and older ones still running
    /// processes they started before a newer host build was installed. Each older one is
    /// "draining": it keeps its processes going and exits once they're done.
    private var fd: Int32 = -1
    private var draining: [Int32] = []
    /// Bumped per connection, so frames read from a closed socket are dropped.
    private var generation = 0
    private var generations: [Int32: Int] = [:]
    /// Which connection each known process is on (absent: the current host).
    private var owners: [String: Int32] = [:]
    private var subscribers: [String: Subscriber] = [:]
    private var listWaiters: [Int: (fd: Int32, done: CheckedContinuation<[HostProcess], Error>)] = [:]
    private var nextRequest = 1

    var isConnected: Bool { fd >= 0 }

    /// The process runs in a host from an older build, so the next start should be here.
    func isOnDrainingHost(_ id: String?) -> Bool { id.flatMap { owners[$0] }.map(draining.contains) ?? false }

    // MARK: - Connection

    /// Connects, launching the host first if needed. With `launch` false, only an already
    /// running host is used.
    func connect(launch: Bool = true) throws {
        if fd >= 0 { return }
        connectDraining()
        if let socket = UnixSocket.connect(to: HostPaths.socket) {
            if hostIsCurrent(socket) { return adopt(socket) }
            // A host from an older build: it keeps what it's running, under another name,
            // and a current host takes the usual one for everything new.
            moveAside(socket)
        }
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

    // MARK: - Handing off to a newer host

    /// Asks the host whether it's the build this app would start. A host from before this
    /// check answers "Unknown request", which is a no too.
    private func hostIsCurrent(_ socket: Int32) -> Bool {
        guard let binary = Self.hostBinary?.path,
              var data = try? JSON.object(["op": "hello", "binary": .string(binary)]).encoded() else { return true }
        data.append(0x0A)
        guard data.withUnsafeBytes({ Darwin.write(socket, $0.baseAddress!, $0.count) }) == data.count else { return true }
        var reader = HostFrameReader()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let n = read(socket, &buffer, buffer.count)
            guard n > 0 else { return true }
            for frame in reader.feed(Data(buffer[0..<n])) {
                switch frame.header["op"]?.string {
                case "hello": return frame.header["current"]?.bool ?? true
                case "error": return false
                default: continue
                }
            }
        }
        return true
    }

    /// Renames the older host's socket so a new host can listen on the usual one, tells it
    /// to finish (exit once its processes end), and keeps talking to it for those.
    private func moveAside(_ socket: Int32) {
        let aside = HostPaths.directory.appendingPathComponent("host-draining-\(UUID().uuidString.prefix(8)).sock")
        if rename(HostPaths.socket.path, aside.path) != 0 {
            close(socket)   // Another client got there first; the usual socket is the new host's.
            return
        }
        if var data = try? JSON.object(["op": "drain"]).encoded() {
            data.append(0x0A)
            _ = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress!, $0.count) }
        }
        adoptDraining(socket)
    }

    /// Hosts already handing off (moved aside by this or another client, or before a relaunch).
    private func connectDraining() {
        guard draining.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: HostPaths.directory.path) else { return }
        for name in names where name.hasPrefix("host-draining-") && name.hasSuffix(".sock") {
            let url = HostPaths.directory.appendingPathComponent(name)
            if let socket = UnixSocket.connect(to: url) { adoptDraining(socket) } else { unlink(url.path) }
        }
    }

    private func adoptDraining(_ socket: Int32) {
        draining.append(socket)
        startReading(socket)
        // Learn which processes are there, so their requests go to it.
        let req = nextRequest
        nextRequest += 1
        sendRaw(["op": "list", "req": .number(Double(req))], to: socket)
    }

    /// A draining host with nothing running is let go, so it can exit.
    private func releaseIdleDraining(_ socket: Int32, processes: [HostProcess]) {
        guard draining.contains(socket), !processes.contains(where: \.running),
              !owners.contains(where: { $0.value == socket && subscribers[$0.key] != nil }) else { return }
        // shutdown, not just close: the reader thread is blocked on this socket, and a close
        // alone leaves the connection open until that read returns.
        shutdown(socket, SHUT_RDWR)
        close(socket)
        drop(socket)
    }

    /// The host ships inside the app as its own small app (Contents/Helpers), so macOS's
    /// Privacy settings can list it; older bundles keep it in Contents/MacOS.
    /// Tests point at theirs with `CHATTERBOX_HOST_BINARY`.
    static var hostBinary: URL? {
        // A service set up before the host moved may still name the old place; skip it then.
        if let path = ProcessInfo.processInfo.environment["CHATTERBOX_HOST_BINARY"], !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ChatterboxHost.app/Contents/MacOS/ChatterboxHost")
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
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
        try Self.spawnOwnResponsibility(binary, output: log.fileDescriptor)
        try? log.close()
    }

    /// Starts the host as the process macOS holds responsible for itself. Otherwise privacy
    /// checks (Accessibility, Screen Recording) for the agents' tools fall on whoever launched
    /// it, chatterboxd or the app, and approving "Chatterbox Host" in Settings wouldn't count.
    private static func spawnOwnResponsibility(_ binary: URL, output: Int32) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, true)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        var pid: pid_t = 0
        let path = binary.path
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, path, &actions, &attributes, &argv, environ)
        guard status == 0 else { throw ClaudeCodeError(message: "Couldn't start Chatterbox's background host (\(String(cString: strerror(status)))).") }
        // Reap it if it exits while this process lives; the host normally outlives us.
        DispatchQueue.global(qos: .utility).async { var code: Int32 = 0; waitpid(pid, &code, 0) }
    }

    private func adopt(_ socket: Int32) {
        fd = socket
        startReading(socket)
    }

    private func startReading(_ socket: Int32) {
        generation += 1
        let generation = generation
        generations[socket] = generation
        let thread = Thread { [weak self] in
            var reader = HostFrameReader()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(socket, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                let frames = reader.feed(Data(buffer[0..<n]))
                guard !frames.isEmpty else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(frames, from: socket, generation: generation) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionLost(socket, generation: generation) } }
        }
        thread.name = "Chatterbox host reader"
        thread.start()
    }

    private func connectionLost(_ socket: Int32, generation: Int) {
        guard generations[socket] == generation else { return }
        close(socket)
        let lost = socket == fd ? subscribers.filter { owners[$0.key] == nil } : subscribers.filter { owners[$0.key] == socket }
        drop(socket)
        for (id, subscriber) in lost {
            subscribers.removeValue(forKey: id)
            subscriber.onExit(-1, "Chatterbox's background host stopped.")
        }
        for (req, waiter) in listWaiters where waiter.fd == socket {
            listWaiters.removeValue(forKey: req)
            waiter.done.resume(throwing: ClaudeCodeError(message: "Chatterbox's background host stopped."))
        }
    }

    /// Forgets a closed connection and what was on it.
    private func drop(_ socket: Int32) {
        generations.removeValue(forKey: socket)
        if socket == fd { fd = -1 }
        draining.removeAll { $0 == socket }
        owners = owners.filter { $0.value != socket }
    }

    /// Drops the connections without stopping anything in the hosts, as quitting does.
    func disconnect() {
        for socket in draining + (fd >= 0 ? [fd] : []) {
            shutdown(socket, SHUT_RDWR)
            close(socket)
            drop(socket)
        }
        subscribers = [:]
    }

    private func handle(_ frames: [HostFrameReader.Frame], from socket: Int32, generation: Int) {
        guard generations[socket] == generation else { return }
        for frame in frames {
            let header = frame.header
            let id = header["id"]?.string ?? ""
            switch header["op"]?.string {
            case "line":
                guard let raw = frame.raw, let end = header["end"]?.int else { continue }
                subscribers[id]?.onLine(raw, end)
            case "exit":
                // A draining host may be done now: ask what it still has.
                if draining.contains(socket) { sendRaw(["op": "list"], to: socket) }
                guard let subscriber = subscribers.removeValue(forKey: id) else { continue }
                subscriber.onExit(Int32(header["status"]?.int ?? -1), header["stderr"]?.string ?? "")
            case "list":
                let processes = (header["processes"]?.array ?? []).compactMap { p -> HostProcess? in
                    guard let id = p["id"]?.string else { return nil }
                    return HostProcess(id: id, running: p["running"]?.bool ?? false, end: p["end"]?.int ?? 0,
                                       busy: p["busy"]?.bool ?? false, status: p["status"]?.int.map(Int32.init))
                }
                if draining.contains(socket) {
                    for process in processes { owners[process.id] = socket }
                }
                if let req = header["req"]?.int, let waiter = listWaiters.removeValue(forKey: req) {
                    waiter.done.resume(returning: processes)
                }
                releaseIdleDraining(socket, processes: processes)
            case "spawned":
                if let error = header["error"]?.string { NSLog("Chatterbox host: \(error)") }
            case "error":
                NSLog("Chatterbox host: \(header["message"]?.string ?? "error")")
            default:
                break
            }
        }
    }

    /// A request about process `id` goes to the host it's in.
    private func send(_ request: JSON) {
        let target = request["id"]?.string.flatMap { owners[$0] } ?? fd
        sendRaw(request, to: target)
    }

    private func sendRaw(_ request: JSON, to fd: Int32) {
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
        if !ok, let generation = generations[fd] { connectionLost(fd, generation: generation) }
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
        owners.removeValue(forKey: id)
        sendRaw(.object(request), to: fd)
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
    /// Every host's: the current one's and any still draining.
    func list(launch: Bool = false) async throws -> [HostProcess] {
        do { try connect(launch: launch) } catch {
            if launch { throw error }
            if draining.isEmpty { connectDraining() }
        }
        var all: [HostProcess] = []
        for socket in draining + (fd >= 0 ? [fd] : []) {
            let req = nextRequest
            nextRequest += 1
            if let processes = try? await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<[HostProcess], Error>) in
                listWaiters[req] = (socket, continuation)
                sendRaw(["op": "list", "req": .number(Double(req))], to: socket)
            }) { all += processes }
        }
        return all
    }
}
