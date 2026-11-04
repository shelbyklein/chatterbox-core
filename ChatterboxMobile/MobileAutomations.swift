import SwiftUI

// Automations on the phone: every project's routines, to switch on or off, change and run.

/// Automations, from the session lists' ⋯ menu and the Desk: every project's routines, the
/// soonest to run first. The Mac keeps one automation per weekday; a routine is those alike but
/// for the day, shown as one. Its switch turns every day on or off, its last run opens that
/// run's session, and tapping it opens its editor, with Run Now.
struct MobileAutomationsView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// A run's session to open: the presenter opens it once this sheet has closed.
    var open: (UUID) -> Void = { MobilePushNotifications.shared.pendingChat = $0 }
    @State private var routines: [Companion.AutomationRoutine]?
    @State private var problem: String?
    @State private var editing: Companion.AutomationRoutine?
    /// Routines whose switch is on its way to the Mac.
    @State private var switching = Set<UUID>()

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Section { Label(problem, systemImage: "wifi.exclamationmark").foregroundStyle(.orange) }
                }
                if let routines {
                    if routines.isEmpty {
                        ContentUnavailableView("No automations yet", systemImage: "clock.arrow.circlepath",
                                               description: Text("Set one up on the Mac: right-click a project and choose Automations."))
                    }
                    ForEach(routines) { routine in
                        MobileAutomationRow(routine: routine, switching: switching.contains(routine.id),
                                            edit: { editing = routine },
                                            setEnabled: { setEnabled(routine, $0) },
                                            openRun: openSession)
                    }
                } else if problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Automations")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $editing) { routine in
                MobileAutomationEditor(routine: routine, saved: replace, ran: openSession)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            // On screen: kept current (a run finishing, a change on the Mac).
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(8))
                }
            }
        }
    }

    private func load() async {
        do {
            let fresh = try await store.automations()
            // A switch on its way keeps showing where it was moved.
            guard switching.isEmpty else { return }
            routines = fresh
            problem = nil
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { problem = MobileAutomations.describe(error) }
        }
    }

    /// The routine as the Mac now has it, in place of what it was (its ids may have changed).
    private func replace(_ routine: Companion.AutomationRoutine) {
        guard let index = routines?.firstIndex(where: { !Set($0.ids).isDisjoint(with: routine.ids) }) else { return }
        routines?[index] = routine
    }

    private func setEnabled(_ routine: Companion.AutomationRoutine, _ on: Bool) {
        guard switching.insert(routine.id).inserted else { return }
        if let index = routines?.firstIndex(where: { $0.id == routine.id }) { routines?[index].enabled = on }
        Task {
            defer { switching.remove(routine.id) }
            do {
                replace(try await store.editAutomation(routine.id, .init(enabled: on)))
                problem = nil
            } catch {
                replace(routine)
                problem = MobileAutomations.describe(error)
            }
        }
    }

    private func openSession(_ id: UUID) {
        open(id)
        dismiss()
    }
}

/// One routine: its name, project and agent, when it runs, its switch, and its last run.
private struct MobileAutomationRow: View {
    let routine: Companion.AutomationRoutine
    let switching: Bool
    let edit: () -> Void
    let setEnabled: (Bool) -> Void
    let openRun: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: edit) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        MobileAgentIcon(agent: routine.agent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.title).font(.headline).foregroundStyle(.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text("\(routine.project) · \(MobileAutomations.agent(routine))")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text(MobileAutomations.schedule(routine))
                                .font(.subheadline).foregroundStyle(routine.enabled ? .primary : .secondary).lineLimit(2)
                            Text(MobileAutomations.status(routine))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens its editor, with Run Now")
                .accessibilityIdentifier("automation-\(routine.id.uuidString)")
                Toggle("On", isOn: Binding(get: { routine.enabled }, set: setEnabled))
                    .labelsHidden()
                    .disabled(switching)
                    .accessibilityLabel("\(routine.title) on")
                    .accessibilityIdentifier("automation-switch-\(routine.id.uuidString)")
            }
            if let last = routine.lastRunAt {
                MobileLastRun(routine: routine, last: last, open: openRun)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }
}

/// "Last run 2 hours ago", and what it said; tapping opens the run's session.
private struct MobileLastRun: View {
    let routine: Companion.AutomationRoutine
    let last: Date
    let open: (UUID) -> Void

    var body: some View {
        if let thread = routine.lastThreadID {
            Button { open(thread) } label: { label(opens: true) }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens the run's session")
                .accessibilityIdentifier("automation-last-run-\(routine.id.uuidString)")
        } else {
            label(opens: false)
        }
    }

