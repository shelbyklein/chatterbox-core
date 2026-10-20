import AppKit
import SwiftUI

/// Settings → Tools: what agents can use at a level (ToolScopes). Chatterbox-wide and Studios
/// here; a project's own from its right-click menu (Tools…). Each level lists what it adds,
/// what it inherits, and what the agents load on their own, each with a switch.
struct ToolsSettingsView: View {
    @AppStorage("toolsSettingsScope") private var scopeName = "chatterbox"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Level", selection: $scopeName) {
                    Text("Chatterbox").tag("chatterbox")
                    Text("Studios").tag("studios")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("Projects: right-click a project \u{2192} Tools\u{2026}").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            ToolsPanel(scope: scopeName == "studios" ? .studios : .chatterbox)
                .id(scopeName)
        }
    }
}

/// A project's Tools… sheet.
struct ProjectToolsSheet: View {
    let folder: String
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools").font(.title2.weight(.semibold))
                    Text(name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ToolsPanel(scope: .project(folder), projectFolder: folder)
        }
        .frame(width: 680, height: 680)
    }
}

/// One level's tools, editable.
struct ToolsPanel: View {
    let scope: ToolScope
    var projectFolder: String?
    @Environment(AppModel.self) private var model
    @State private var sets: [String: ToolSet] = [:]
    @State private var outside: [DiscoveredTool] = []
    @State private var editing: ToolServer?
    @State private var problem: String?

    private var set: ToolSet { sets[scope.key] ?? ToolSet() }
    private var inherited: ToolSet? { scope == .chatterbox ? nil : sets[ToolScope.chatterbox.key] }
    private var levelName: String {
        switch scope { case .chatterbox: "every session"; case .studios: "every Studio session"; case .project: "this project's sessions" }
    }

