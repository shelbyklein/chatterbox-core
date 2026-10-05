import SwiftUI

/// A project's automations: what each does, when it runs, and its thread. Opened from a
/// project's right-click menu (Automations…).
struct AutomationsSheet: View {
    let projectFolder: String
    let projectName: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var automations: [ProjectAutomation] = []
    @State private var state: [String: AutomationRunState] = [:]
    @State private var editing: UUID?
    @State private var problem: String?
    @State private var running: UUID?

    private var mine: [ProjectAutomation] { automations.filter { $0.projectFolder == projectFolder } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automations").font(.title2.weight(.semibold))
                    Text(projectName).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(ProjectAutomation.Template.allCases) { template in
                        Button(template.label) { add(template) }
                    }
                } label: { Label("Add Automation", systemImage: "plus") }
                .fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if mine.isEmpty {
                ContentUnavailableView {
                    Label("No automations yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("An automation runs on a schedule in this project's own Automation thread, separate from its main chat. Each run reports what it finds and asks before changing anything.")
                } actions: {
                    Button("Keep WordPress Updated") { add(.wordpress) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(mine) { automation in
                        Section { row(automation) }
                    }
                }
                .formStyle(.grouped)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .frame(width: 640, height: 620)
        .task { reload() }
    }

    @ViewBuilder
    private func row(_ automation: ProjectAutomation) -> some View {
        let isEditing = editing == automation.id
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: binding(automation, \.enabled)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(automation.title).font(.headline)
                    Text(statusLine(automation)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Spacer()
            Button(running == automation.id ? "Starting\u{2026}" : "Run Now") { runNow(automation) }
                .disabled(running != nil || !RuntimeClient.usesDaemon)
            if let thread = state[automation.id.uuidString]?.threadID, model.sessions.contains(where: { $0.id == thread }) {
                Button("Open Thread") { model.selectedID = thread; dismiss() }
            }
            Button(isEditing ? "Done" : "Edit") { editing = isEditing ? nil : automation.id }
        }
        if isEditing {
            TextField("Name", text: binding(automation, \.title))
            Picker("Every", selection: binding(automation, \.weekday)) {
                ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
            }
            DatePicker("At", selection: Binding(get: { time(automation) }, set: { setTime(automation, $0) }),
                       displayedComponents: .hourAndMinute)
            Picker("Preset", selection: binding(automation, \.preset)) {
                Text("The thread's own model").tag(UUID?.none)
                ForEach(ModelPresets.shared.presets) { preset in
                    Text(preset.nickname.map { "\($0) \u{00B7} \(preset.title)" } ?? preset.title).tag(UUID?.some(preset.id))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What each run does").font(.subheadline)
                TextEditor(text: binding(automation, \.instructions))
                    .font(.callout)
                    .frame(minHeight: 160)
                Text("Every run also follows these rules: report first and ask before changing anything, never touch staging or production without your approval in the thread, and back up first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Delete Automation", role: .destructive) { delete(automation) }
            }
        }
    }

    private func statusLine(_ automation: ProjectAutomation) -> String {
        var parts = [ProjectAutomations.scheduleText(automation)]
        if automation.enabled, let next = ProjectAutomations.nextOccurrence(of: automation) {
            parts.append("next \(next.formatted(date: .abbreviated, time: .shortened))")
        } else if !automation.enabled {
            parts.append("paused")
        }
        if let last = state[automation.id.uuidString]?.lastRun {
            parts.append("last ran \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Changes

    private func reload() {
        automations = ProjectAutomations.load()
        state = ProjectAutomations.loadState()
    }

    private func commit() {
        do { try ProjectAutomations.save(automations); problem = nil }
        catch { problem = "Couldn't save: \(error.localizedDescription)" }
    }

    private func binding<Value>(_ automation: ProjectAutomation, _ key: WritableKeyPath<ProjectAutomation, Value>) -> Binding<Value> {
        Binding(get: {
            automations.first { $0.id == automation.id }?[keyPath: key] ?? automation[keyPath: key]
        }, set: { value in
            guard let index = automations.firstIndex(where: { $0.id == automation.id }) else { return }
            automations[index][keyPath: key] = value
            commit()
        })
    }

    private func time(_ automation: ProjectAutomation) -> Date {
        let current = automations.first { $0.id == automation.id } ?? automation
        return Calendar.current.date(from: DateComponents(hour: current.hour, minute: current.minute)) ?? Date()
    }

    private func setTime(_ automation: ProjectAutomation, _ date: Date) {
        guard let index = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        automations[index].hour = parts.hour ?? 9
        automations[index].minute = parts.minute ?? 0
        commit()
    }

    private func add(_ template: ProjectAutomation.Template) {
        let automation = ProjectAutomation(projectFolder: projectFolder, title: template.defaultTitle, template: template,
                                           instructions: template.defaultInstructions)
        automations.append(automation)
        editing = automation.id
        commit()
    }

    private func delete(_ automation: ProjectAutomation) {
        automations.removeAll { $0.id == automation.id }
        editing = nil
        commit()
    }

    private func runNow(_ automation: ProjectAutomation) {
        running = automation.id
        Task {
            defer { running = nil }
            do {
                let reply = try await RuntimeClient.shared.request("runAutomation", body: ["id": .string(automation.id.uuidString)])
                reload()
                if let id = reply["threadID"]?.string.flatMap(UUID.init(uuidString:)) {
                    // The new thread reaches the sidebar with the next list update.
                    for _ in 0..<20 where !model.sessions.contains(where: { $0.id == id }) { try? await Task.sleep(for: .milliseconds(150)) }
                    model.selectedID = id
                    dismiss()
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