    private func label(opens: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if routine.isRunning == true {
                    ProgressView().controlSize(.mini)
                    Text("Running now, started \(last.formatted(.relative(presentation: .named)))")
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Last run \(last.formatted(.relative(presentation: .named)))")
                }
                if opens { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)) }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(opens ? Color.accentColor : Color.secondary)
            if let result = routine.lastResult, !result.isEmpty {
                Text(result).font(.caption).foregroundStyle(Color.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
    }
}

private struct MobileAgentIcon: View {
    let agent: String
    var body: some View {
        Image((Backend(rawValue: agent) ?? .claude).iconName)
            .resizable().scaledToFit().frame(width: 16, height: 16)
            .foregroundStyle(MobileConversationStyle.accent(for: agent))
            .accessibilityLabel(agent == "codex" ? "Codex" : "Claude")
    }
}

/// A routine's editor: its name, what each run does, its days and time, its agent, and its
/// switch; Save sends what changed (to every day). Run Now runs it, saving first, and opens
/// the run's session.
struct MobileAutomationEditor: View {
    let saved: (Companion.AutomationRoutine) -> Void
    let ran: (UUID) -> Void
    @Environment(MobileStore.self) private var store
    @State private var routine: Companion.AutomationRoutine
    @State private var title: String
    @State private var instructions: String
    @State private var days: Set<Int>
    @State private var time: Date
    @State private var agent: String
    @State private var enabled: Bool
    @State private var saving = false
    @State private var running = false
    @State private var problem: String?

