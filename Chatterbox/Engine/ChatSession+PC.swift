import Foundation

/// Running a chat on Shelby-PC, and open-weight models from the PC's Ollama (see
/// RemoteMachine). A PC chat's agent works in its own scratch workspace there; files it
/// writes are copied back to `~/Chatterbox/PC/<workspace>` for previews.
extension ChatSession {
    /// The machine this chat's agent runs on; nil is this Mac. Golem always stays here.
    var runMachine: RemoteMachine? { isDot ? nil : RemoteMachine.named(record.runOn) }
    /// On Shelby-PC in either way: an open model there, or the agent running there.
    var usesPC: Bool { !isDot && (record.openModel != nil || runMachine != nil) }

    /// Where the agent works on the PC, named the first time it's needed.
    func pcWorkspace(on machine: RemoteMachine) -> String {
        if record.remoteFolder == nil { record.remoteFolder = RemoteMachine.workspaceFolder(title: record.title, id: id) }
        return machine.workspace(record.remoteFolder ?? "chat")
    }

    /// Moves the chat to another machine. Sessions stay on the machine that ran them, so the
    /// agent starts a new one there, caught up on the conversation so far.
    func setRunOn(_ machine: String?) {
        if let remoteCommand { remoteCommand("settings", ["runOn": machine.map(JSON.string) ?? .null]); return }
        guard !isDot, machine != record.runOn, !isRunning else { return }
        claudeWorkingFolderChanged()
        if let thread = record.codex?.threadId { Task { await codexServer.unsubscribeIdleThread(thread) } }
        record.codex?.threadId = nil
        record.codexHost = nil
        record.codexSeenThrough = nil
        record.runOn = machine
        let transcript = Self.transcript(record.items[...])
        if !transcript.isEmpty {
            record.pendingHandoff = Prompts.handoff(from: "", transcript: transcript, isWholeConversation: true,
                                                    toolsUsed: Self.toolsUsed(record.items[...]))
        }
        noteSettingsChange()
        onChange?(self)
    }

    /// Picks an open-weight model from the PC (nil goes back to the agent's own models).
    /// Claude restarts with the new endpoint, resuming its session; Codex reloads its thread.
    func setOpenModel(_ model: String?) {
        if let remoteCommand { remoteCommand("settings", ["openModel": model.map(JSON.string) ?? .null]); return }
        guard !isDot, model != record.openModel else { return }
        record.openModel = model
        if record.backend == .claude { restartClaudeForNewTools() }
        noteSettingsChange()
        onChange?(self)
    }

    // MARK: - Open-weight models

    /// Ollama's address as the agent sees it: on the PC itself, or through the tunnel.
    var openModelBase: String {
        "http://127.0.0.1:\(runMachine == nil ? PCModels.tunnelPort : PCModels.ollamaPort)"
    }

