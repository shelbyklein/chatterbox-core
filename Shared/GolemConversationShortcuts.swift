#if GOLEM_APP
import AppIntents
import SwiftUI

/// Ephemeral command mailbox: cold launches can wait for the connected chat to appear.
@MainActor @Observable final class GolemConversationRequest {
    static let shared = GolemConversationRequest()
    struct Request { let id = UUID(); let start: Bool }
    var pending: Request?
    var cancelPending: (() -> Void)?
    private var results: [UUID: String] = [:]
    func finish(_ request: Request, error: String? = nil) {
        guard pending?.id == request.id else { return }
        cancelPending = nil
        results[request.id] = error ?? ""
        pending = nil
    }
    func run(start: Bool) async throws {
        if let previous = pending { cancelPending?(); finish(previous, error: "Another conversation action replaced this request.") }
        let request = Request(start: start)
        pending = request
        defer {
            results.removeValue(forKey: request.id)
            if pending?.id == request.id {
                cancelPending?()
                cancelPending = nil
                pending = nil
            }
        }
        for _ in 0..<200 {
            try Task.checkCancellation()
            if let result = results.removeValue(forKey: request.id) {
                if !result.isEmpty { throw ConversationActionError(message: result) }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ConversationActionError(message: "Open Golem and check its connection to your Mac, then try again.")
    }
}

struct ConversationActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct StartGolemConversation: AppIntent {
    static var title: LocalizedStringResource = "Start Conversation"
    static var description = IntentDescription("Open Golem and listen for your spoken reply. Pause to send.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        try await GolemConversationRequest.shared.run(start: true)
        return .result()
    }
}
struct EndGolemConversation: AppIntent {
    static var title: LocalizedStringResource = "End Conversation"
    static var description = IntentDescription("Stop Golem speaking and listening, keeping unsent words.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        try await GolemConversationRequest.shared.run(start: false)
        return .result()
    }
}
struct GolemConversationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartGolemConversation(), phrases: ["Talk to \(.applicationName)", "Start a conversation with \(.applicationName)"], shortTitle: "Talk to Golem", systemImageName: "waveform")
        AppShortcut(intent: EndGolemConversation(), phrases: ["End conversation with \(.applicationName)"], shortTitle: "End Conversation", systemImageName: "stop.circle")
    }
}
#endif