    var body: some View {
        Form {
            serversSection(kind: .command, title: "MCP servers",
                           note: "Servers agents run on this Mac. On here applies to \(levelName).")
            connectorsSection
            skillsSection
            if let problem { Text(problem).foregroundStyle(.orange).font(.callout) }
        }
        .formStyle(.grouped)
        .task { reload() }
        .sheet(item: $editing) { server in
            ToolServerEditor(server: server, isNew: !set.servers.contains { $0.id == server.id }) { saved in
                change { s in
                    if let i = s.servers.firstIndex(where: { $0.id == saved.id }) { s.servers[i] = saved } else { s.servers.append(saved) }
                }
            } onDelete: {
                change { $0.servers.removeAll { $0.id == server.id } }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func serversSection(kind: ToolServer.Kind, title: String, note: String) -> some View {
        Section {
            ForEach(set.servers.filter { $0.kind == kind }) { server in
                ownRow(server)
            }
            if let inherited {
                ForEach(inherited.servers.filter { $0.kind == kind && $0.enabled }) { server in
                    toggleRow(server.name, detail: detail(server), source: "Chatterbox-wide", agents: server.agents, key: ToolKey.server(server.name))
                }
            }
            ForEach(outside.filter { $0.kind == .server && ((kind == .url) == $0.detail.hasPrefix("http")) }) { item in
                outsideRow(item)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button(kind == .url ? "Add Remote Server" : "Add Server", systemImage: "plus") {
                    editing = ToolServer(name: "", kind: kind)
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectorsSection: some View {
        Group {
            serversSection(kind: .url, title: "Connectors and remote servers",
                           note: "Remote MCP servers by URL, and your claude.ai and ChatGPT account connectors (added on claude.ai or chatgpt.com; here you can only allow or block them).")
            let accounts = outside.filter { $0.kind == .connector }
            if !accounts.isEmpty {
                Section("Account connectors") {
                    ForEach(accounts) { item in
                        toggleRow(item.name, detail: item.detail, source: item.source == .codex ? "ChatGPT" : "claude.ai", agents: item.agents, key: item.offKey)
                    }
                }
            }
        }
    }

    private var skillsSection: some View {
        Section {
            ForEach(set.skillFolders, id: \.self) { folder in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: folder).lastPathComponent)
                        Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    badge("Added here")
                    Button { change { $0.skillFolders.removeAll { $0 == folder } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this skill folder")
                }
            }
            ForEach(outside.filter { $0.kind == .skill }) { item in
                skillRow(item)
            }
        } header: {
            HStack {
                Text("Skills")
                Spacer()
                Button("Add Skill Folder", systemImage: "plus") { addSkillFolder() }.buttonStyle(.borderless)
            }
        } footer: {
            Text("A folder holding SKILL.md, or a folder of them. Switching a skill off blocks it when called in \(levelName), but Claude still lists it, so it saves no tokens; to drop a plugin's skills, disable the plugin in Claude Code (/plugin).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    private func ownRow(_ server: ToolServer) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(detail(server)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            agentBadges(server.agents)
            badge("Added here")
            Button("Edit") { editing = server }.buttonStyle(.borderless)
            Toggle("", isOn: Binding(get: { server.enabled }, set: { on in
                change { s in if let i = s.servers.firstIndex(where: { $0.id == server.id }) { s.servers[i].enabled = on } }
            })).labelsHidden().toggleStyle(.switch)
        }
    }

    private func outsideRow(_ item: DiscoveredTool) -> some View {
        let imported = (sets[scope.key]?.servers ?? []).contains { $0.name == ToolServer.cleanName(item.name) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            agentBadges(item.agents)
            badge("From \(item.source.rawValue)")
            if let server = item.importable, !imported {
                Button("Import") { importServer(server) }.buttonStyle(.borderless)
                    .help("Copy it into Chatterbox at this level. Your own config file isn't changed.")
            }
            offSwitch(item.offKey, offThere: !item.enabledThere)
        }
    }

    /// A skill the agents have: which agents, Share with the other one, and a note when the
    /// two agents' copies differ.
    private func skillRow(_ item: DiscoveredTool) -> some View {
        let shared = sets[scope.key]?.skillFolders.contains(item.detail) == true
        let other: Backend? = item.agents.count == 1 ? (item.agents[0] == .claude ? .codex : .claude) : nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                    if item.drift {
                        Text("Different versions").font(.caption2).foregroundStyle(.orange)
                            .help("Claude and Codex each have their own copy of this skill, and they differ. Keep one in a shared folder (for example ~/.agents/skills) to use the same version in both.")
                    }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            agentBadges(item.agents + (shared ? [other].compactMap { $0 } : []))
            badge("From \(item.source.rawValue)")
            if let other, !item.drift {
                if shared {
                    Button("Stop Sharing") {
                        change { $0.skillFolders.removeAll { $0 == item.detail }; $0.skillFolderAgents[item.detail] = nil }
                    }.buttonStyle(.borderless)
                } else {
                    Button("Share with \(other.label)") {
                        change { $0.skillFolders.append(item.detail); $0.skillFolderAgents[item.detail] = [other] }
                    }
                    .buttonStyle(.borderless)
                    .help("\(other.label) sessions get this skill too, from the same folder")
                }
            }
            offSwitch(item.offKey, offThere: !item.enabledThere)
        }
    }

    private func toggleRow(_ name: String, detail: String, source: String, agents: [Backend], key: String, offThere: Bool = false) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            agentBadges(agents)
            badge(source)
            offSwitch(key, offThere: offThere)
        }
    }

    /// On unless this level (or Chatterbox-wide, for a lower level) turned it off.
    @ViewBuilder
    private func offSwitch(_ key: String, offThere: Bool) -> some View {
        let offAbove = inherited?.off.contains(key) == true
        if offThere {
            Text("Off in its own config").font(.caption).foregroundStyle(.secondary)
        } else if offAbove {
            Text("Off everywhere").font(.caption).foregroundStyle(.secondary)
                .help("Turned off Chatterbox-wide; turn it on there first")
        } else {
            Toggle("", isOn: Binding(get: { !set.off.contains(key) }, set: { on in
                change { s in if on { s.off.removeAll { $0 == key } } else if !s.off.contains(key) { s.off.append(key) } }
            })).labelsHidden().toggleStyle(.switch)
        }
    }

    private func agentBadges(_ agents: [Backend]) -> some View {
        HStack(spacing: 3) {
            ForEach(agents) { agent in
                Image(agent.iconName).resizable().scaledToFit().frame(width: 12, height: 12).foregroundStyle(.secondary)
                    .help(agent.label)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func detail(_ server: ToolServer) -> String {
        server.kind == .url ? server.url : ([server.command] + server.args).joined(separator: " ")
    }

    // MARK: Changes

    private func reload() {
        sets = ToolScopes.load()
        let folder = projectFolder
        Task.detached(priority: .userInitiated) {
            let found = ToolDiscovery.discover(projectFolder: folder)
            await MainActor.run { outside = found }
        }
    }

    private func change(_ edit: (inout ToolSet) -> Void) {
        var next = sets[scope.key] ?? ToolSet()
        edit(&next)
        sets[scope.key] = next
        do {
            try ToolScopes.save(sets)
            problem = nil
            // Nothing to send: each chat picks the change up with its next message (Claude
            // restarts its process then; Codex reloads its thread from the configuration key).
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func importServer(_ server: ToolServer) {
        var copy = server
        copy.id = UUID()
        change { $0.servers.append(copy) }
        editing = copy
    }

    private func addSkillFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "A skill folder (with SKILL.md), or a folder of skills"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { if !$0.skillFolders.contains(url.path) { $0.skillFolders.append(url.path) } }
    }
}

/// Adding or editing a server: a command or a URL, keys from Secrets, which agents get it.
struct ToolServerEditor: View {
    @State var server: ToolServer
    let isNew: Bool
    let save: (ToolServer) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var argsText = ""
    @State private var keyName = ""
    @State private var keySecret = ""

    private var secrets: [SecretEntry] { SecretVault.shared.entries }
    private var valid: Bool {
        !ToolServer.cleanName(server.name).isEmpty && (server.kind == .url ? URL(string: server.url)?.scheme?.hasPrefix("http") == true : !server.command.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $server.name, prompt: Text("linear"))
                Picker("Kind", selection: $server.kind) {
                    Text("Command").tag(ToolServer.Kind.command)
                    Text("URL").tag(ToolServer.Kind.url)
                }.pickerStyle(.segmented)
                if server.kind == .command {
                    TextField("Command", text: $server.command, prompt: Text("/usr/local/bin/my-mcp"))
                    TextField("Arguments", text: $argsText, prompt: Text("--stdio"))
                    Section("Keys from Secrets") {
                        ForEach(server.secretEnv.sorted(by: { $0.key < $1.key }), id: \.key) { name, variable in
                            HStack {
                                Text(name).font(.body.monospaced())
                                Text("\u{2190} \(variable)").foregroundStyle(.secondary)
                                Spacer()
                                Button { server.secretEnv[name] = nil } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Variable", text: $keyName, prompt: Text("API_KEY")).frame(width: 140)
                            Picker("from", selection: $keySecret) {
                                Text("Choose a secret").tag("")
                                ForEach(secrets) { Text($0.name).tag($0.variable) }
                            }
                            Button("Add") { server.secretEnv[keyName] = keySecret; keyName = ""; keySecret = "" }
                                .disabled(keyName.isEmpty || keySecret.isEmpty)
                        }
                        if secrets.isEmpty { Text("Add keys in Settings \u{2192} Secrets first.").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    TextField("URL", text: $server.url, prompt: Text("https://mcp.example.com/mcp"))
                    Picker("Token", selection: Binding(get: { server.bearerSecret ?? "" }, set: { server.bearerSecret = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(secrets) { Text($0.name).tag($0.variable) }
                    }
                    .help("Sent as a bearer token. Servers that need a browser sign-in: sign in from the agent's own settings.")
                }
                Section("Agents") {
                    ForEach(Backend.allCases) { agent in
                        Toggle(agent.label, isOn: Binding(get: { server.agents.contains(agent) }, set: { on in
                            if on { server.agents.append(agent) } else { server.agents.removeAll { $0 == agent } }
                        }))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew { Button("Delete Server", role: .destructive) { onDelete(); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    server.name = ToolServer.cleanName(server.name)
                    server.args = argsText.split(separator: " ").map(String.init)
                    save(server)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || server.agents.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onAppear { argsText = server.args.joined(separator: " ") }
    }
}

/// In a chat's Session tools: the MCP servers this chat's agent loads (its own config's, and
/// what Chatterbox adds or switched off), whether their tools load on demand, and where to
/// change it.
struct SessionToolsSummary: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model
    @State private var editingProject = false
    @State private var servers: [ToolDiscovery.LoadedServer]?

    var body: some View {
        let backend = session.record.backend
        let tools = ToolScopes.effective(for: session)
        // Servers are listed above; this is skills, connectors and ChatGPT apps.
        let otherOff = tools.off.filter { !$0.hasPrefix("server:") }.sorted()
        VStack(alignment: .leading, spacing: 6) {
            Text("Tools").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let servers {
                        if servers.isEmpty {
                            Text("No MCP servers in \(backend.label)'s config or Chatterbox.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("MCP servers \(backend.label) loads").font(.caption.weight(.medium))
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(servers) { serverRow($0) }
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if backend == .claude {
                        Text(session.claudeToolSearch ? "Tool search is on: MCP tools load on demand." : "Tool search is off: every MCP tool loads at the start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !otherOff.isEmpty {
                        Text("Off: " + otherOff.map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let folder = ToolScopes.projectFolder(of: session) {
                    Button("Edit for \(session.projectName)\u{2026}") { editingProject = true }
                        .sheet(isPresented: $editingProject) {
                            ProjectToolsSheet(folder: folder, name: session.projectName).environment(model)
                        }
                }
                Button(session.record.studioID != nil ? "Edit for Studios\u{2026}" : "Edit\u{2026}") {
                    AppPreferences.defaults.set("tools", forKey: "settingsPage")
                    AppPreferences.defaults.set(session.record.studioID != nil ? "studios" : "chatterbox", forKey: "toolsSettingsScope")
                    model.showingSettings = true
                }
            }
            .buttonStyle(.link).font(.caption)
        }
        .accessibilityElement(children: .contain)
        .task {
            let backend = session.record.backend, folder = session.record.boundFolder, tools = ToolScopes.effective(for: session)
            servers = await Task.detached(priority: .userInitiated) {
                ToolDiscovery.loadedServers(backend, projectFolder: folder, tools: tools)
            }.value
        }
    }

    private func serverRow(_ server: ToolDiscovery.LoadedServer) -> some View {
        let note: String = switch server.state {
        case .on: "From \(server.source)"
        case .offInChatterbox: "Off in Chatterbox"
        case .offInConfig: "Off in its config"
        case .addedInChatterbox: "Added in Chatterbox"
        }
        let off = server.state == .offInChatterbox || server.state == .offInConfig
        return HStack(spacing: 6) {
            Text(server.name).font(.caption).strikethrough(off).foregroundStyle(off ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(note).font(.caption2).foregroundStyle(server.state == .addedInChatterbox ? Color.accentColor : .secondary)
        }
    }
}
