import Foundation

/// "!command" in the message box: runs a shell command in the chat's folder, streams its
/// output into the chat, and hands both to the agent with your next message, like Claude
/// Code's shell mode.
extension ChatSession {
    /// Where the chat works: its project or Studio, its Codex folder, or the working folder.
    var workingFolder: String {
        record.boundFolder ?? record.codex?.folder ?? AppPreferences.defaults.string(forKey: "codexFolder") ?? NSHomeDirectory()
    }

    /// What the chat shows of a command's output, in bytes; the rest is dropped as it arrives.
    nonisolated static let shellOutputLimit = 100_000
    /// How much of the end of the output the agent is handed.
    nonisolated static let shellTailLimit = 20_000
    nonisolated static let shellCutOffNote = "\n\u{2026} (output cut off)"

    func runShell(_ command: String) {
        if let remoteCommand {remoteCommand("shell",["command":.string(command)]);return}
        guard !command.isEmpty else { return }
        let itemID = appendItem(DisplayItem(kind: .shell, text: command, toolState: .running, detail: ""))
        let job = ShellJob(command: command)
        shellJobs[itemID] = job
        onChange?(self)
        let folder = workingFolder
        Task { [weak self] in
            let result = await Self.execute(command, in: folder, job: job) { text in
                Task { @MainActor in self?.updateItem(itemID) { $0.detail = text } }
            }
            await MainActor.run {
                guard let self else { return }
                self.shellJobs[itemID] = nil
                var text = result.display
                if result.stopped { text += text.isEmpty ? "(stopped)" : "\n(stopped)" }
                self.updateItem(itemID) {
                    $0.detail = text
                    $0.toolState = result.status == 0 ? .done : .failed
                    if result.status != 0 { $0.text = command }
                }
                let body = (result.truncated ? "\u{2026} (earlier output cut off)\n" : "") + result.tail
                let stopped = result.stopped ? " stopped=\"true\"" : ""
                let note = "<shell_command cwd=\"\(folder)\" exit_code=\"\(result.status)\"\(stopped)>\n$ \(command)\n\(body)\n</shell_command>"
                self.record.pendingShellContext = [self.record.pendingShellContext, note].compactMap { $0 }.joined(separator: "\n\n")
                self.onChange?(self)
            }
        }
    }

    var hasShellJobs: Bool { !shellJobs.isEmpty }

