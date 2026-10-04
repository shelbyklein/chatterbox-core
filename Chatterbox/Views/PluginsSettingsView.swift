import SwiftUI

/// Settings → Plugins: Chatterbox's own plugins, each a feature you can turn on or off.
struct PluginsSettingsView: View {
    var body: some View {
        Form {
            Section("Golem") {
                Toggle("Connect Golem to Chatterbox",isOn:Binding(get:{GolemIntegration.shared.enabled},set:{GolemIntegration.shared.setEnabled($0)}))
                LabeledContent("Status",value:GolemIntegration.shared.problem ?? (GolemIntegration.shared.enabled ? "Connected":"Disabled"))
                Button("Open Golem"){GolemIntegration.shared.open()}
                Text("Golem runs as a separate app and background service. Disabling this connection stops access to Chatterbox chats. Use Golem’s service controls to stop its independent jobs.").font(.caption).foregroundStyle(.secondary)
            }
            .task{while !Task.isCancelled{await GolemIntegration.shared.refresh();try? await Task.sleep(for:.seconds(3))}}
            ForEach(ChatterboxPlugin.allCases) { plugin in
                Section {
                    PluginRow(plugin: plugin)
                    switch plugin {
                    case .nextSteps: NextStepsOptions()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PluginRow: View {
    let plugin: ChatterboxPlugin
    @State private var isOn: Bool

    init(plugin: ChatterboxPlugin) {
        self.plugin = plugin
        _isOn = State(initialValue: plugin.isOn)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { isOn = $0; plugin.isOn = $0 })) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.title).font(.headline)
                    Text(plugin.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: plugin.icon).foregroundStyle(Color.highlight)
            }
        }
        .toggleStyle(.switch)
    }
}

private struct NextStepsOptions: View {
    @AppStorage(NextSteps.minAnswerKey) private var minAnswerChars = 80
    @AppStorage(NextSteps.suggestCommandsKey) private var suggestCommands = true
    @AppStorage("plugin.nextSteps.enabled") private var enabled = true

    var body: some View {
        Group {
            Stepper(value: $minAnswerChars, in: 0...2000, step: 20) {
                LabeledContent("Skip replies shorter than", value: "\(minAnswerChars) characters")
            }
            Toggle("Suggest the chat's slash commands and skills", isOn: $suggestCommands)
            Text("Each suggestion costs one short request after a reply: Claude Haiku for Claude chats, GPT-6-Luna for Codex chats, on your existing sign-ins. Shows in your chats and Golem's on the Mac, and on iPhone and iPad.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!enabled)
    }
}
