import Foundation

/// A recurring job for a project, run by the background service in the project's own
/// Automation thread (a Sidechat kept for it), so the project's main chat isn't disturbed.
/// Every run reports what it finds and asks before changing anything.
struct ProjectAutomation: Codable, Identifiable, Equatable {
    enum Template: String, Codable, CaseIterable, Identifiable {
        case wordpress, custom
        var id: String { rawValue }
        var label: String { self == .wordpress ? "Keep WordPress Updated" : "Custom" }
        var defaultTitle: String { self == .wordpress ? "WordPress updates" : "Weekly check" }
        var defaultInstructions: String { self == .wordpress ? ProjectAutomations.wordpressInstructions : "" }
    }

    var id = UUID()
    /// nil means a general routine, independent of every development project.
    var projectFolder: String?
    var reportSessionID: UUID?
    var reportSessionTitle: String?
    var title: String
    var template: Template
    var instructions: String
    /// Calendar weekday: 1 is Sunday, 7 Saturday.
    var weekday: Int = 2
    var hour: Int = 9
    var minute: Int = 0
    var enabled = true
    /// A model preset each run starts with (older automations); `backend`/`model`/`effort`,
    /// when set, are what runs use instead.
    var preset: UUID?
    /// "claude" or "codex"; nil means the project chat's own agent.
    var backend: String?
    /// The agent's model id; nil means its default.
    var model: String?
    /// nil means the model's default effort.
    var effort: String?
    var createdAt = Date()
}

extension ProjectAutomation {
    var isGeneral: Bool { projectFolder == nil }
    var reportingTitle: String { reportSessionTitle ?? title }

    func validateTarget() throws {
        let valid = projectFolder.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reportSessionID == nil && reportSessionTitle == nil }
            ?? (reportSessionID != nil)
        guard valid else { throw NSError(domain: "AutomationTarget", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Choose General with a reporting session, or a project, for the automation."]) }
    }
}

/// What the service has done with an automation; written only by the service.
struct AutomationRunState: Codable {
    var lastRun: Date?
    var threadID: UUID?
}

enum ProjectAutomations {
    /// The configured intake used by this Desk. Exact identity only: never run an unrelated
    /// maintenance routine because its instructions happen to mention mail or tasks.
    static func deskSourceRoutine(in automations: [ProjectAutomation]) throws -> [ProjectAutomation] {
        let matches = routines(in: automations).filter {
            $0.first?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("ClickUp + Outlook morning priorities") == .orderedSame
        }
        guard matches.count == 1, let routine = matches.first else {
            throw NSError(domain: "DeskSources", code: 1, userInfo: [NSLocalizedDescriptionKey:
                matches.isEmpty ? "Set up the ClickUp + Outlook morning priorities routine in Automations first." : "More than one morning-priorities routine is configured. Keep one source-check routine before checking from the Desk."])
        }
        return routine
    }

    static func deskSourceInstructions(_ configured: String, includeNew: Bool) -> String {
        """
        \(configured)

        This manual run is Check for updates from the Desk. \(includeNew ? "Find new source tasks as well as updates to existing Desk cards." : "Check existing Desk cards only; do not add new tasks.")
        - Read only the sources/accounts covered by the configured instructions above. Do not change ClickUp, send/draft email, publish, install anything, or perform the tasks themselves.
        - Use each source's last verified coverage checkpoint in the existing reports. A last-requested or last-run timestamp is NOT a coverage checkpoint. If a previous pull was partial, resume from the last verified checkpoint; report inaccessible sources and never advance their checkpoint.
        - Read `desk list --json` before adding anything. Compare its complete `tasks` inventory, including in-progress, waiting-for-Shelby, Review, silenced and Done tasks; never compare only incoming cards. De-duplicate by source reference, or sender/subject/date when no ID exists; preserve existing tasks and board columns. Update source status and verified links with `desk source REF --status STATUS --url URL --task DESK_ID`. Warn about mismatches; do not complete or archive existing tasks.
        - For genuinely new tasks, preserve the verified source reference/title/link, propose the correct place and score preparation confidence yes/no with a reason. Clear, bounded preparation is Yes even when publication, sending or follow-up needs final approval; score No only for a real blocker to preparation or an outbound-only task with no useful preparatory deliverable. Outbound approval remains required. Never invent IDs, links, successful coverage or new work when nothing changed.
        - Finish with counts of new items, updated items and sources that could not be checked, plus links to relevant source material and reports. Leave existing verified checkpoints unchanged for every partial source.
        """
    }
    /// The automations, as set in the app (Automations… on a project).
    static var configFile: URL { RuntimePaths.data.appendingPathComponent("Automations.json") }
    /// Their runs, as recorded by the background service.
    static var stateFile: URL { RuntimePaths.data.appendingPathComponent("automation-state.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> [ProjectAutomation] {
        guard let data = try? Data(contentsOf: configFile) else { return [] }
        return (try? decoder.decode([ProjectAutomation].self, from: data)) ?? []
    }

    static func save(_ automations: [ProjectAutomation]) throws {
        for automation in automations { try automation.validateTarget() }
        try encoder.encode(automations).write(to: configFile, options: .atomic)
    }

    static func loadState() -> [String: AutomationRunState] {
        guard let data = try? Data(contentsOf: stateFile) else { return [:] }
        return (try? decoder.decode([String: AutomationRunState].self, from: data)) ?? [:]
    }

    static func saveState(_ state: [String: AutomationRunState]) throws {
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    // MARK: - The schedule

    /// The latest scheduled time at or before `now`.
    static func latestOccurrence(of automation: ProjectAutomation, before now: Date, calendar: Calendar = .current) -> Date? {
        let parts = DateComponents(hour: automation.hour, minute: automation.minute, weekday: automation.weekday)
        guard let next = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) else { return nil }
        return calendar.date(byAdding: .day, value: -7, to: next)
    }

    /// The next scheduled time after `now`.
    static func nextOccurrence(of automation: ProjectAutomation, after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: now, matching: DateComponents(hour: automation.hour, minute: automation.minute, weekday: automation.weekday),
                          matchingPolicy: .nextTime)
    }

