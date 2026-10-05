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
    var projectFolder: String
    var title: String
    var template: Template
    var instructions: String
    /// Calendar weekday: 1 is Sunday, 7 Saturday.
    var weekday: Int = 2
    var hour: Int = 9
    var minute: Int = 0
    var enabled = true
    /// A model preset the thread switches to before each run (optional).
    var preset: UUID?
    var createdAt = Date()
}

/// What the service has done with an automation; written only by the service.
struct AutomationRunState: Codable {
    var lastRun: Date?
    var threadID: UUID?
}

enum ProjectAutomations {
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

    /// "Mondays at 9:00 AM".
    static func scheduleText(_ automation: ProjectAutomation) -> String {
        let day = Calendar.current.weekdaySymbols[max(0, min(6, automation.weekday - 1))]
        var parts = DateComponents(); parts.hour = automation.hour; parts.minute = automation.minute
        let time = Calendar.current.date(from: parts).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(day)s at \(time)"
    }

    // MARK: - What a run says

    /// The message each run sends to the Automation thread.
    static func message(for automation: ProjectAutomation, manual: Bool, now: Date = Date()) -> String {
        """
        Automation run: \(automation.title) (\(manual ? "started by hand" : "weekly"), \(now.formatted(date: .abbreviated, time: .shortened))).

        \(automation.instructions.trimmingCharacters(in: .whitespacesAndNewlines))

        Rules for every automation run:
        - Report what you found first, and ask before changing anything. Wait for my answer in this thread.
        - Never change staging or production without my explicit approval in this thread, for that environment.
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