    /// Claude Code pointed at Ollama's Anthropic-compatible API, with every model alias
    /// (subagents, the small model for titles) on the same open model.
    var openModelClaudeEnvironment: [String: String] {
        guard let model = record.openModel else { return [:] }
        return ["ANTHROPIC_BASE_URL": openModelBase, "ANTHROPIC_AUTH_TOKEN": "ollama", "ANTHROPIC_API_KEY": "",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": model, "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_SMALL_FAST_MODEL": model,
                "CLAUDE_CODE_SUBAGENT_MODEL": model, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
    }

    /// Codex thread config for Ollama's Responses API. `ollama` is Codex's reserved built-in
    /// id, so this provider has its own.
    var openModelCodexConfig: [String: JSON] {
        ["model_providers.chatterbox-pc": ["name": .string("Ollama on \(RemoteMachine.pc.name)"), "base_url": .string(openModelBase + "/v1"),
                                           "wire_api": "responses"],
         "model_provider": "chatterbox-pc"]
    }

    /// Ollama takes none, low, medium, high or max; Codex's own default may be higher.
    static func openModelEffort(_ effort: String?) -> String {
        switch effort {
        case "none", "low", "medium", "high", "max": effort ?? "medium"
        case "xhigh": "high"
        default: "medium"
        }
    }

    /// The tunnel for a Mac chat on an open model.
    func prepareOpenModel() async throws {
        guard record.openModel != nil, runMachine == nil else { return }
        try await PCModels.ensureTunnel()
    }

    // MARK: - Instructions

    /// Told to an agent running on the PC, so it works in Windows terms and knows where its
    /// files end up.
    func pcInstructions(workspace: String) -> String {
        guard let machine = runMachine else { return "" }
        let mirror = machine.mirrorRoot.appendingPathComponent(record.remoteFolder ?? "").path
        return """


        # Where you're running
        You're running on \(machine.name), the user's Windows 10 PC (PowerShell; Ryzen 7, 32 GB RAM, RTX 3080 Ti), \
        not on their Mac. Your workspace is `\(workspace)`: keep your files there. After each reply, files you changed \
        in it are copied to the user's Mac at `\(mirror)`, which is how they see them. Mac paths don't exist here.
        """
    }

    // MARK: - Files

    /// Puts attachments on the PC and points the message at them. Images stay local for
    /// Claude, which sends them inline.
    func uploadAttachments(_ message: UserMessage, includingImages: Bool) async -> UserMessage {
        guard let machine = runMachine else { return message }
        var remote = message
        for index in remote.attachments.indices where includingImages || remote.attachments[index].kind != .image {
            let attachment = remote.attachments[index]
            let target = machine.attachmentsRoot + #"\"# + attachment.id.uuidString.prefix(8).lowercased() + "-" + attachment.name
            do {
                try await RemoteLaunch.upload(attachment.url, to: target, on: machine)
                remote.attachments[index].path = target
            } catch {
                notice("Couldn't copy \(attachment.name) to \(machine.name): \(error.localizedDescription)")
            }
        }
        return remote
    }

    /// A file the agent wrote on the PC, copied back so it can be previewed. Returns false for
    /// a path that isn't on the PC.
    func showRemoteWrittenFile(_ path: String) -> Bool {
        guard let machine = runMachine, path.dropFirst().hasPrefix(":") else { return false }
        guard let mirror = machine.mirror(of: path) else { return true }
        let ext = mirror.pathExtension.lowercased()
        guard ["html", "htm", "svg", "png", "jpg", "jpeg", "gif", "webp"].contains(ext) || MediaKind.of(mirror) != nil else { return true }
        Task {
            do {
                try await RemoteLaunch.fetch(path, to: mirror, from: machine)
                showWrittenFile(mirror.path)
                onChange?(self)
            } catch {
                RuntimeHooks.note("Couldn't copy \(mirror.lastPathComponent) from \(machine.name): \(error.localizedDescription)")
            }
        }
        return true
    }

    /// After a turn: copies the files changed in the PC workspace since `since` (newest
    /// first, up to 200 MB) into the Mac mirror. Skips dependency and git folders.
    func mirrorPCWorkspace(changedSince since: Date?) {
        guard let machine = runMachine, let folder = record.remoteFolder else { return }
        let workspace = machine.workspace(folder)
        let after = Int((since ?? Date()).timeIntervalSince1970) - 5
        let archive = machine.attachmentsRoot + #"\mirror-"# + folder + ".tar"
        let script = """
        $ErrorActionPreference = 'Stop'
        $root = '\(workspace.replacingOccurrences(of: "'", with: "''"))'
        if (-not (Test-Path -LiteralPath $root)) { return }
        $since = [DateTimeOffset]::FromUnixTimeSeconds(\(after)).UtcDateTime
        $total = 0; $list = @()
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTimeUtc -ge $since -and $_.FullName -notmatch '\\\\(node_modules|\\.git|__pycache__|\\.venv)\\\\' } |
          Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
            if ($total + $_.Length -le 200MB) { $total += $_.Length; $list += $_.FullName.Substring($root.Length + 1) } }
        if ($list.Count -eq 0) { return }
        $names = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllLines($names, $list)
        tar -cf '\(archive)' -C $root -T $names
        Remove-Item $names
        'ok'
        """
        let local = machine.mirrorRoot.appendingPathComponent(folder, isDirectory: true)
        Task.detached {
            do {
                let out = try await RemoteLaunch.run(script, on: machine, connectTimeout: 10)
                guard String(decoding: out, as: UTF8.self).contains("ok") else { return }
                let tar = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-mirror-\(folder).tar")
                try await RemoteLaunch.fetch(archive, to: tar, from: machine)
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                _ = try await RemoteLaunch.process("/usr/bin/tar", ["-xf", tar.path, "-C", local.path])
                try? FileManager.default.removeItem(at: tar)
                _ = try? await RemoteLaunch.run("Remove-Item -LiteralPath '\(archive)' -ErrorAction SilentlyContinue", on: machine)
            } catch {
                await MainActor.run { RuntimeHooks.note("Couldn't copy files back from \(machine.name): \(error.localizedDescription)") }
            }
        }
    }
}
