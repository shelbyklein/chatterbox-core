import Foundation

/// What Chatterbox on the Mac and the Chatterbox iPhone app say to each other. The Mac
/// serves this over HTTP on the home network and Tailscale; every call but pairing carries
/// the token the phone got when it paired.
enum Companion {
    static let port: UInt16 = Flavor.current.companionPort
    /// Bonjour service type, for finding the Mac on the same Wi-Fi.
    static let serviceType = Flavor.current.bonjourType
    static let tokenHeader = "X-Chatterbox-Token"
    /// The newest items a chat sends at once; older ones are left out.
    static let itemLimit = 300

    struct PushRegistration: Codable, Equatable, Sendable {
        var token: String
        /// sandbox for development installs, production for TestFlight/App Store.
        var environment: String
        var enabled: Bool
        var valid: Bool {
            ["sandbox", "production"].contains(environment) && token.range(of: "^[0-9a-fA-F]{64,512}$", options: .regularExpression) != nil
        }
    }

    struct PairRequest: Codable {
        var code: String
        var deviceName: String
    }

    /// Where the Mac can be reached right now (its addresses change, and Tailscale may have
    /// been off when the phone paired).
    struct Addresses: Codable {
        var addresses: [String]
    }

    struct PairResponse: Codable {
        var token: String
        var macName: String
        /// Where else the Mac can be reached, such as its Tailscale address.
        var addresses: [String]
    }

    /// The chat list, grouped the way the Mac's sidebar is.
    struct ChatList: Codable {
        var revision: Int
        var groups: [ChatGroup]
        /// Pins that show everywhere.
        var pins: [Pin]? = nil
        /// Actual turn-end events, newest first. Missing on older Macs.
        var activity: [TurnCompletion]? = nil
    }

    struct TurnCompletion: Codable, Identifiable, Hashable {
        var id: UUID
        var chatID: UUID
        var title: String
        var backend: String
        var endedAt: Date
    }