    /// The running "!" commands as background work, so the bar, timers and sidebar show them.
    var shellTasks: [BackgroundTask] {
        shellJobs.map { id, job in
            BackgroundTask(id: id.uuidString, kind: .shell, title: job.command, startedAt: job.startedAt, detached: true, rowID: id)
        }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Stops every "!" command this chat is running: SIGTERM to its process group, then SIGKILL.
    func stopShellJobs() {
        if let remoteCommand {remoteCommand("stopShell",[:]);return}
        for job in shellJobs.values { job.stop() }
    }

    /// Ends them now, for when the app quits (nothing could reattach to them afterwards).
    func killShellJobs() {
        for job in shellJobs.values { job.kill() }
    }

    /// A "!" command row still marked running when the chat was loaded lost its process when
    /// the app quit.
    func settleOrphanedShellRows() {
        for index in record.items.indices where record.items[index].kind == .shell && record.items[index].toolState == .running {
            record.items[index].toolState = .failed
            let detail = record.items[index].detail ?? ""
            record.items[index].detail = detail + (detail.isEmpty ? "" : "\n") + "(stopped when Chatterbox quit)"
        }
    }

    /// The pending "!" commands for the agent's next message, with a line on what they are.
    func takeShellContext() -> String? {
        guard let context = record.pendingShellContext else { return nil }
        record.pendingShellContext = nil
        return "The user ran these commands in the chat themselves; here's what they printed:\n\n" + context
    }

    /// Blocks the detached task's thread until the pipe reader finishes.
    private nonisolated static func wait(for group: DispatchGroup) { group.wait() }

    struct ShellResult {
        var display: String
        var tail: String
        var truncated: Bool
        var status: Int32
        var stopped: Bool
    }

    /// Runs through the user's login shell so their PATH and aliases apply, in its own process
    /// group so Stop reaches what it started. Output is kept only up to the limits, but the
    /// pipe is always drained so the command never blocks. `onDisplay` gets the text to show,
    /// at most about ten times a second and only while it still changes.
    static func execute(_ command: String, in folder: String, job: ShellJob, onDisplay: @escaping @Sendable (String) -> Void) async -> ShellResult {
        await Task.detached {
            func failure(_ text: String) -> ShellResult {
                ShellResult(display: text, tail: text, truncated: false, status: -1, stopped: job.isStopped)
            }
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return failure("Couldn't run the command: no pipe") }
            let (readFD, writeFD) = (fds[0], fds[1])
            var actions: posix_spawn_file_actions_t? = nil
            var attributes: posix_spawnattr_t? = nil
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_addchdir_np(&actions, folder)
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
            posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
            var defaults = sigset_t(), none = sigset_t()
            sigfillset(&defaults)
            sigemptyset(&none)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setsigmask(&attributes, &none)
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
            let words: [String] = ["/bin/zsh", "-lc", command]
            let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
            let environment: [UnsafeMutablePointer<CChar>?] = BinaryLocator.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
            var pid: pid_t = 0
            let code = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, arguments, environment)
            close(writeFD)
            guard code == 0 else {
                close(readFD)
                return failure("Couldn't run the command: \(String(cString: strerror(code)))")
            }
            job.attach(pid)

            let collected = OutputCollector(headLimit: shellOutputLimit, tailLimit: shellTailLimit)
            let exited = ExitFlag()
            let reader = DispatchGroup()
            reader.enter()
            DispatchQueue.global().async {
                defer { reader.leave() }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var lastEmit = Date.distantPast
                var dirty = false
                while true {
                    var poller = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&poller, 1, 100)
                    if ready > 0 {
                        let count = read(readFD, &buffer, buffer.count)
                        if count > 0 {
                            if collected.append(Data(buffer.prefix(count))) { dirty = true }
                        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                            break
                        }
                    } else if ready == 0, exited.value {
                        // The command is gone; whatever a leftover process still holds open is dropped.
                        break
                    }
                    if dirty, Date().timeIntervalSince(lastEmit) >= 0.1 {
                        onDisplay(collected.display)
                        lastEmit = Date()
                        dirty = false
                    }
                }
            }
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            exited.set()
            Self.wait(for: reader)
            close(readFD)
            let status: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            return ShellResult(display: collected.display, tail: collected.tail, truncated: collected.truncated, status: status, stopped: job.isStopped)
        }.value
    }
}

/// One running "!" command, held so Stop can end it and everything it started.
final class ShellJob: @unchecked Sendable {
    let command: String
    let startedAt = Date()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopRequested = false

    init(command: String) { self.command = command }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    /// Called once the process exists (it leads its own process group).
    func attach(_ pid: pid_t) {
        lock.lock(); self.pid = pid; let stop = stopRequested; lock.unlock()
        if stop { terminate(pid: pid, grace: 2) }
    }

    /// SIGTERM to the process group, then SIGKILL if anything is left after `grace` seconds.
    func stop(grace: TimeInterval = 2) {
        lock.lock(); stopRequested = true; let pid = pid; lock.unlock()
        if pid > 0 { terminate(pid: pid, grace: grace) }
    }

    /// SIGKILL to the process group right now.
    func kill() {
        lock.lock(); stopRequested = true; let pid = pid; lock.unlock()
        if pid > 0 { Darwin.kill(-pid, SIGKILL) }
    }

    private func terminate(pid: pid_t, grace: TimeInterval) {
        Darwin.kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { Darwin.kill(-pid, SIGKILL) }
    }
}

private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Keeps the start of a command's output (what the chat shows) and the end (what the agent
/// gets), however much it prints. Fed from the pipe's reader.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let headLimit: Int
    private let tailLimit: Int
    private var head = Data()
    private var tailBuffer = Data()
    private var total = 0

    init(headLimit: Int, tailLimit: Int) { self.headLimit = headLimit; self.tailLimit = tailLimit }

    /// Returns whether the text to show changed.
    func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasFull = total > headLimit
        total += data.count
        var changed = !wasFull && total > headLimit
        if head.count < headLimit {
            head.append(data.prefix(headLimit - head.count))
            changed = true
        }
        tailBuffer.append(data)
        if tailBuffer.count > tailLimit * 2 { tailBuffer = Data(tailBuffer.suffix(tailLimit)) }
        return changed
    }

    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return total > headLimit }

    /// The start of the output, with a note when the rest was dropped.
    var display: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: head, as: UTF8.self) + (total > headLimit ? ChatSession.shellCutOffNote : "")
    }

    /// The last bytes of the output.
    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: tailBuffer.suffix(tailLimit), as: UTF8.self)
    }
}