    init(routine: Companion.AutomationRoutine, saved: @escaping (Companion.AutomationRoutine) -> Void, ran: @escaping (UUID) -> Void) {
        self.saved = saved
        self.ran = ran
        _routine = State(initialValue: routine)
        _title = State(initialValue: routine.title)
        _instructions = State(initialValue: routine.instructions)
        _days = State(initialValue: Set(routine.days))
        _time = State(initialValue: MobileAutomations.date(hour: routine.hour, minute: routine.minute))
        _agent = State(initialValue: routine.agent)
        _enabled = State(initialValue: routine.enabled)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hourAndMinute: (hour: Int, minute: Int) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? routine.hour, parts.minute ?? routine.minute)
    }

    /// What's changed here, and only that.
    private var change: Companion.AutomationEdit {
        var change = Companion.AutomationEdit()
        if trimmedTitle != routine.title { change.title = trimmedTitle }
        if instructions != routine.instructions { change.instructions = instructions }
        if days != Set(routine.days) { change.days = days.sorted() }
        if hourAndMinute.hour != routine.hour { change.hour = hourAndMinute.hour }
        if hourAndMinute.minute != routine.minute { change.minute = hourAndMinute.minute }
        if agent != routine.agent { change.agent = agent }
        if enabled != routine.enabled { change.enabled = enabled }
        return change
    }
    private var changed: Bool {
        let c = change
        return c.title != nil || c.instructions != nil || c.days != nil || c.hour != nil || c.minute != nil || c.agent != nil || c.enabled != nil
    }
    private var invalid: Bool { trimmedTitle.isEmpty || days.isEmpty }

    var body: some View {
        Form {
            Section { runNow } footer: { Text(runFooter) }
            Section("Name") {
                TextField("Name", text: $title)
                    .accessibilityIdentifier("automation-title")
            }
            Section {
                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("automation-instructions")
            } header: {
                Text("What each run does")
            } footer: {
                Text("Every run also reports first and asks before changing anything, never touches staging or production without your approval, and backs up first. Its report goes to \(routine.project)'s session.")
            }
            Section {
                dayChips
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("automation-time")
            } header: {
                Text("Schedule")
            } footer: {
                Text(days.isEmpty ? "Pick at least one day." : "\(MobileAutomations.days(days.sorted())) at \(MobileAutomations.time(hour: hourAndMinute.hour, minute: hourAndMinute.minute)).")
            }
            Section {
                Picker("Agent", selection: $agent) {
                    Text("Claude").tag(Backend.claude.rawValue)
                    Text("Codex").tag(Backend.codex.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("automation-agent")
            } header: {
                Text("Agent")
            } footer: {
                Text(agentFooter)
            }
            Section {
                Toggle("On", isOn: $enabled)
                    .accessibilityIdentifier("automation-enabled")
            } footer: {
                Text(enabledFooter)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(routine.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { try? await save() } }
                    .bold()
                    .disabled(!changed || invalid || saving || running)
                    .accessibilityIdentifier("automation-save")
            }
        }
        .alert("Couldn't update the automation", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }

    /// Run Now, prominent: it runs the routine and opens the run's session.
    private var runNow: some View {
        Button(action: run) {
            HStack(spacing: 8) {
                if running { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                Text(running ? "Starting…" : changed ? "Save and Run Now" : "Run Now")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(running || saving || (changed && invalid))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("automation-run")
    }

    private var runFooter: String {
        var parts = ["Runs as a sidequest of \(routine.project)'s session, then opens it."]
        if let last = routine.lastRunAt {
            parts.append(routine.isRunning == true ? "Running now." : "Last run \(last.formatted(.relative(presentation: .named))).")
        }
        if routine.enabled, let next = routine.nextRunAt { parts.append("Next \(next.formatted(.relative(presentation: .named))).") }
        return parts.joined(separator: " ")
    }

    private var agentFooter: String {
        let name = agent == Backend.codex.rawValue ? "Codex" : "Claude"
        guard agent == routine.agent else { return "Runs on \(name)'s default model and effort. Pick another on the Mac." }
        let model = [routine.model, routine.effort.map { "\($0) effort" }].compactMap { $0 }
        return model.isEmpty ? "\(name)'s default model and effort." : model.joined(separator: " · ") + "."
    }

    private var enabledFooter: String {
        guard enabled else { return "Off: it runs only when you run it." }
        if let paused = routine.pausedDays, !paused.isEmpty, enabled == routine.enabled {
            return "Off on \(MobileAutomations.days(paused)), switched off on the Mac."
        }
        return "Runs on its schedule."
    }

    /// The week's days, from the first day of the week here, as chips to switch on and off.
    private var dayChips: some View {
        HStack(spacing: 4) {
            ForEach(MobileAutomations.week, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityValue(on ? "On" : "Off")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("automation-day-\(day)")
            }
        }
        .padding(.vertical, 4)
    }

    /// Sends what changed; the routine comes back as the Mac now has it.
    private func save() async throws {
        guard changed, !invalid else { return }
        saving = true
        defer { saving = false }
        do {
            let updated = try await store.editAutomation(routine.id, change)
            routine = updated
            title = updated.title
            instructions = updated.instructions
            days = Set(updated.days)
            time = MobileAutomations.date(hour: updated.hour, minute: updated.minute)
            agent = updated.agent
            enabled = updated.enabled
            saved(updated)
        } catch {
            problem = MobileAutomations.describe(error)
            throw error
        }
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            defer { running = false }
            do {
                if changed { try await save() }
                let run = try await store.runAutomation(routine.id)
                ran(run.summary.id)
            } catch {
                if problem == nil { problem = MobileAutomations.describe(error) }
            }
        }
    }
}

/// How routines read on the phone.
enum MobileAutomations {
    /// Weekdays (1 Sunday to 7 Saturday) from the first day of the week here.
    static var week: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// "Every day", "Weekdays", "Weekends", "Mondays", "Every day but Sunday", or "Mon, Wed, Fri".
    static func days(_ days: [Int]) -> String {
        let set = Set(days)
        if set == Set(1...7) { return "Every day" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        let calendar = Calendar.current
        if set.count == 1, let day = set.first, (1...7).contains(day) { return calendar.weekdaySymbols[day - 1] + "s" }
        if set.count == 6, let off = Set(1...7).subtracting(set).first { return "Every day but \(calendar.weekdaySymbols[off - 1])" }
        return week.filter(set.contains).map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }

    static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    /// "8:30 AM".
    static func time(hour: Int, minute: Int) -> String {
        date(hour: hour, minute: minute).formatted(date: .omitted, time: .shortened)
    }

    /// "Every day at 8:30 AM".
    static func schedule(_ routine: Companion.AutomationRoutine) -> String {
        "\(days(routine.days)) at \(time(hour: routine.hour, minute: routine.minute))"
    }

    /// "Codex · GPT-5.5 · High".
    static func agent(_ routine: Companion.AutomationRoutine) -> String {
        ([routine.agent == Backend.codex.rawValue ? "Codex" : "Claude"] + [routine.model, routine.effort].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// "Next in 11 hours", or why it won't run.
    static func status(_ routine: Companion.AutomationRoutine) -> String {
        guard routine.enabled else { return "Off" }
        var parts: [String] = []
        if let next = routine.nextRunAt { parts.append("Next \(next.formatted(.relative(presentation: .named)))") }
        if let paused = routine.pausedDays, !paused.isEmpty { parts.append("off on \(days(paused))") }
        return parts.joined(separator: " · ")
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? MobileError, error.status == 404 || error.message == "Not found" {
            return "Automations on the phone need the newest Chatterbox on the Mac. Update it there to use them."
        }
        return error.localizedDescription
    }
}