    /// Something pinned on the Mac: a website (opens on the phone), or an app, file, or
    /// Shortcut (opens on the Mac).
    struct Pin: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        /// "website", "app", "file", or "shortcut".
        var kind: String
        var target: String
    }

    struct InstructionsRequest: Codable {
        var text: String
    }

    struct PromotionRequest: Codable {
        enum Kind: String, Codable, Identifiable { case studio, project; var id: String { rawValue } }
        var kind: Kind
        var studioID: UUID? = nil
        var name: String? = nil
        var folder: String? = nil
        var newFolderName: String? = nil
        var keepFolder: Bool = true
    }

    struct PromotionOptions: Codable {
        struct Destination: Codable, Identifiable {
            var id: UUID
            var name: String
            var folder: String
        }
        var currentFolder: String
        var studios: [Destination]
    }

    struct ProjectFolders: Codable {
        struct Folder: Codable, Identifiable {
            var path: String
            var name: String
            var id: String { path }
        }
        var path: String
        var parent: String?
        var folders: [Folder]
    }

    /// A slash command or Codex skill the chat can use.
    struct Command: Codable, Hashable, Identifiable {
        var id: String { name }
        var name: String
        var detail: String
        var argumentHint: String?
    }

    struct ChatGroup: Codable, Identifiable {
        enum Kind: String, Codable { case projects, studio, chats }
        var id: String
        var kind: Kind
        var title: String
        var chats: [ChatSummary]
        /// A Studio's id, instructions, and pins.
        var studioID: UUID? = nil
        var instructions: String? = nil
        var pins: [Pin]? = nil
    }

    struct ChatSummary: Codable, Identifiable, Hashable {
        var id: UUID
        var title: String
        /// A project's name, shown above the chat's title.
        var project: String?
        /// What happened last, or the chat's title.
        var subtitle: String?
        var backend: String
        var isRunning: Bool
        var isWaitingOnYou: Bool
        var updatedAt: Date
        /// A project's own pins.
        var pins: [Pin]? = nil
        /// A worktree of the project listed just before it: its branch, shown nested under it.
        var worktreeBranch: String? = nil
        /// A temporary independent conversation, listed under this parent when available.
        var sidechatOf: UUID? = nil
        /// A sidequest: the chat it reports back to, its task, and whether it has. Older Macs omit them.
        var sidequestOf: UUID? = nil
        var sidequestTask: String? = nil
        var sidequestReturned: Bool? = nil
        /// A project's tags, and how active the chat is: turns in the last day and week, and
        /// its average turns a day since it started (for chats from before turns were timed).
        var tags: [String]? = nil
        var turnsToday: Int? = nil
        var turnsThisWeek: Int? = nil
        var turnsPerDay: Double? = nil
        /// Latest image preview, fetched separately as a bounded thumbnail.
        var thumbnail: File? = nil
        /// Stable identity for the reply in progress; absent on older Macs.
        var turnStartedAt: Date? = nil
        /// A regular chat that can become a Project or join a Studio. Older Macs omit it.
        var canPromote: Bool? = nil
        /// The session's Brief, which both agents get (older Macs send none).
        var brief: String? = nil
        /// Pinned on the Mac (Pin to Top): its place among the pins, first is 0.
        var pinnedRank: Int? = nil
        /// A work thread (plans/work-threads.md): the front thread it reports to. Older Macs omit it.
        var workOf: UUID? = nil
    }

    /// One chat, with its recent transcript.
    struct ChatDetail: Codable {
        var revision: Int
        var summary: ChatSummary
        /// e.g. "Claude · Opus 5.5 · Medium effort"
        var settings: String
        var items: [Item]
        /// Items before these that were left out.
        var earlierCount: Int
        /// What can be changed: agent, model, effort, mode, presets.
        var options: ChatOptions? = nil
        var isArchived: Bool? = nil
        /// A project's chat: there's one per folder, so it isn't forked.
        var canFork: Bool? = nil
        /// When the reply in progress started, for its running time.
        var turnStartedAt: Date? = nil
        var backgroundTasks: [BackgroundTask]? = nil
        /// How full the agent's context is, 0–1, once known.
        var contextFraction: Double? = nil
        var contextTokens: Int? = nil
        /// Where `!` commands run.
        var folder: String? = nil
        var commands: [Command]? = nil
        /// Next Steps (a Chatterbox plugin): up to three prompts you might send next.
        var nextSteps: [String]? = nil
        /// A front thread's work threads (its Work strip), newest first; done ones for a week.
        /// Nil with none, or from an older Mac.
        var work: [WorkThread]? = nil
        /// In a work thread: its front thread's title, for the "Work for" header.
        var workOfTitle: String? = nil
    }

    // MARK: - Work threads (plans/work-threads.md)

    /// A work thread as its front thread shows it: a fresh thread in the same project, doing
    /// one task, that reports its result back.
    struct WorkThread: Codable, Identifiable, Hashable {
        /// The work thread's session.
        var id: UUID
        var title: String
        /// "working", "needsYou", "ready" (finished, its result reported) or "done" (marked
        /// complete: archived).
        var state: String
        /// The task it carries on the Desk.
        var task: UUID? = nil
        var backend: String
        var updatedAt: Date
    }

    /// POST /v1/chats/<id>/work (socket: operation "work", action "start"): a work thread for
    /// this front thread, started with `brief` as its first message, on the front thread's agent
    /// and model unless `agent` or `model` say otherwise. Answers the work thread's ChatDetail.
    struct WorkStartRequest: Codable {
        var title: String
        var brief: String
        var agent: String? = nil
        var model: String? = nil
    }

    /// A chat's settings and the choices for each, as on the Mac.
    struct ChatOptions: Codable, Hashable {
        /// "claude" or "codex": who answers next.
        var backend: String
        /// The current model's id; for Codex, empty means Codex's default.
        var model: String
        /// Empty means the model's default.
        var effort: String
        var claudeModels: [ModelOption]
        var codexModels: [ModelOption]
        /// Modes for the current agent.
        var modes: [ModeOption]
        var mode: String
        /// No longer filled (presets are gone); older phones read an empty list.
        var presets: [PresetOption]
        var fastMode: Bool? = nil
        /// Open-weight models on the PC, run by the chat's agent; nil where they can't be picked
        /// (an older Mac).
        var openModels: [ModelOption]? = nil
        /// The open model in use; nil: the agent's own.
        var openModel: String? = nil
    }

    struct ModelOption: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var detail: String
        /// Effort levels, weakest first; empty when the model has none.
        var efforts: [String]
        var defaultEffort: String?
    }

    struct ModeOption: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var detail: String
        var systemImage: String
        /// Can do anything without asking: shown in orange.
        var isUnrestricted: Bool
    }

    struct PresetOption: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        var backend: String
        var isActive: Bool
        /// Older Macs' second name for it; newer ones fold it into the title.
        var nickname: String? = nil
        /// What it switches to: "Claude · Opus 5.5 · Medium".
        var summary: String? = nil
        /// Whose model it runs ("claude" for a Claude model through Codex); the agent otherwise.
        var provider: String? = nil
    }

    /// Hand a task from a chat to the other agent.
    struct SidequestRequest: Codable { var task: String }

    /// Change any of a chat's settings; leave the rest nil.
    struct SettingsRequest: Codable {
        var backend: String? = nil
        var model: String? = nil
        var effort: String? = nil
        var mode: String? = nil
        var preset: UUID? = nil
        var fastMode: Bool? = nil
        /// An open model on the PC; empty: back to the agent's own. Picking a model without
        /// this also leaves the open model.
        var openModel: String? = nil
    }

    /// A new chat, in a Studio or on its own.
    struct NewChatRequest: Codable {
        var studio: UUID? = nil
        var backend: String? = nil
        /// A project's chat: the new chat is a Sidechat of it (same folder, its own history).
        var project: UUID? = nil
        /// A preset to start with (its agent, model and effort).
        var preset: UUID? = nil
        /// Settings chosen before starting (model, effort, permissions), applied after the preset.
        var settings: SettingsRequest? = nil
        /// The name you gave it; empty or missing: named from the first message, as before.
        var title: String? = nil
    }

    /// A model preset, for agents: its nickname and what it switches to.
    struct PresetInfo: Codable {
        var id: UUID
        var nickname: String?
        var title: String
        var backend: String
        var summary: String
    }

    struct RenameRequest: Codable {
        var title: String
    }

    /// One of the Mac's displays, in points, from the top left of them all; Mac Screen splits
    /// Screen Sharing's one picture with these (Screen Sharing doesn't report its displays).
    struct MacDisplay: Codable, Hashable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    // MARK: - The Desk (plans/front-desk.md)

    /// The Desk: what needs Shelby, requests waiting to be placed, and what's working. It
    /// never does work itself; starting a request opens a session in its Studio or project.
    /// Shown as a board (plans/desk-board.md): To do (`incoming`) · Working · Needs you ·
    /// Ready to mark complete · Done.
    struct Desk: Codable {
        var revision: Int
        /// What waits on Shelby, less what was silenced.
        var needsYou: [DeskWaiting]
        var incoming: [DeskRequest]
        var working: [DeskWorking]
        /// Waiting things silenced from the Desk, still waiting in their sessions (an approval
        /// stays pending). The Mac, which finds approvals in its own sessions, leaves these out.
        /// Nil from a service older than silencing.
        var silenced: [DeskWaiting]? = nil
        /// Sessions that finished their reply and ask nothing, newest first: to mark complete.
        /// Nil from a service older than the board.
        var ready: [DeskReady]? = nil
        /// Tasks marked complete from the board in the last week, newest first. Nil from a
        /// service older than the board.
        var done: [DeskDone]? = nil
        /// Every task linked to a thread (open, and done this week): which thread carries which
        /// task, for thread menus and the Mac's own Working. Nil from a service older than tasks.
        var linked: [DeskTask]? = nil
    }

    /// A task linked to its thread (plans/work-threads.md). One task per thread, one thread per task.
    struct DeskTask: Codable, Identifiable, Hashable {
        var id: UUID
        var text: String
        var chatID: UUID
        /// When it was marked complete (its thread archived); nil while open.
        var completedAt: Date? = nil
    }

    /// A session waiting on Shelby, with what it asks.
    struct DeskWaiting: Codable, Identifiable, Hashable {
        /// The waiting item (an approval, a plan or questions); the session's id when it's
        /// waiting on a reply in plain text.
        var id: UUID
        var chatID: UUID
        /// The session's name as the session list shows it: its worktree's branch, its
        /// project's name, or its own title.
        var title: String
        /// The session's Studio or project, if it has one.
        var place: String?
        /// "approval", "plan", "questions" or "reply".
        var kind: String
        /// What it asks, short.
        var text: String
        var questions: [Question]? = nil
        /// The session's own title, when `title` is its project's or branch's name.
        var subtitle: String? = nil
        /// An approval's exact command or files, as its session's card shows them. Nil for
        /// plans, questions and replies, and from a service older than it.
        var detail: String? = nil
        /// The task its thread carries, and what it says; nil: a thread that isn't a task
        /// (shown here only because it needs you), or a service older than tasks.
        var task: UUID? = nil
        var taskText: String? = nil
    }

    /// Where work goes: a Studio, a project (its work starts as a Sidechat of it), or loose.
    struct DeskPlace: Codable, Hashable, Identifiable {
        /// "studio", "project" or "loose".
        var kind: String
        /// The Studio's id, or the project's own session id; nil for loose.
        var id: UUID?
        var name: String
        /// What belongs there: the Studio's instructions or the project's brief.
        var detail: String? = nil
    }

    /// Work waiting to be placed and started.
    struct DeskRequest: Codable, Identifiable, Hashable {
        var id: UUID
        var text: String
        /// Who asked: "you" (typed at the Desk) or "claude" (the connector); more sources later.
        var source: String
        var createdAt: Date
        /// Where the Desk suggests it goes; nil when nothing clearly fits.
        var proposed: DeskPlace?
        /// A line from the asker (why that place, or the plan).
        var note: String? = nil
    }

    struct DeskWorking: Codable, Identifiable, Hashable {
        var id: UUID
        /// Named as in DeskWaiting.
        var title: String
        var place: String?
        var subtitle: String? = nil
        /// What it's doing now (the step it's on, or that it's thinking), short. Nil from a
        /// service older than the board.
        var activity: String? = nil
        /// When its reply started.
        var since: Date? = nil
        /// The task it's doing (Working shows only threads that carry one).
        var task: UUID? = nil
        var taskText: String? = nil
    }

    /// A task whose thread finished its reply and asks nothing: Ready to mark complete. Only
    /// threads that carry a task (plans/work-threads.md), however long ago they finished.
    /// Silencing it (DeskSilenceRequest with its id and text) hides it until something new
    /// happens in it.
    struct DeskReady: Codable, Identifiable, Hashable {
        /// The session.
        var id: UUID
        /// Named as in DeskWaiting.
        var title: String
        var place: String?
        var subtitle: String? = nil
        /// What its last reply says, its first sentence.
        var text: String
        var finishedAt: Date
        var task: UUID? = nil
        var taskText: String? = nil
    }

    /// A task marked complete (its thread archived, from the board or elsewhere); Reopen
    /// unarchives the thread and reopens the task.
    struct DeskDone: Codable, Identifiable, Hashable {
        /// The session.
        var id: UUID
        /// Named as in DeskWaiting.
        var title: String
        var place: String?
        var subtitle: String? = nil
        var completedAt: Date
        var task: UUID? = nil
        var taskText: String? = nil
    }

    /// POST /v1/desk/complete (socket: action "complete"): archives the session, completing the
    /// task it carries (into Done). POST /v1/desk/reopen (socket: action "reopen"): unarchives
    /// it and reopens its task. Both answer the Desk.
    struct DeskSessionRequest: Codable {
        var chatID: UUID
    }

    /// POST /v1/desk/<task id>/link (socket: action "link", with `id`): the task is done in that
    /// thread. A thread carrying another open task is refused (409) unless `replace`: then that
    /// task goes back to To do. POST /v1/desk/<task id>/unlink (socket: "unlink"): back to To do.
    /// Both answer the Desk.
    struct DeskLinkRequest: Codable {
        var chatID: UUID
        var replace: Bool? = nil
    }

    /// POST /v1/desk/task (socket: action "makeTask"): Make this a task: a new task, already
    /// linked to the thread, named `text` or else the thread's title. Answers the Desk.
    struct DeskTaskRequest: Codable {
        var chatID: UUID
        var text: String? = nil
    }

    /// POST /v1/desk: a new request. `place` names a Studio or project to propose instead of
    /// the Desk's own guess.
    struct DeskAddRequest: Codable {
        var text: String
        var source: String? = nil
        var place: String? = nil
        var note: String? = nil
    }

    /// POST /v1/desk/<id>/start: start it where proposed, or in `place` instead, on `agent`
    /// and `model` (and `effort`, or an open model on the PC) when given. With `continueChat`,
    /// nothing new starts: the request goes to that session as its next message (queued if
    /// it's working), and the reply is that session; the agent and model given switch it first
    /// (its agent only between replies, else 409). Older services ignore the new fields.
    struct DeskStartRequest: Codable {
        var place: DeskPlace? = nil
        var agent: String? = nil
        var model: String? = nil
        var effort: String? = nil
        var openModel: String? = nil
        var continueChat: UUID? = nil
        /// Continuing a thread that already carries another open task: that task goes back to
        /// To do (else 409).
        var replace: Bool? = nil
    }

    /// GET /v1/desk/<id>/threads?place=<id or "loose"> (socket: action "threads", with `place`):
    /// sessions already in that place that look like the same work, best first. Continuing
    /// one sends the request there instead of starting a new session. With all=1 (socket:
    /// `all` true), every open thread there, best matches first: Link a thread's choices.
    struct DeskThread: Codable, Identifiable, Hashable {
        /// The session.
        var id: UUID
        /// Its own title.
        var title: String
        /// What it last said or was asked, short.
        var detail: String? = nil
        /// Its agent and model: "Claude · Opus 5.5 · Medium".
        var settings: String? = nil
        var updatedAt: Date
        var isRunning: Bool
        /// "clear": very likely the same work, chosen unless you pick otherwise; "possible":
        /// it shares some of the request's words; "other" (asked for with all=1): it doesn't.
        var match: String
        /// The open task it already carries; linking this request to it sends that one back to To do.
        var task: String? = nil
    }

    /// POST /v1/desk/silence (socket: action "silence"): takes one waiting thing off the Desk,
    /// on every device, without answering it. The DeskWaiting's chatID, id and text: a new
    /// approval, plan or questions, or a newer reply that asks something, shows again.
    /// POST /v1/desk/unsilence (socket: action "unsilence"), the same body: puts a silenced
    /// thing (one of the Desk's `silenced`) back on the Desk. Answers the Desk; something
    /// not silenced is left as it is. A service older than it answers 404.
    struct DeskSilenceRequest: Codable {
        var chatID: UUID
        var id: UUID
        var text: String? = nil
    }

    // MARK: - Automations

    /// A project's routine (GET /v1/automations): the Mac keeps one automation per weekday,
    /// and those that share a project, name, instructions, time and agent show as one.
    struct AutomationRoutine: Codable, Identifiable, Hashable {
        /// Its first day's automation; any of `ids` names the routine in the routes.
        var id: UUID
        var ids: [UUID]
        var title: String
        var instructions: String
        /// The project's name, and its folder.
        var project: String
        var projectFolder: String
        /// "claude" or "codex": who does each run.
        var agent: String
        /// The model's name and the effort; nil: the agent's defaults.
        var model: String? = nil
        var effort: String? = nil
        /// The weekdays it runs on, 1 Sunday to 7 Saturday.
        var days: [Int]
        var hour: Int
        var minute: Int
        /// On for any of its days.
        var enabled: Bool
        /// Days switched off on the Mac while others are on; nil when all match.
        var pausedDays: [Int]? = nil
        var lastRunAt: Date? = nil
        /// The last run's session, while it's still there.
        var lastThreadID: UUID? = nil
        /// What the last run says last, as the session list shows it.
        var lastResult: String? = nil
        /// The last run is still working.
        var isRunning: Bool? = nil
        var nextRunAt: Date? = nil
    }

    /// POST /v1/automations/<id>: changes every day of the routine; leave the rest nil. New
    /// days copy the routine, and days left out are deleted.
    struct AutomationEdit: Codable {
        var title: String? = nil
        var instructions: String? = nil
        var days: [Int]? = nil
        var hour: Int? = nil
        var minute: Int? = nil
        var enabled: Bool? = nil
        /// "claude" or "codex"; another agent starts on its default model and effort.
        var agent: String? = nil
    }

    /// Pin to Top on the Mac, or not.
    struct PinRequest: Codable {
        var pinned: Bool
    }

    /// The accounts' usage, as the Mac sees it: each agent's limit windows (from its latest
    /// report) and, with EasyCLIProxy, each proxy account's remaining quota.
    struct Usage: Codable {
        struct Window: Codable, Hashable {
            var label: String
            /// 0 to 1: used for a limit window, remaining for a proxy quota.
            var fraction: Double?
            var resetsAt: Date?

            /// Proxy quota is measured in percent; the wire contract always uses 0–1.
            static func quota(label: String, remainingPercent: Double?, resetsAt: Date?) -> Self {
                .init(label: label, fraction: remainingPercent.map { $0 / 100 }, resetsAt: resetsAt)
            }
        }
        struct Account: Codable, Hashable {
            var provider: String
            var name: String
            var status: String
            var windows: [Window]
            var problem: String?
        }
        var claude: [Window]
        var codex: [Window]
        var proxyAccounts: [Account]?
        var proxyProblem: String?
        var proxyChecked: Date?
    }

    /// Sets the session's Brief; empty clears it.
    struct BriefRequest: Codable {
        var brief: String
    }

    struct Item: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case user, assistant, thought, tool, plan, notice, approval, image, questions, shell }
        var id: UUID
        var kind: Kind
        var text: String
        /// An agent's reply still being written.
        var isStreaming: Bool
        /// Narration mid-task rather than the reply.
        var isCommentary: Bool
        /// For tool rows: running, done, or failed.
        var toolState: String?
        /// Waiting for an answer on the Mac (approvals and question cards).
        var isPending: Bool
        var attachments: [File]
        /// Queued while the agent works, not yet picked up.
        var isQueued: Bool
        /// Approval rows: the decision asked for, and what was decided.
        var approval: Approval? = nil
        /// Question rows: what the agent asked, and the answers once sent.
        var questions: [Question]? = nil
        var answers: [String: [String]]? = nil
        /// Approval detail (the command, or the plan) and `!` command output.
        var detail: String? = nil
        /// A plan's steps.
        var planSteps: [PlanStep]? = nil
        /// On a reply that ended a turn: how long the turn took.
        var workedSeconds: Int? = nil
    }

    struct PlanStep: Codable, Hashable {
        var step: String
        /// "pending", "in_progress", or "completed".
        var status: String
    }

    /// A subagent or background command still running apart from the reply.
    struct BackgroundTask: Codable, Hashable, Identifiable {
        var id: String
        /// "agent" or "shell".
        var kind: String
        var title: String
        var detail: String?
        var startedAt: Date
    }

    struct Approval: Codable, Hashable {
        /// A plan to start building, rather than a single action to allow.
        var isPlan: Bool
        /// "pending", "approved", "approvedForSession", "denied", or "expired".
        var state: String
    }

    struct Question: Codable, Hashable, Identifiable {
        struct Option: Codable, Hashable {
            var label: String
            var detail: String
        }
        var id: String
        var header: String
        var question: String
        var options: [Option]
        var multiSelect: Bool
        var isSecret: Bool
    }

    /// Allow or deny an action, or start building a plan.
    struct DecisionRequest: Codable {
        /// "approved", "approvedForSession", or "denied".
        var decision: String
    }

    /// Answers by question id; nil skips the questions.
    struct AnswersRequest: Codable {
        var answers: [String: [String]]?
    }

    struct File: Codable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var mediaType: String
        var isImage: Bool
        /// PDFs: modification time and size, to refresh a changed saved copy.
        var revision: String? = nil
        var byteCount: Int64? = nil
    }

    struct SendRequest: Codable {
        var text: String
        /// Images sent with the message, such as a sketch (PNG or JPEG).
        var images: [Upload]? = nil
        /// Stop the agent and send this right away ("Send Now"), rather than adding it to
        /// the reply in progress.
        var now: Bool? = nil
    }

    struct Upload: Codable {
        var name: String
        var data: Data
    }

    /// Requests can carry images, so allow this much.
    static let maxRequestBytes = 40_000_000

    struct Unchanged: Codable {
        var unchanged = true
        var revision: Int
    }

    struct ErrorResponse: Codable {
        var error: String
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension Companion.SettingsRequest {
    /// Choices made before something starts (New Chat, the Desk's start step), one change at a
    /// time: switching agent or preset starts that part over; the rest add up. `backend` is
    /// the agent the options shown are for.
    mutating func add(_ change: Companion.SettingsRequest, backend: String?) {
        if let preset = change.preset {
            self = .init(preset: preset)
        } else if let picked = change.backend, picked != backend {
            // Another agent's model: that agent, with the model picked.
            self = .init(backend: picked, model: change.model)
        } else if let open = change.openModel {
            openModel = open; effort = nil
        } else {
            if let model = change.model { self.model = model; effort = nil; openModel = nil }
            if let effort = change.effort { self.effort = effort }
            if let mode = change.mode { self.mode = mode }
            if let fast = change.fastMode { fastMode = fast }
        }
    }

    /// Nothing chosen yet.
    var isEmpty: Bool { backend == nil && model == nil && effort == nil && mode == nil && preset == nil && fastMode == nil && openModel == nil }
}

extension Companion.ChatOptions {
    /// The model in use: an open model, or the agent's, among its models.
    var currentModel: Companion.ModelOption? {
        openModel == nil ? (backend == "codex" ? codexModels : claudeModels).first { $0.id == model } : nil
    }

    /// Runs on the same agent, model and effort.
    func sameModel(as other: Companion.ChatOptions) -> Bool {
        backend == other.backend && model == other.model && effort == other.effort && openModel == other.openModel
    }
}