    /// Due once its latest scheduled time has passed since it last ran (or was made). A run
    /// missed while the Mac slept happens once when it wakes, not once per missed week.
    static func isDue(_ automation: ProjectAutomation, state: AutomationRunState?, now: Date = Date()) -> Bool {
        guard automation.enabled, let latest = latestOccurrence(of: automation, before: now) else { return false }
        return latest > max(state?.lastRun ?? automation.createdAt, automation.createdAt)
    }

    // MARK: - Routines

    /// What a routine's days share: everything but the day, whether it's on, and their own ids.
    private struct RoutineKey: Hashable {
        var projectFolder: String?
        var reportSessionID: UUID?
        var reportSessionTitle: String?
        var title: String
        var instructions: String
        var hour: Int
        var minute: Int
        var backend: String?
        var model: String?
        var effort: String?
        var preset: UUID?

        init(_ automation: ProjectAutomation) {
            projectFolder = automation.projectFolder; reportSessionID = automation.reportSessionID; reportSessionTitle = automation.reportSessionTitle
            title = automation.title; instructions = automation.instructions
            hour = automation.hour; minute = automation.minute
            backend = automation.backend; model = automation.model; effort = automation.effort; preset = automation.preset
        }
    }

    /// The automations as routines, as the phone shows them: a routine that runs on several
    /// days is one automation per day, alike but for the day (and whether it's on). Each
    /// routine's days in weekday order; routines in the order they were first set up.
    static func routines(in automations: [ProjectAutomation]) -> [[ProjectAutomation]] {
        var order: [RoutineKey] = []
        var groups: [RoutineKey: [ProjectAutomation]] = [:]
        for automation in automations {
            let key = RoutineKey(automation)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(automation)
        }
        return order.compactMap { groups[$0]?.sorted { $0.weekday < $1.weekday } }
    }

    /// Changes every day of the routine `id` belongs to: what `change` sets, and its days (a
    /// new day copies the routine; a day left out is deleted). New days and a new time run from
    /// now on. An agent named starts on its default model and effort, as picking it on the Mac
    /// does. `change` is already checked.
    /// Returns the routine's ids after, or nil when there's no such automation.
    static func edit(_ id: UUID, _ change: Companion.AutomationEdit, in automations: inout [ProjectAutomation], now: Date = Date()) -> [UUID]? {
        guard let routine = routines(in: automations).first(where: { $0.contains { $0.id == id } }), let first = routine.first else { return nil }
        var ids = Set(routine.map(\.id))
        if let days = change.days.map({ Set($0) }) {
            // New days go after the routine's others, and run from now on, not for a time already past.
            var at = (automations.lastIndex { ids.contains($0.id) } ?? automations.count - 1) + 1
            for day in days.subtracting(routine.map(\.weekday)).sorted() {
                var copy = first
                copy.id = UUID(); copy.weekday = day; copy.createdAt = now
                copy.enabled = routine.contains(where: \.enabled)
                automations.insert(copy, at: at); at += 1
                ids.insert(copy.id)
            }
            automations.removeAll { ids.contains($0.id) && !days.contains($0.weekday) }
            ids = ids.filter { id in automations.contains { $0.id == id } }
        }
        for index in automations.indices where ids.contains(automations[index].id) {
            if let title = change.title { automations[index].title = title }
            if let instructions = change.instructions { automations[index].instructions = instructions }
            if let hour = change.hour { automations[index].hour = hour }
            if let minute = change.minute { automations[index].minute = minute }
            // A new time runs from now on: one already past today doesn't run the moment it's set.
            if change.hour != nil || change.minute != nil { automations[index].createdAt = now }
            if let enabled = change.enabled { automations[index].enabled = enabled }
            if let agent = change.agent {
                automations[index].backend = agent
                automations[index].model = nil; automations[index].effort = nil; automations[index].preset = nil
            }
        }
        return automations.filter { ids.contains($0.id) }.map(\.id)
    }

