import Foundation

/// What Chatterbox on the Mac and the Chatterbox iPhone app say to each other. The Mac
/// serves this over HTTP on the home network and Tailscale; every call but pairing carries
/// the token the phone got when it paired.
enum Companion {
    static let port: UInt16 = 47_321
    /// Bonjour service type, for finding the Mac on the same Wi-Fi.
    static let serviceType = "_chatterbox._tcp"
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
        var product:String? = nil
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
        enum Kind: String, Codable { case dot, projects, studio, chats }
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
        /// The assistant's own chat, and how many of its replies you haven't read.
        var isDot: Bool? = nil
        var unread: Int? = nil
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
    }

    /// The assistant's animations and head image, to play on the phone too.
    struct AvatarList: Codable {
        struct File: Codable, Hashable {
            var name: String
            var modified: Date
        }
        var files: [File]
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
        /// (Golem, or an older Mac).
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
        /// Pending question rows: answers Golem suggests, and why. Sent only by the user.
        var suggested: [String: [String]]? = nil
        var suggestedReason: String? = nil
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

    /// From Golem's tools on the Mac: answers he suggests for a question card.
    struct SuggestionRequest: Codable {
        var answers: [String: [String]]
        var reason: String
    }

    /// From Golem's tools on the Mac: a decision for his journal.
    struct DecisionNote: Codable {
        var summary: String
        var why: String?
        var chat: String?
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
        /// Sent by Dot, which then follows the chat and reports back when it's done.
        var fromDot: Bool? = nil
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
