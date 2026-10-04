import Foundation

/// Work an agent started that runs apart from its reply: a subagent (a helper agent), or a
/// shell command left running in the background. Shown above the message box, and in the
/// sidebar, so a chat never looks idle while something is still going.
struct BackgroundTask: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable { case agent, shell }

    /// The agent's own id for it: a task id, a Codex thread, or a command's item id.
    var id: String
    var kind: Kind
    var title: String
    /// What it's doing now, when the agent says.
    var detail: String?
    var startedAt = Date()
    /// Keeps going after the reply ends. A subagent the reply waits on doesn't.
    var detached: Bool
    /// The command's process, so Chatterbox can tell when it's gone.
    var processID: Int32?
    /// The transcript row that started it, settled when it finishes.
    var rowID: UUID?
}

extension ChatSession {
    /// What the agent started (saved with the chat), then the "!" commands running now.
    var backgroundTasks: [BackgroundTask] { (record.backgroundTasks ?? []) + shellTasks }
    var hasBackgroundWork: Bool { !backgroundTasks.isEmpty }

    /// Adds a task, or refreshes one already shown (keeping when it started).
    func addBackgroundTask(_ task: BackgroundTask) {
        var tasks = record.backgroundTasks ?? []
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].title = task.title
            tasks[index].kind = task.kind
        } else {
            tasks.append(task)
            if let pid = task.processID { watchBackgroundProcess(pid, task: task.id) }
        }
        record.backgroundTasks = tasks
        onChange?(self)
    }

    func updateBackgroundTask(_ id: String, _ change: (inout BackgroundTask) -> Void) {
        guard var tasks = record.backgroundTasks, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        record.backgroundTasks = tasks
    }

    /// Removes a finished task and settles the row that started it.
    @discardableResult
    func finishBackgroundTask(_ id: String, failed: Bool = false) -> BackgroundTask? {
        guard var tasks = record.backgroundTasks, let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let task = tasks.remove(at: index)
        record.backgroundTasks = tasks.isEmpty ? nil : tasks
        if let row = task.rowID {
            updateItem(row) { if $0.toolState == .running { $0.toolState = failed ? .failed : .done } }
        }
        onChange?(self)
        return task
    }

    /// Everything stops with the agent's process.
    func clearBackgroundTasks(where shouldRemove: (BackgroundTask) -> Bool = { _ in true }) {
        for task in record.backgroundTasks ?? [] where shouldRemove(task) { finishBackgroundTask(task.id, failed: true) }
    }

    /// Checks now and then that a background command's process is still alive, in case its
    /// agent never says it ended (or ended while Chatterbox was closed).
    private func watchBackgroundProcess(_ pid: Int32, task id: String) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self, (self.record.backgroundTasks ?? []).contains(where: { $0.id == id }) else { return }
                if kill(pid, 0) != 0, errno == ESRCH {
                    self.finishBackgroundTask(id)
                    return
                }
            }
        }
    }

    /// Picks the watch back up for commands still listed after a relaunch.
    func resumeBackgroundWatches() {
        for task in record.backgroundTasks ?? [] {
            if let pid = task.processID { watchBackgroundProcess(pid, task: task.id) }
        }
    }
}