    /// Move every weekday together, retaining its IDs, schedule, agent and run state.
    @discardableResult static func setTarget(_ id: UUID, projectFolder: String?, reportTitle: String? = nil,
                                            in automations: inout [ProjectAutomation]) -> [UUID] {
        guard let routine = routines(in: automations).first(where: { $0.contains { $0.id == id } }) else { return [] }
        let ids = Set(routine.map(\.id))
        let reportID = projectFolder == nil ? (routine.first?.reportSessionID ?? UUID()) : nil
        for index in automations.indices where ids.contains(automations[index].id) {
            automations[index].projectFolder = projectFolder
            automations[index].reportSessionID = reportID
            automations[index].reportSessionTitle = projectFolder == nil ? (reportTitle ?? routine.first?.reportSessionTitle ?? routine.first?.title) : nil
        }
        return routine.map(\.id)
    }

    /// "Mondays at 9:00 AM".
    static func scheduleText(_ automation: ProjectAutomation) -> String {
        let day = Calendar.current.weekdaySymbols[max(0, min(6, automation.weekday - 1))]
        var parts = DateComponents(); parts.hour = automation.hour; parts.minute = automation.minute
        let time = Calendar.current.date(from: parts).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(day)s at \(time)"
    }

    static func routineScheduleText(_ automation: ProjectAutomation) -> String {
        let days = routines(in: load()).first { $0.contains { $0.id == automation.id } }?.map(\.weekday) ?? [automation.weekday]
        guard days.count > 1 else { return scheduleText(automation) }
        let calendar = Calendar.current
        let time = calendar.date(from: DateComponents(hour: automation.hour, minute: automation.minute))?.formatted(date: .omitted, time: .shortened) ?? ""
        let label = days.count == 7 ? "Every day" : days.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        return "\(label) at \(time)"
    }

    // MARK: - What a run says

    /// The message each run sends to the Automation thread.
    static func message(for automation: ProjectAutomation, manual: Bool, now: Date = Date()) -> String {
        """
        Automation run: \(automation.title) (\(manual ? "started by hand" : "weekly"), \(now.formatted(date: .abbreviated, time: .shortened))).

        \(automation.instructions.trimmingCharacters(in: .whitespacesAndNewlines))

        Rules for every automation run:
        - Before adding work, read `desk list --json` and compare the complete `tasks` inventory across every column, including work in progress, waiting for Shelby, Review, silenced and Done. Reuse existing tasks by source identity (or verified sender/subject/date without an ID); update source status with `desk source`, preserving their thread and column. A changed title or an unfinished source is not a new task.
        - When adding email or ClickUp work to the Desk, preserve its source: `desk add ... --source email:<message id>` or `--source clickup:<task id or link>`, with `--source-title` and `--source-url` for the verified original web link. Report source status using `desk source <ref> --status "<status>" --url "<verified link>"`. Never invent an ID or URL; if the source provides neither, retain sender, subject and date in the note and explicitly report that a direct link is unavailable. Do not send email or change ClickUp to obtain a link.
        - Report what you found first, and ask before changing anything: ask with your question tool and wait for my answer.
        - Never change staging or production without my explicit approval, for that environment.
        - Back up before you change anything, and say where the backup is.
        - If there's nothing to do, say so in one line.
        """
    }

    static let wordpressInstructions = """
        Keep this project's WordPress site up to date, safely.
        1. Find the local SKD Studio copy of this site (under /Users/shelbyklein/Studio unless this project says otherwise) and confirm its local URL.
        2. With WP-CLI, list available core, plugin and theme updates (wp core check-update, wp plugin list --update=available, wp theme list --update=available). Flag major-version jumps, abandoned plugins and anything with security fixes.
        3. Report the list and ask which updates to apply.
        4. When I approve: export the local database (wp db export) and note the backup path, apply the approved updates locally, then check that the front page and wp-admin load without PHP errors and that the debug log is clean.
        5. Report the results, then ask before applying the same updates to staging or production. Use this project's established deploy workflow (for example RunCloud), back up the live site first, and verify it afterwards.
        """
}
