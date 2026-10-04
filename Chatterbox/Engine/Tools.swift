import Foundation

/// How Claude Code's tool calls appear in the transcript.
enum Tools {
    /// Claude Code's to-do list, shown as the plan card instead of a tool row.
    static let todoTool = "TodoWrite"

    static func planSteps(_ input: JSON?) -> [PlanStep]? {
        guard let todos = input?["todos"]?.array, !todos.isEmpty else { return nil }
        return todos.compactMap { todo in
            guard let text = todo["content"]?.string ?? todo["activeForm"]?.string else { return nil }
            let status = todo["status"]?.string ?? "pending"
            return PlanStep(step: text, status: ["pending", "in_progress", "completed"].contains(status) ? status : "pending")
        }
    }

    /// Human-readable status line for a tool call.
    static func label(name: String, input: JSON?) -> String {
        if name.hasPrefix("mcp__chatterbox__") { return dotLabel(String(name.dropFirst("mcp__chatterbox__".count)), input: input) }
        let file = input?["file_path"]?.string ?? input?["notebook_path"]?.string ?? input?["path"]?.string
        let fileName = file.map { ($0 as NSString).lastPathComponent }
        switch name {
        case "Bash":
            if let description = input?["description"]?.string, !description.isEmpty { return description }
            if let command = input?["command"]?.string { return "Running `\(short(command))`" }
            return "Running a command"
        case "Read": return "Reading \(fileName ?? "a file")"
        case "Write": return "Writing \(fileName ?? "a file")"
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(fileName ?? "a file")"
        case "Glob":
            if let pattern = input?["pattern"]?.string { return "Finding files matching \(pattern)" }
            return "Finding files"
        case "Grep":
            if let pattern = input?["pattern"]?.string { return "Searching for \u{201C}\(short(pattern))\u{201D}" }
            return "Searching files"
        case "WebSearch":
            if let q = input?["query"]?.string { return "Searching the web for \u{201C}\(q)\u{201D}" }
            return "Searching the web"
        case "WebFetch":
            if let url = input?["url"]?.string { return "Reading \(URL(string: url)?.host ?? url)" }
            return "Reading a page"
        case "Task", "Agent":
            if let description = input?["description"]?.string { return "Delegating: \(description)" }
            return "Delegating to a helper"
        case "Skill":
            if let skill = input?["skill"]?.string ?? input?["command"]?.string { return "Using the \(skill) skill" }
            return "Using a skill"
        case todoTool: return "Updating the plan"
        default:
            // MCP tools are named mcp__<server>__<tool>.
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 { return "Using \(parts.dropFirst(2).joined(separator: " ")) (\(parts[1]))" }
            }
            return "Using \(name)"
        }
    }

    /// Title and detail for a permission prompt.
    static func approval(name: String, input: JSON?, description: String?) -> (title: String, detail: String?) {
        let file = input?["file_path"]?.string ?? input?["notebook_path"]?.string
        switch name {
        case "Bash":
            return ("Claude wants to run a command", input?["command"]?.string)
        case "Write":
            return ("Claude wants to create \((file as NSString?)?.lastPathComponent ?? "a file")", file)
        case "Edit", "MultiEdit", "NotebookEdit":
            let change = input?["old_string"]?.string.map { old in
                "\(file ?? "")\n\u{2212} \(short(old, 200))\n+ \(short(input?["new_string"]?.string ?? "", 200))"
            }
            return ("Claude wants to edit \((file as NSString?)?.lastPathComponent ?? "a file")", change ?? file)
        case "WebFetch":
            return ("Claude wants to open a web page", input?["url"]?.string)
        default:
            return ("Claude wants to use \(label(name: name, input: input).lowercasedFirst)", description)
        }
    }

    private static func short(_ text: String, _ limit: Int = 80) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "\u{2026}" : oneLine
    }

    /// Dot's Chatterbox tools, in words: "Messaging “SDHQ”".
    private static func dotLabel(_ tool: String, input: JSON?) -> String {
        let chat = input?["chat"]?.string.map { " \u{201C}\($0)\u{201D}" } ?? ""
        switch tool {
        case "list_chats": return "Looking over your chats"
        case "read_chat": return "Reading" + (chat.isEmpty ? " a chat" : chat)
        case "send_message": return "Messaging" + (chat.isEmpty ? " a chat" : chat)
        case "start_chat": return "Starting a chat" + (input?["studio"]?.string.map { " in \u{201C}\($0)\u{201D}" } ?? "")
        case "wait_for_reply": return "Waiting on" + (chat.isEmpty ? " a chat" : chat)
        case "stop_chat": return "Stopping" + (chat.isEmpty ? " a chat" : chat)
        default: return "Using Chatterbox"
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
