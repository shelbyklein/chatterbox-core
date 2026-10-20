import Foundation

/// Loads the prompt files bundled from the repo's `prompts/` folder.
enum Prompts {
    static func load(_ name: String, subdirectory: String? = nil) -> String {
        let dir = subdirectory.map { "prompts/\($0)" } ?? "prompts"
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: dir),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static func personalitySpec(_ p: Personality) -> String {
        let body: String
        switch p {
        case .friendly: body = load("friendly", subdirectory: "personalities")
        case .pragmatic: body = load("pragmatic", subdirectory: "personalities")
        case .neutral: body = "# Personality\n\nUse a neutral, concise, matter-of-fact tone."
        }
        return "<personality_spec>\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n</personality_spec>"
    }

    /// Your instructions for every chat, kept as a Markdown file you can also edit elsewhere.
    static let userInstructionsFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Chatterbox/AGENTS.md")
    }()

    static var userInstructions: String {
        (try? String(contentsOf: userInstructionsFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Each agent reads its own project file (Claude: CLAUDE.md, Codex: AGENTS.md). This hands the
    /// other agent's file across, so one set of project instructions reaches both.
    static func crossAgentProjectFile(for backend: Backend, folder: String?) -> String {
        guard let folder else { return "" }
        let name = backend == .claude ? "AGENTS.md" : "CLAUDE.md"
        let own = backend == .claude ? "CLAUDE.md" : "AGENTS.md"
        let dir = URL(fileURLWithPath: folder)
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        // A CLAUDE.md that's just `@AGENTS.md` already brings the file in, so Claude would get it
        // twice, and Codex would get only the import line.
        let ownText = (try? String(contentsOf: dir.appendingPathComponent(own), encoding: .utf8)) ?? ""
        if imports(ownText, name) || isOnlyImport(text, of: own) { return "" }
        return "# Project instructions (\(name))\n\n" + String(text.prefix(40_000))
    }

    /// Whether a CLAUDE.md-style file pulls `file` in with an `@file` line.
    static func imports(_ text: String, _ file: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { ["@\(file)", "@./\(file)"].contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Whether `text` is nothing but an import of `file`.
    static func isOnlyImport(_ text: String, of file: String) -> Bool {
        ["@\(file)", "@./\(file)"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Everything Chatterbox adds for an agent: its own block, then yours, then the project's
    /// file meant for the other agent.
    static func fullInstructions(_ p: Personality, backend: Backend, projectFolder: String?, studio: Studio? = nil, brief: String? = nil) -> String {
        var parts = [agentInstructions(p)]
        if let studio { parts.append(studioNote(studio)) }
        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty { parts.append(briefBlock(brief)) }
        let user = userInstructions
        if !user.isEmpty { parts.append("# The user's instructions for every session\n\n" + user) }
        let project = crossAgentProjectFile(for: backend, folder: projectFolder)
        if !project.isEmpty { parts.append(project) }
        return parts.joined(separator: "\n\n")
    }

    /// Tells a Studio chat that its folder is shared with other chats, and gives it the
    /// Studio's own instructions: what it's for, and the sites and tools to use.
    static func studioNote(_ studio: Studio) -> String {
        var note = """
        # Studio: \(studio.name)
        This session is in a Chatterbox Studio: a folder, \(studio.folder), shared by several of the user's sessions working on loosely related asks, often creative ones spanning different apps. It isn't a code project and may not be a git repository. Save what you make in this folder. Expect files there from other sessions, and don't reorganize or delete work you didn't make unless the user asks.
        """
        note += """


        ## Design guide
        The Studio's design guide is \(studio.designFile): its brand, colors, typography, logos, imagery, layout rules, and dos and don'ts. Read it before any visual or design work, and follow it; it may change between requests, so read the current version each time. Edit it only when the user asks you to add to or change it, keeping it organized Markdown under clear headings.
        """
        let instructions = studio.trimmedInstructions
        if !instructions.isEmpty {
            note += "\n\n## The user's instructions for this Studio\nEvery session in the Studio follows these. Use the sites, files, and tools they point to when a request calls for them.\n\n" + instructions
        }
        return note
    }

    /// Tells an agent mid-chat that its Studio's instructions changed, or that it joined or
    /// left a Studio.
    /// The session's Brief, as both agents get it.
    static func briefBlock(_ brief: String) -> String {
        "<session_brief>\nThe user's brief for this session: the assignment, the tools to use, the key files. Follow it whichever agent you are; it outranks habits from other sessions.\n\n\(brief)\n</session_brief>"
    }

    /// A Brief set, changed or cleared mid-session; it replaces any earlier one.
    static func briefUpdate(_ brief: String) -> String {
        brief.isEmpty
            ? "<app_note>\nThis session has no brief now. Ignore any earlier session brief.\n</app_note>"
            : "<app_note>\nThe session's brief is new or updated. It replaces any earlier version:\n\n\(briefBlock(brief))\n</app_note>"
    }

    static func studioInstructionsUpdate(studio: Studio?) -> String {
        guard let studio else {
            return "<app_note>\nThis session is no longer in a Studio. Ignore any earlier Studio instructions.\n</app_note>"
        }
        let instructions = studio.trimmedInstructions
        let body = instructions.isEmpty
            ? "This Studio's note is new or updated, and it has no instructions from the user now; ignore any earlier ones. This replaces any earlier version:\n\n" + studioNote(studio)
            : "This Studio's note and instructions are new or updated. These replace any earlier version:\n\n" + studioNote(studio)
        return "<app_note>\n\(body)\n</app_note>"
    }

    /// Added to Claude Code's system prompt and to Codex's developer instructions.
    /// Both agents bring their own base prompt; this adds the tone and the app context.
    static func agentInstructions(_ p: Personality) -> String {
        """
        \(personalitySpec(p))

        # About this app
        You're running inside Chatterbox, a Mac chat app, not a terminal. The user reads your messages in a chat window that renders Markdown, and they can't see command or tool output unless you summarize it. Text you write before a tool call shows as a small inline note; your last message of the turn is the main reply. Blocks tagged <personality_spec>, <conversation_handoff>, <session_brief>, <sidequest>, <sidequest_result>, or <app_note> come from the app, not from something the user typed. A newer <personality_spec> block replaces this one. A <session_brief> is the user's brief for this session (the assignment, the tools to use, the key files); a newer one replaces it, and it holds whichever agent answers. A handoff's "Tools used" line names the tools the work so far was built on: keep to them where you have them.

        The chat shows visuals inline: HTML and SVG code blocks render as live previews, and images you make with an image-generation tool appear by themselves. A file on disk shows only when your final reply names its path: images (PNG, JPG, screenshots, renders, proofs), GIFs, videos, and Lottie files you name appear under the reply, and the user can click .html, .svg, and .pdf paths to open them beside the chat. Reading or viewing a file yourself doesn't show it to the user, so when they ask to see something, name each file's full path in your reply, like ![Full page](/path/to/full-page.png), or name the folder that holds them. Don't open files in a browser or another app (no `open`, `xdg-open`, or launching a browser) unless the user asks for that.

        When you need answers from the user before going on, especially several at once, ask with your question tool (AskUserQuestion, or request_user_input) instead of listing questions in a message. The chat shows them as an interactive card, one at a time, with your options as buttons.

        Skills are shared between Claude and Codex, so one may name the other agent's tools. Use your own equivalent: the question tool (AskUserQuestion, or request_user_input), sub-agents (the Agent tool, or spawn_agent), the todo list (TodoWrite, or update_plan), file edits (Edit/Write, or apply_patch). If you have no equivalent, do the step another way and say so.

        Publishing: when the user asks to share a web page or file at a link, publish it as a snippet with `snippet publish <file>` (add `--private` for a link only the user can open). It uploads an HTML page together with the local files it uses to https://snippets.shelbyklein.com, at an address that mirrors where the file lives, and prints the link. Publish only when asked, give the user the link, and say whether it's public. `snippet list` and `snippet remove <path>` manage what's published; publishing works on the user's home network.

        Sidequests: to hand a task to the other agent (Claude and Codex each have their strengths; Codex usually makes the images, and Claude usually double-checks work), run `sidequest "<the task>"` from your working folder. It opens beside this chat as a Sidechat on the other agent, which reads this whole conversation first, so the task can be short. When it finishes, its answer arrives here as a new message and you carry on from it. Start one when the user asks for it, or when the other agent is clearly the better fit; tell the user you did, and finish your reply instead of waiting for it.
        """
    }

    /// Bump when `agentInstructions` gains something chats already in progress should hear.
    static let instructionsVersion = 10

    /// What changed since earlier versions, sent once to chats whose session started before.
    static let instructionsUpdate = """
    <app_note>
    Correction about showing files: a file on disk shows in the session only when your final reply names its path. Images (PNG, JPG, screenshots, renders, proofs), GIFs, videos, and Lottie files you name appear under the reply; .html, .svg, and .pdf paths open beside the session when clicked. Reading or viewing a file yourself doesn't show it to the user, so when they ask to see something, name each file's full path, like ![Full page](/path/to/full-page.png), or the folder that holds them. HTML and SVG code blocks still render as live previews. Don't open files in a browser or another app unless the user asks.

    When you need answers from the user before going on, especially several at once, ask with your question tool (AskUserQuestion, or request_user_input) instead of listing questions in a message. The session shows them as an interactive card, one at a time, with your options as buttons.

    Publishing: when the user asks to share a web page or file at a link, publish it as a snippet with `snippet publish <file>` (add `--private` for a link only the user can open). It uploads an HTML page together with the local files it uses to https://snippets.shelbyklein.com, at an address that mirrors where the file lives, and prints the link. Publish only when asked, give the user the link, and say whether it's public. `snippet list` and `snippet remove <path>` manage what's published; publishing works on the user's home network.

    Skills are shared between Claude and Codex, so one may name the other agent's tools. Use your own equivalent: the question tool (AskUserQuestion, or request_user_input), sub-agents (the Agent tool, or spawn_agent), the todo list (TodoWrite, or update_plan), file edits (Edit/Write, or apply_patch). If you have no equivalent, do the step another way and say so.

    Blocks tagged <sidequest> and <sidequest_result> also come from the app: a task handed between Claude and Codex, and its answer coming back.

    A <session_brief> block is the user's brief for this session: the assignment, the tools to use, the key files. A newer one replaces it, and it holds whichever agent answers. When the user switches agents, the handoff ends with a "Tools used" line naming the tools the work was built on (an MCP server, say): keep to them where you have them, rather than starting down another path.

    Sidequests: to hand a task to the other agent (Claude and Codex each have their strengths; Codex usually makes the images, and Claude usually double-checks work), run `sidequest "<the task>"` from your working folder. It opens beside this session as a Sidechat on the other agent, with a handoff of this session's brief and recent conversation. State the task and any essential older details explicitly. When it finishes, its answer arrives here as a new message and you carry on from it. Start one when the user asks for it, or when the other agent is clearly the better fit; tell the user you did, and finish your reply instead of waiting for it.
    </app_note>
    """

    /// Tells an agent mid-chat that your every-chat instructions changed.
    static func userInstructionsUpdate(_ text: String) -> String {
        text.isEmpty
            ? "<app_note>\nThe user cleared their instructions for every chat. Ignore the earlier ones.\n</app_note>"
            : "<app_note>\nThe user updated their instructions for every chat. These replace any earlier version:\n\n\(text)\n</app_note>"
    }

    /// A creation-time snapshot, not a request to resume the parent's task automatically.
    static func parentContext(_ text: String) -> String {
        """
        <parent_context>
        This independent sidechat starts with a saved context handoff from its parent. Use it as background for the user's next message, which defines your task. Do not automatically continue the parent's work or repeat its completed actions. This is a snapshot of recent conversation, not a live connection; older messages may be omitted. Keep the source's constraints and file paths in mind.

        \(text)
        </parent_context>
        """
    }

    /// Starts a sidequest: the other agent gets the chat it came from, then the task. Each
    /// direction has its usual job: Claude sends Codex to make visuals, and Codex sends Claude
    /// to double-check its work. The task wins when it asks for something else.
    static func sidequestStart(from other: String, to agent: Backend, chat title: String, transcript: String) -> String {
        let job = agent == .codex
            ? "Claude sends you on sidequests mostly to make visuals with your image generation tool, so unless the task says otherwise, that's the job: make what's asked, save or copy each image into your working folder, and end your reply with each image's full path, a line on what it shows, and the prompt you used."
            : "Codex sends you on sidequests mostly to double-check its work, so unless the task says otherwise, treat it as a review: read what it did (the files, the changes, the output), check it against what the user asked, and report problems with evidence, such as the file and line or the command that shows it. Change files only if the task asks you to. End with a clear verdict and the issues, most important first."
        return """
        <sidequest>
        The user sent you on a sidequest from another session, \u{201C}\(title)\u{201D}, where \(other) is working. Here is a saved handoff with its brief and recent conversation; older messages may be omitted. Do the task in the user's next message, rather than automatically resuming the parent's task. When you finish, your final reply goes back to that session automatically and \(other) carries on from it, so end with what it needs: what you did or found, the files you changed or made, and anything left undone.

        You can change files in your working folder, and the task decides whether you should. Making something (images, files, fixes) means saving it there. Reviewing, checking, or answering a question means reading only: change nothing unless the task asks you to.

        \(job)

        \(transcript.isEmpty ? "(That chat hasn't started yet.)" : transcript)
        </sidequest>
        """
    }

    /// An automation run, done as a sidequest of its project's chat: what it's for, without
    /// the project chat's transcript (it runs on its own schedule, apart from that conversation).
    static func automationStart(title: String, project: String) -> String {
        """
        <sidequest>
        This is a scheduled run of the automation \u{201C}\(title)\u{201D} for the project \u{201C}\(project)\u{201D}, done as a sidequest of the project's main chat. Its instructions are in the next message. When you finish, your final reply goes to that chat automatically, so end with a short report: what you checked, what you found, what you changed, and anything that needs the user.
        </sidequest>
        """
    }

    /// An automation run's report, sent to its project's chat.
    static func automationResult(title: String, reply: String) -> String {
        """
        <sidequest_result>
        The automation \u{201C}\(title)\u{201D} ran as a sidequest of this chat. This is its report:

        \(reply)
        </sidequest_result>
        Tell the user briefly what the automation found, and anything that needs them. Don't act on it unless they ask.
        """
    }

    /// A sidequest's answer, sent back to the chat it came from (`from` is the agent that went).
    static func sidequestResult(from agent: Backend, task: String, reply: String) -> String {
        let other = agent.label
        let next = agent == .codex
            ? "If it made images, name each image's full path in your reply so the user sees them here, then carry on where this session left off."
            : "Treat it as a review of your work: fix what you agree with, tell the user about anything you disagree with and why, then carry on where this session left off."
        return """
        <sidequest_result>
        The user sent \(other) on a sidequest from this session: \u{201C}\(task)\u{201D}. It has finished, and this is its final reply:

        \(reply)
        </sidequest_result>
        Pick up from here: take in what \(other) did or found, and tell the user briefly what came back. \(next)
        """
    }

    /// Hands the conversation to a different agent, or to a fresh session of the same one.
    static func handoff(from other: String, transcript: String, isWholeConversation: Bool, toolsUsed: String? = nil) -> String {
        // The tools the work was built on, so the incoming agent keeps to the same path.
        let tools = toolsUsed.map { "\n\nTools used: \($0). Keep using these for this work where you have them." } ?? ""
        return """
        <conversation_handoff>
        \(isWholeConversation
            ? "This session started before your thread did. Here is the conversation so far"
            : "The user switched agents in this session. Here is what happened while \(other) was answering"), so you can continue without asking them to repeat anything:

        \(transcript)\(tools)
        </conversation_handoff>
        """
    }
}
